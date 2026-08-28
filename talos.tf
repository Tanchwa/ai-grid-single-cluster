resource "talos_machine_secrets" "this" {}

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  machine_type       = "controlplane"
  cluster_endpoint   = "https://${aws_lb.k8s_api.dns_name}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
      }
      cluster = {
        allowSchedulingOnControlPlanes = false
        apiServer = {
          certSANs = [aws_lb.k8s_api.dns_name, aws_lb.k8s_api_public.dns_name]
          extraArgs = {
            "service-account-issuer" = local.oidc_issuer_url
          }
        }
        serviceAccount = {
          key = base64encode(tls_private_key.sa_signing.private_key_pem)
        }
      }
    }),
    file("${path.module}/node-config/controlplane.yaml"),
    file("${path.module}/node-config/cluster.yaml")
  ]
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  machine_type       = "worker"
  cluster_endpoint   = "https://${aws_lb.k8s_api.dns_name}:6443"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  talos_version      = var.talos_version
  kubernetes_version = var.kubernetes_version

  config_patches = [
    yamlencode({
      machine = {
        install = {
          image = "ghcr.io/siderolabs/installer:${var.talos_version}"
        }
      }
    }),
    file("${path.module}/node-config/worker.yaml"),
    file("${path.module}/node-config/longhorn-volume.yaml")
  ]
}

# Push the generated config to each controlplane node via the Talos API.
# Workers receive their config through the ASG launch template user_data.
resource "talos_machine_configuration_apply" "controlplane" {
  # Use the list index as the for_each key so the key is static and known at
  # plan time. toset(private_ips) fails during plan because IPs are computed
  # and unknown until the EC2 instances are created.
  for_each = { for idx, ip in module.cluster_controlplane_nodes.instance_private_ips : tostring(idx) => ip }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value
  endpoint                    = each.value
}

# Bootstrap etcd on the first controlplane node.
# Remaining nodes join automatically via trustd (port 50001).
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cluster_bootstrap_ip
  endpoint             = local.cluster_bootstrap_ip

  depends_on = [talos_machine_configuration_apply.controlplane]
}

# talos_cluster_health was removed: worker nodes are managed by an ASG so their
# IPs aren't reliably known at apply time. Including booting nodes caused apid
# timeouts and boot-sequence failures. A fixed sleep is simpler and sufficient.
resource "time_sleep" "wait_for_cluster" {
  create_duration = "3m"
  depends_on      = [talos_machine_bootstrap.this]
}

resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.cluster_bootstrap_ip
  endpoint             = local.cluster_bootstrap_ip

  depends_on = [time_sleep.wait_for_cluster]
}

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = module.cluster_controlplane_nodes.instance_private_ips
  nodes                = module.cluster_controlplane_nodes.instance_private_ips
}
