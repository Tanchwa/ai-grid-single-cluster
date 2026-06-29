locals {
  is_control_plane = var.node_role == "controlplane"

  # Tags applied to every resource in this module.
  common_tags = merge(
    {
      "kubernetes.io/cluster/${var.cluster_name}" = "owned"
      "talos.dev/cluster"                         = var.cluster_name
      "talos.dev/role"                            = var.node_role
    },
    var.tags
  )

  # Tags propagated to EC2 instances and their volumes.
  instance_tags = merge(local.common_tags, {
    Name = "${var.cluster_name}-${var.node_role}"
  })

  instance_profile_name = var.create_iam_resources ? aws_iam_instance_profile.nodes[0].name : var.iam_instance_profile_name
}

# ─── Launch template ─────────────────────────────────────────────────────────


resource "aws_launch_template" "this" {
  # checkov:skip=CKV_AWS_341:hop_limit 2 is required for Kubernetes pods to reach IMDS for IRSA token exchange

  name_prefix   = "${var.cluster_name}-${var.node_role}-"
  image_id      = var.ami_id
  instance_type = var.instance_type
  ebs_optimized = var.ebs_optimized

  # Talos machine config is passed directly as user data (base64-encoded YAML).
  user_data = var.talos_machine_config

  monitoring {
    enabled = var.enable_detailed_monitoring
  }

  iam_instance_profile {
    name = local.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups = concat(
      [aws_security_group.nodes.id],
    )
    delete_on_termination = true
  }

  block_device_mappings {
    device_name = "dev/xvda"
    ebs {
      volume_size           = var.root_volume_size_gb
      volume_type           = var.root_volume_type
      delete_on_termination = true
      encrypted             = true
    }
  }
  block_device_mappings {
    device_name = "dev/xvdb"
    ebs {
      volume_size           = var.longhorn_volume_size_gb
      volume_type           = var.longhorn_volume_type
      delete_on_termination = true
      encrypted             = true
    }
  }


  # IMDSv2 required; hop limit 2 so pods can reach IMDS via the node.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "network-interface"
    tags          = local.common_tags
  }

  dynamic "instance_market_options" {
    for_each = var.use_spot ? [1] : []
    content {
      market_type = "spot"
      spot_options {
        max_price                      = var.spot_max_price
        instance_interruption_behavior = "terminate"
      }
    }
  }

  tags = local.common_tags

  lifecycle {
    create_before_destroy = true
  }
}

# ─── Control plane: static instances (stable etcd membership) ────────────────

resource "aws_instance" "control_plane" {
  count = local.is_control_plane ? var.instance_count : 0

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # Spread across subnets for multi-AZ etcd quorum.
  subnet_id            = var.subnet_ids[count.index % length(var.subnet_ids)]
  monitoring           = true
  ebs_optimized        = var.ebs_optimized
  iam_instance_profile = local.instance_profile_name

  # IMDSv2 required; hop limit 2 so pods can reach IMDS via the node.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    encrypted             = true
    volume_size           = var.root_volume_size_gb
    volume_type           = var.root_volume_type
    delete_on_termination = true
  }

  tags = merge(local.instance_tags, {
    Name = "${var.cluster_name}-controlplane-${count.index}"
  })

  lifecycle {
    # Prevent accidental replacement of etcd members.
    ignore_changes = [launch_template]
  }
}

# ─── Workers: Auto Scaling Group ─────────────────────────────────────────────

resource "aws_autoscaling_group" "workers" {
  count = local.is_control_plane ? 0 : 1

  name                = "${var.cluster_name}-worker"
  vpc_zone_identifier = var.subnet_ids

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.instance_count

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Required so the Cluster Autoscaler and AWS LB Controller can discover nodes.
  dynamic "tag" {
    for_each = merge(local.instance_tags, {
      # Cluster Autoscaler discovery tags
      "k8s.io/cluster-autoscaler/enabled"             = "true"
      "k8s.io/cluster-autoscaler/${var.cluster_name}" = "owned"
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}
