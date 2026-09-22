# ─── Destroy-time load balancer cleanup ──────────────────────────────────────
# The AWS Load Balancer Controller and CCM create NLBs/ALBs outside Terraform
# state, in response to Service type=LoadBalancer / Ingress objects that ArgoCD
# deploys. Terraform can't see them, so on `terraform destroy` it would delete
# the VPC while those load balancers still hold ENIs in the subnets and own
# security groups in the VPC — subnet/SG deletion then blocks and times out.
#
# This runs a destroy-time provisioner that reaps those load balancers first,
# then deletes the security groups the LB controller created — revoking the
# rules it injected into the Terraform-managed node SGs that reference them,
# since AWS refuses to delete a group another group's rule still points at.
# Ordering is enforced by the dependency graph: because this resource depends on
# the helm releases AND the VPC, Terraform destroys it BEFORE any of them
# (destroy order is the reverse of create order). So the cleanup runs while
# ArgoCD and the LB controller are still alive to process the deletions, and
# finishes before the VPC teardown begins. See scripts/destroy-lb-cleanup.sh.

resource "null_resource" "lb_cleanup" {
  # Stashed in triggers so the destroy-time provisioner can read them via `self`
  # (destroy provisioners can't reference vars or other resources). Referencing
  # module.vpc here also makes this resource depend on the VPC, so it is torn
  # down before the VPC.
  triggers = {
    vpc_id       = module.vpc.vpc_id
    aws_region   = var.aws_region
    aws_profile  = var.aws_profile
    cluster_name = var.cluster_name
    kubeconfig   = talos_cluster_kubeconfig.this.kubeconfig_raw
  }

  depends_on = [
    helm_release.lb_controller,
    helm_release.aws_ccm,
    helm_release.argocd,
    helm_release.argocd_bootstrap,
  ]

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/usr/bin/env", "bash", "-c"]

    environment = {
      KUBECONFIG_CONTENT = self.triggers.kubeconfig
      VPC_ID             = self.triggers.vpc_id
      AWS_REGION         = self.triggers.aws_region
      AWS_PROFILE        = self.triggers.aws_profile
      CLUSTER_NAME       = self.triggers.cluster_name
    }

    command = "bash ${path.module}/scripts/destroy-lb-cleanup.sh"
  }
}
