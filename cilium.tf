resource "helm_release" "cilium" {
  name             = "cilium"
  repository       = "https://helm.cilium.io"
  chart            = "cilium"
  version          = var.cilium_version
  namespace        = "kube-system"
  create_namespace = false

  values = [yamlencode({
    kubeProxyReplacement = true
    k8sServiceHost       = "localhost"
    # kubePrism port
    k8sServicePort = 7445

    securityContext = {
      privileged = true

      capabilities = {
        # enable all except for SYS_MODULE, which is not supported in Talos
        ciliumAgent = [
          "CHOWN",
          "KILL",
          "NET_ADMIN",
          "NET_RAW",
          "IPC_LOCK",
          "SYS_ADMIN",
          "SYS_RESOURCE",
          "DAC_OVERRIDE",
          "FOWNER",
          "SETGID",
          "SETUID",
          "SYSLOG"
        ]
        cleanCiliumState = [
          "NET_ADMIN",
          "SYS_ADMIN",
          "SYS_RESOURCE"
        ]
      }
    }

    # Pod IPAM — cluster-pool carves per-node /24 slices from the pod CIDR.
    ipam = {
      mode = "kubernetes"
    }

    # Hubble — network observability, relay for multi-node aggregation, UI for
    # the dashboard. Relay and UI are opt-in so they don't run in production
    # without intention; both are enabled here since Hubble was explicitly requested.
    hubble = {
      enabled = true
      relay = {
        enabled = true
      }
      ui = {
        enabled = true
      }
    }

    cgroup = {
      autoMount = {
        enabled = false
      }
      hostRoot = "/sys/fs/cgroup"
    }

    # BGP Control Plane — advertises LoadBalancer and pod CIDRs via BGP.
    # Requires CiliumBGPPeeringPolicy (v1) or CiliumBGPClusterConfig (v2) CRDs
    # to actually peer; dormant without them, so AWS LB Controller is unaffected.
    # LB-IPAM pool assignment also only activates per CiliumLoadBalancerIPPool
    # resources, meaning AWS LB Controller retains full ownership of services
    # annotated with service.beta.kubernetes.io/aws-load-balancer-* keys.
    bgpControlPlane = {
      enabled = var.cilium_bgp_enabled
    }

    # Announce LoadBalancer IPs and pod CIDRs over BGP when peers are configured.
    bgp = {
      announce = {
        loadbalancerIPs = var.cilium_bgp_enabled
        podCIDR         = var.cilium_bgp_enabled
      }
    }

    # Remove the node.cilium.io/agent-not-ready taint automatically once Cilium
    # is running on each node so pods can be scheduled.
    operator = {
      removeCiliumNodeTaints = true
    }

    # TC-level fallback for ClusterIP access from the host network namespace.
    # The kube-apiserver (hostNetwork static pod) on Talos runs in a cgroup
    # namespace that Cilium's socket LB hook cannot see, so webhook calls to
    # ClusterIP services time out. This attaches a TC BPF program to the host's
    # physical interface that DNATs ClusterIP traffic at the packet level,
    # bypassing the cgroup interception requirement.
    bpf = {
      lbExternalClusterIP = true
    }
  })]

  timeout = 480

  depends_on = [talos_cluster_kubeconfig.this, module.tailscale_gateway]
}
