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
# left — e.g. if the cluster is already unreachable — followed by a sweep of the
# security groups the AWS Load Balancer Controller created (and of the rules in
# the node security groups that reference them), so the VPC teardown never
# blocks on an orphaned load balancer or security group.
set -euo pipefail

: "${VPC_ID:?VPC_ID is required}"
: "${AWS_REGION:?AWS_REGION is required}"
: "${CLUSTER_NAME:?CLUSTER_NAME is required}"

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
# subnets. Phase 3 then sweeps the security groups they leave behind.
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
}

# ─── Phase 3: sweep the AWS Load Balancer Controller's security groups ────────
# The controller creates security groups outside Terraform state and they
# outlive a force-deleted load balancer:
#   * per-ALB frontend SGs        tag elbv2.k8s.aws/cluster (+ ingress.k8s.aws/*
#                                 for groups made by the legacy ingress controller)
#   * the shared backend SG       name k8s-traffic-<cluster>-<hash>,
#                                 tag elbv2.k8s.aws/resource=backend
#   * per-service backend SGs     tag elbv2.k8s.aws/resource=<stack>/<resource>
# Deleting them is not enough on its own: the controller also injects ingress
# rules into the Terraform-managed *node* SGs that reference these groups, and
# AWS refuses to delete a security group while another group's rule points at
# it (DependencyViolation). So revoke every referencing rule first, then delete.

# Security groups in the VPC that the LB controller owns. Scoped by VPC (one VPC
# per cluster) plus controller-specific tag keys / the shared-backend name
# prefix, so Terraform-managed node SGs are never matched.
controller_sgs() {
  {
    aws_cli ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=tag-key,Values=elbv2.k8s.aws/cluster,elbv2.k8s.aws/resource,ingress.k8s.aws/cluster,ingress.k8s.aws/stack,ingress.k8s.aws/resource" \
      --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true
    aws_cli ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$VPC_ID" \
        "Name=group-name,Values=k8s-traffic-$CLUSTER_NAME-*" \
      --query "SecurityGroups[].GroupId" --output text 2>/dev/null || true
  } | tr '[:space:]' '\n' | { grep -E '^sg-' || true; } | sort -u
}

# Every security group in the VPC — the search space for rules pointing at the
# groups we're about to delete (describe-security-group-rules has no vpc-id
# filter, so the group ids have to be passed explicitly).
vpc_sg_ids() {
  aws_cli ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" \
    --query "SecurityGroups[].GroupId" --output text 2>/dev/null | tr '[:space:]' ',' | sed 's/,$//'
}

# Revoke every rule in the VPC (in any security group, including the node SGs)
# that references $1, so the group becomes deletable.
revoke_references_to() {
  local target="$1" all="$2" group rule egress
  [ -z "$all" ] && return 0
  aws_cli ec2 describe-security-group-rules \
    --filters "Name=group-id,Values=$all" \
    --query "SecurityGroupRules[?ReferencedGroupInfo.GroupId=='$target'].[GroupId,SecurityGroupRuleId,IsEgress]" \
    --output text 2>/dev/null | while read -r group rule egress; do
      [ -z "$rule" ] && continue
      # Self-references die with the group; only cross-group rules block it.
      [ "$group" = "$target" ] && continue
      log "  revoking rule $rule in $group (references $target)"
      if [ "$egress" = "True" ]; then
        aws_cli ec2 revoke-security-group-egress \
          --group-id "$group" --security-group-rule-ids "$rule" >/dev/null 2>&1 || \
          log "  warning: could not revoke $rule in $group"
      else
        aws_cli ec2 revoke-security-group-ingress \
          --group-id "$group" --security-group-rule-ids "$rule" >/dev/null 2>&1 || \
          log "  warning: could not revoke $rule in $group"
      fi
    done
}

# ENIs still holding the group — the other DependencyViolation cause. These
# drain on their own once the load balancer is gone, hence the retry loop.
sg_attachments() {
  aws_cli ec2 describe-network-interfaces \
    --filters "Name=group-id,Values=$1" \
    --query "NetworkInterfaces[].[NetworkInterfaceId,Description]" --output text 2>/dev/null || true
}

sg_cleanup() {
  local sgs
  sgs="$(controller_sgs)"
  if [ -z "$sgs" ]; then
    log "no controller-managed security groups in $VPC_ID"
    return 0
  fi
  log "found controller-managed security groups: $(echo "$sgs" | tr '\n' ' ')"

  local deadline=$(( $(date +%s) + 600 ))  # 10-minute cap
  while :; do
    local all remaining="" sg attached
    all="$(vpc_sg_ids)"

    for sg in $sgs; do
      # Gone already (deleted by the controller on the graceful path, or by a
      # previous pass) — nothing to do.
      if ! aws_cli ec2 describe-security-groups --group-ids "$sg" >/dev/null 2>&1; then
        continue
      fi
      revoke_references_to "$sg" "$all"
      log "deleting security group $sg"
      if aws_cli ec2 delete-security-group --group-id "$sg" >/dev/null 2>&1; then
        continue
      fi
      attached="$(sg_attachments "$sg")"
      if [ -n "$attached" ]; then
        log "  $sg still attached to ENIs:"
        echo "$attached" | while read -r eni desc; do log "    $eni ${desc:-}"; done
      else
        log "  $sg not deletable yet; will retry"
      fi
      remaining+="$sg"$'\n'
    done

    sgs="$(printf '%s' "$remaining" | grep -E '^sg-' || true)"
    if [ -z "$sgs" ]; then
      log "all controller-managed security groups deleted"
      break
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      log "warning: timed out deleting security groups: $(echo "$sgs" | tr '\n' ' ')"
      log "warning: VPC destroy may fail — delete them manually if it does"
      break
    fi
    log "waiting for security group dependencies to clear..."
    sleep 15
  done
}

graceful_cleanup
aws_backstop
sg_cleanup
log "done"
