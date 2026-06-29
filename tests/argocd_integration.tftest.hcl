# Integration test — deploys the full cluster and validates ArgoCD is available.
#
# Prerequisites:
#   1. AWS credentials configured in the environment (AWS_PROFILE or AWS_ACCESS_KEY_ID etc.)
#   2. A talosconfig file at the path given by talosconfig_path.
#      On a fresh environment, generate this before running the test:
#        talosctl gen config <cluster_name> https://<nlb-dns>:6443 --output-dir /tmp/talos
#        export TF_VAR_talosconfig_path=/tmp/talos/talosconfig
#   3. The Terraform VPC module cached locally (terraform init).
#
# Run with:
#   terraform test -filter=tests/argocd_integration.tftest.hcl -var-file=test.tfvars.json
#
# WARNING: This test performs a real apply against AWS and will destroy all
# resources when the test completes. Use a dedicated test account.

variables {
  cluster_name           = "test-single"
  domain_name            = "asutliff-aws.com"
  global_network_space   = "10.0.0.0/16"
  github_repository_name = "argocd-core"
}

# ─── Stage 1: cluster infrastructure ─────────────────────────────────────────
# Nodes and networking must exist before the Talos bootstrap data source can
# retrieve a kubeconfig to hand to the Helm provider.

run "deploy_cluster" {
  command = apply

  assert {
    condition     = length(module.cluster_controlplane_nodes.instance_private_ips) == 3
    error_message = "Expected 3 controlplane nodes after apply"
  }

  assert {
    condition     = length(module.cluster_worker_nodes.instance_ids) == 0
    error_message = "Worker nodes are managed by an ASG; instance_ids should be empty for worker module"
  }

  assert {
    condition     = module.cluster_worker_nodes.asg_name != null
    error_message = "Worker ASG must be created"
  }
}

# ─── Stage 2: ArgoCD availability ────────────────────────────────────────────
# helm_release.wait = true, so a "deployed" status guarantees all ArgoCD pods
# passed their readiness checks before Terraform reported success.

run "argocd_available" {
  command = apply

  assert {
    condition     = helm_release.argocd.status == "deployed"
    error_message = "ArgoCD Helm release must reach 'deployed' status (wait=true ensures pods are ready)"
  }

  assert {
    condition     = helm_release.argocd_bootstrap.status == "deployed"
    error_message = "ArgoCD App-of-Apps bootstrap Helm release must reach 'deployed' status"
  }

  assert {
    condition     = output.argocd_url == "https://argocd.asutliff-aws.com"
    error_message = "argocd_url output must be https://argocd.<domain_name>"
  }

  assert {
    condition     = output.lb_controller_role_arn != null && output.lb_controller_role_arn != ""
    error_message = "AWS Load Balancer Controller IRSA role must be provisioned"
  }

  assert {
    condition     = output.cert_manager_role_arn != null && output.cert_manager_role_arn != ""
    error_message = "cert-manager IRSA role must be provisioned"
  }
}
