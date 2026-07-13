# ─── Node security group ─────────────────────────────────────────────────────

resource "aws_security_group" "nodes" {
  name        = "${var.cluster_name}-${var.node_role}-nodes"
  description = "Talos ${var.node_role} nodes for cluster ${var.cluster_name}"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${var.node_role}-nodes"
  })
}

# ─── Intra-group traffic ──────────────────────────────────────────────────────

# All nodes within this group can reach each other freely (etcd, kubelet, Cilium eBPF).
resource "aws_vpc_security_group_ingress_rule" "self_all" {
  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = aws_security_group.nodes.id
  ip_protocol                  = "-1"
  description                  = "All traffic within ${var.node_role} group"
  tags                         = local.common_tags
}

# Allow full traffic from peer node groups (e.g., worker → control plane API, control plane → kubelet).
resource "aws_vpc_security_group_ingress_rule" "peer_all" {
  # Use the list index as the for_each key so the key is static and known at
  # plan time. toset(peer_security_group_ids) fails during plan because SG IDs
  # are computed and unknown until the peer module's security group is created.
  for_each = { for idx, sg_id in var.peer_security_group_ids : tostring(idx) => sg_id }

  security_group_id            = aws_security_group.nodes.id
  referenced_security_group_id = each.value
  ip_protocol                  = "-1"
  description                  = "All traffic from peer node group"
  tags                         = local.common_tags
}

# ─── Kubernetes API server (control plane only) ───────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "kube_api" {
  for_each = local.is_control_plane ? toset(var.kube_api_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  from_port         = 6443
  to_port           = 6443
  ip_protocol       = "tcp"
  description       = "Kubernetes API server"
  tags              = local.common_tags
}

# ─── Talos API ────────────────────────────────────────────────────────────────

# apid: used by talosctl for all management operations.
resource "aws_vpc_security_group_ingress_rule" "talos_apid" {
  for_each = toset(var.talos_api_allowed_cidrs)

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  from_port         = 50000
  to_port           = 50000
  ip_protocol       = "tcp"
  description       = "Talos apid (talosctl)"
  tags              = local.common_tags
}

# trustd: inter-node trust establishment during bootstrap and join.
resource "aws_vpc_security_group_ingress_rule" "talos_trustd" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 50001
  to_port           = 50001
  ip_protocol       = "tcp"
  description       = "Talos trustd (node bootstrap/join)"
  tags              = local.common_tags
}

# ─── etcd (control plane only) ───────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "etcd" {
  count = local.is_control_plane ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 2379
  to_port           = 2380
  ip_protocol       = "tcp"
  description       = "etcd client (2379) and peer (2380)"
  tags              = local.common_tags
}

# ─── Kubelet ─────────────────────────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "kubelet" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 10250
  to_port           = 10250
  ip_protocol       = "tcp"
  description       = "Kubelet API (metrics-server, kubectl exec/logs)"
  tags              = local.common_tags
}

# ─── Cilium ───────────────────────────────────────────────────────────────────

# Health check probe between every pair of Cilium agents.
resource "aws_vpc_security_group_ingress_rule" "cilium_health" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 4240
  to_port           = 4240
  ip_protocol       = "tcp"
  description       = "Cilium health check"
  tags              = local.common_tags
}

# Hubble server (in-node gRPC API).
resource "aws_vpc_security_group_ingress_rule" "hubble_server" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 4244
  to_port           = 4244
  ip_protocol       = "tcp"
  description       = "Hubble server"
  tags              = local.common_tags
}

# Hubble Relay aggregates Hubble data across nodes.
resource "aws_vpc_security_group_ingress_rule" "hubble_relay" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 4245
  to_port           = 4245
  ip_protocol       = "tcp"
  description       = "Hubble Relay"
  tags              = local.common_tags
}

# Prometheus metrics: cilium-agent (9962), cilium-operator (9963), Hubble (9964).
resource "aws_vpc_security_group_ingress_rule" "cilium_metrics" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 9962
  to_port           = 9964
  ip_protocol       = "tcp"
  description       = "Cilium/Hubble Prometheus metrics"
  tags              = local.common_tags
}

# VXLAN overlay – only needed when routingMode is NOT 'native'.
resource "aws_vpc_security_group_ingress_rule" "cilium_vxlan" {
  count = var.cilium_enable_vxlan ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 8472
  to_port           = 8472
  ip_protocol       = "udp"
  description       = "Cilium VXLAN overlay"
  tags              = local.common_tags
}

# WireGuard encryption between nodes (Cilium transparent encryption).
resource "aws_vpc_security_group_ingress_rule" "cilium_wireguard" {
  count = var.cilium_enable_wireguard ? 1 : 0

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = 51871
  to_port           = 51871
  ip_protocol       = "udp"
  description       = "Cilium WireGuard encryption"
  tags              = local.common_tags
}

# ─── NodePort services ────────────────────────────────────────────────────────
# ALB/NLB target groups route to NodePorts; nodeport_allowed_cidr scopes this.

resource "aws_vpc_security_group_ingress_rule" "nodeport_tcp" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.nodeport_allowed_cidr
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  description       = "NodePort services (TCP) - ALB/NLB target group access"
  tags              = local.common_tags
}

resource "aws_vpc_security_group_ingress_rule" "nodeport_udp" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.nodeport_allowed_cidr
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "udp"
  description       = "NodePort services (UDP)"
  tags              = local.common_tags
}

# ─── Rancher ──────────────────────────────────────────────────────────────────
# RKE2 supervisor port used during cluster import / node registration.
# The cattle-cluster-agent connects outbound, but Rancher may also probe inbound.

resource "aws_vpc_security_group_ingress_rule" "rancher_supervisor" {
  for_each = toset(var.rancher_server_cidrs)

  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = each.value
  from_port         = 9345
  to_port           = 9345
  ip_protocol       = "tcp"
  description       = "Rancher/RKE2 supervisor API"
  tags              = local.common_tags
}

# ─── ICMP ────────────────────────────────────────────────────────────────────

resource "aws_vpc_security_group_ingress_rule" "icmp" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = var.vpc_cidr
  from_port         = -1
  to_port           = -1
  ip_protocol       = "icmp"
  description       = "ICMP (health checks, MTU path discovery)"
  tags              = local.common_tags
}

# ─── Egress ───────────────────────────────────────────────────────────────────

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.nodes.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all egress"
  tags              = local.common_tags
}
