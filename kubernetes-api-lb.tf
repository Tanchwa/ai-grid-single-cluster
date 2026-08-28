resource "aws_lb" "k8s_api" {
  # checkov:skip=CKV_AWS_150:enabling deletion protection makes no sense with terraform
  name                             = "${var.cluster_name}-api-lb"
  internal                         = true
  load_balancer_type               = "network"
  subnets                          = module.vpc.private_subnets
  enable_cross_zone_load_balancing = true

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.id
    prefix  = "${var.cluster_name}-api-lb"
    enabled = true
  }

  tags = {
    Name = "${var.cluster_name}-api-lb"
  }

  depends_on = [aws_s3_bucket_policy.lb_logs]
}

resource "aws_lb" "k8s_api_public" {
  # checkov:skip=CKV_AWS_150:enabling deletion protection makes no sense with terraform
  name                             = "${var.cluster_name}-api-lb-public"
  internal                         = false
  load_balancer_type               = "network"
  subnets                          = module.vpc.public_subnets
  enable_cross_zone_load_balancing = true

  access_logs {
    bucket  = aws_s3_bucket.lb_logs.id
    prefix  = "${var.cluster_name}-api-lb-public"
    enabled = true
  }
  tags       = { Name = "${var.cluster_name}-api-lb-public" }
  depends_on = [aws_s3_bucket_policy.lb_logs]
}


resource "aws_lb_target_group" "k8s_api" {
  name        = "${var.cluster_name}-api-tg"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    interval            = 30
    port                = "6443"
    protocol            = "TCP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.cluster_name}-api-tg"
  }
}

resource "aws_lb_target_group" "k8s_api_public" {
  name        = "${var.cluster_name}-api-tg-public"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = module.vpc.vpc_id
  target_type = "instance"

  health_check {
    enabled             = true
    interval            = 30
    port                = "6443"
    protocol            = "TCP"
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.cluster_name}-api-tg-public"
  }
}

resource "aws_lb_listener" "k8s_api" {
  load_balancer_arn = aws_lb.k8s_api.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_api.arn
  }
}

resource "aws_lb_listener" "k8s_api_public" {
  load_balancer_arn = aws_lb.k8s_api_public.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.k8s_api_public.arn
  }
}

resource "aws_lb_target_group_attachment" "k8s_api" {
  # Use the list index as the for_each key so the key is static and known at
  # plan time. toset(instance_ids) fails during plan because instance IDs are
  # computed and unknown until apply.
  for_each         = { for idx, id in module.cluster_controlplane_nodes.instance_ids : tostring(idx) => id }
  target_group_arn = aws_lb_target_group.k8s_api.arn
  target_id        = each.value
  port             = 6443
}

resource "aws_lb_target_group_attachment" "k8s_api_public" {
  for_each         = { for idx, id in module.cluster_controlplane_nodes.instance_ids : tostring(idx) => id }
  target_group_arn = aws_lb_target_group.k8s_api_public.arn
  target_id        = each.value
  port             = 6443
}
