# ─── EKS Pod Identity Webhook ────────────────────────────────────────────────
# Mutates pods whose ServiceAccount carries an eks.amazonaws.com/role-arn
# annotation: injects the projected token volume and AWS_* env vars that IRSA
# requires. Must be installed before any workload that needs IRSA (e.g. the LB
# controller). Requires cert-manager for its admission webhook TLS certificate.

resource "helm_release" "pod_identity_webhook" {
  name             = "amazon-eks-pod-identity-webhook"
  repository       = "https://jkroepke.github.io/helm-charts/"
  chart            = "amazon-eks-pod-identity-webhook"
  version          = "2.6.5"
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "config.defaultAwsRegion"
    value = var.aws_region
  }

  depends_on = [talos_cluster_kubeconfig.this, helm_release.cert_manager]
}

# ─── AWS Load Balancer Controller ────────────────────────────────────────────

resource "helm_release" "lb_controller" {
  name             = "aws-load-balancer-controller"
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-load-balancer-controller"
  version          = "3.4.2"
  namespace        = "kube-system"
  create_namespace = false

  set {
    name  = "clusterName"
    value = var.cluster_name
  }
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }
  set {
    name  = "serviceAccount.create"
    value = "true"
  }
  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }
  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.cluster_controlplane_nodes.lb_controller_role_arn
  }

  values = [
    yamlencode({
      hostNetwork = true
    })
  ]

  depends_on = [talos_cluster_kubeconfig.this, helm_release.pod_identity_webhook]
}
