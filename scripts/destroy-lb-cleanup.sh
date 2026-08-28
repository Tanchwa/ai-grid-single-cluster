#!/usr/bin/env bash
# Destroy-time cleanup: reap the Kubernetes-managed AWS load balancers before
# the VPC is torn down.
#
# The AWS Load Balancer Controller and the AWS Cloud Controller Manager create
# NLBs/ALBs (and their security groups + ENIs) *outside* Terraform state, in
# response to Service type=LoadBalancer / Ingress objects that ArgoCD deploys.
# Terraform can't see them, so on `terraform destroy` it would try to delete the
# VPC while those load balancers still exist — their ENIs block subnet deletion
# and their security groups block VPC deletion, and the destroy hangs then
# times out.
#
# This script is invoked by the destroy-time provisioner on
# null_resource.lb_cleanup (see destroy-cleanup.tf). The dependency graph
# guarantees it runs while ArgoCD and the LB controller are still alive, so the
# controllers can delete their AWS load balancers gracefully (including the
# security groups they own). A direct-AWS backstop then force-deletes anything
# left — e.g. if the cluster is already unreachable — so the VPC teardown never
# blocks on an orphaned load balancer.
set -euo pipefail

: "${VPC_ID:?VPC_ID is required}"
: "${AWS_REGION:?AWS_REGION is required}"

log() { echo "[lb-cleanup] $*" >&2; }

aws_cli() {
  local args=(--region "$AWS_REGION")
  [ -n "${AWS_PROFILE:-}" ] && args+=(--profile "$AWS_PROFILE")
  aws "${args[@]}" "$@"
}

# ─── Phase 1: graceful teardown via the in-cluster controllers ────────────────
# Delete the LB-backed workloads so the controllers reap the AWS load balancers
# (and the security groups they manage) the clean way. Best-effort: if the
# cluster is already gone, we fall through to the AWS backstop in phase 2.
graceful_cleanup() {
  if [ -z "${KUBECONFIG_CONTENT:-}" ]; then
    log "no kubeconfig provided; skipping in-cluster cleanup"
    return 0
  fi
  if ! command -v kubectl >/dev/null 2>&1; then
    log "kubectl not found; skipping in-cluster cleanup"
    return 0
  fi

  local kubeconfig
  kubeconfig="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$kubeconfig'" RETURN
  printf '%s' "$KUBECONFIG_CONTENT" > "$kubeconfig"
  export KUBECONFIG="$kubeconfig"

  if ! kubectl cluster-info >/dev/null 2>&1; then
    log "cluster unreachable (Tailscale down or nodes already gone); skipping in-cluster cleanup"
    return 0
  fi

  # Stop ArgoCD from re-syncing: with selfHeal enabled it would recreate any
  # Service/Ingress we delete. Removing the Applications first (cascade) tears
  # down the managed workloads via ArgoCD's resources-finalizer.
  log "deleting ArgoCD Applications (cascade) to stop self-heal"
  kubectl delete applications.argoproj.io --all -n argocd \
    --cascade=foreground --timeout=8m 2>/dev/null || \
    log "warning: ArgoCD Application deletion incomplete; continuing"

  # Delete any remaining LoadBalancer Services. The LB controller / CCM hold a
  # finalizer on each, so --wait blocks until the AWS load balancer is actually
  # deleted. (spec.type is not field-selectable, so enumerate explicitly.)
  local svcs
  svcs="$(kubectl get svc --all-namespaces \
    -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null || true)"
  if [ -n "$svcs" ]; then
    log "deleting LoadBalancer Services and waiting for controllers to reap them"
    while read -r ns name; do
      [ -z "$name" ] && continue
      log "  deleting svc $ns/$name"
      kubectl delete svc "$name" -n "$ns" --wait --timeout=8m 2>/dev/null || \
        log "  warning: svc $ns/$name delete timed out; AWS backstop will handle it"
    done <<< "$svcs"
  fi

  log "deleting Ingresses"
  kubectl delete ingress --all --all-namespaces --wait --timeout=8m 2>/dev/null || \
    log "warning: Ingress deletion incomplete; AWS backstop will handle it"
}

# ─── Phase 2: AWS backstop — force-delete and wait until the VPC is clear ──────
# List every ELBv2 (ALB/NLB) and classic ELB still in the VPC, delete them, and
# poll until none remain so their ENIs are released before Terraform deletes the
# subnets. Then sweep the controller-owned security groups that would otherwise
# block VPC deletion.
elbv2_arns() {
  aws_cli elbv2 describe-load-balancers \
    --query "LoadBalancers[?VpcId=='$VPC_ID'].LoadBalancerArn" --output text 2>/dev/null || true
}

classic_names() {
  aws_cli elb describe-load-balancers \
    --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].LoadBalancerName" --output text 2>/dev/null || true
}

aws_backstop() {
  local deadline=$(( $(date +%s) + 600 ))  # 10-minute cap
  while :; do
    local v2 classic
    v2="$(elbv2_arns)"
    classic="$(classic_names)"

    if [ -z "$v2" ] && [ -z "$classic" ]; then
      log "no load balancers remain in $VPC_ID"
      break
    fi

    for arn in $v2; do
      log "force-deleting ELBv2 $arn"
      aws_cli elbv2 delete-load-balancer --load-balancer-arn "$arn" 2>/dev/null || true
    done
    for name in $classic; do
      log "force-deleting classic ELB $name"
      aws_cli elb delete-load-balancer --load-balancer-name "$name" 2>/dev/null || true
    done

    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "warning: timed out waiting for load balancers to clear in $VPC_ID"
      break
    fi
    log "waiting for load balancer ENIs to release..."
    sleep 15
  done

  # Sweep controller-managed security groups left behind by any force-deleted
  # LBs (the graceful path deletes these itself). Best-effort — once the ENIs
  # are gone these become deletable; if still referenced, VPC destroy retries.
  local sgs
  sgs="$(aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true)"
  for sg in $sgs; do
    log "deleting orphaned LB security group $sg"
    aws_cli ec2 delete-security-group --group-id "$sg" 2>/dev/null || \
      log "  $sg still in use; leaving for VPC destroy to retry"
  done
}

graceful_cleanup
aws_backstop
log "done"
