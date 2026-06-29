output "security_group_id" {
  description = "ID of the node security group. Pass this as peer_security_group_ids to the other node group module."
  value       = aws_security_group.nodes.id
}

output "security_group_arn" {
  description = "ARN of the node security group."
  value       = aws_security_group.nodes.arn
}

output "instance_ids" {
  description = "EC2 instance IDs (control plane only)."
  value       = aws_instance.control_plane[*].id
}

output "instance_private_ips" {
  description = "Private IP addresses of control plane instances. Use the first IP as the Talos bootstrap endpoint."
  value       = aws_instance.control_plane[*].private_ip
}

output "asg_name" {
  description = "Auto Scaling Group name (worker nodes only)."
  value       = length(aws_autoscaling_group.workers) > 0 ? aws_autoscaling_group.workers[0].name : null
}

output "asg_arn" {
  description = "Auto Scaling Group ARN (worker nodes only)."
  value       = length(aws_autoscaling_group.workers) > 0 ? aws_autoscaling_group.workers[0].arn : null
}

output "launch_template_id" {
  description = "ID of the EC2 launch template."
  value       = aws_launch_template.this.id
}

output "launch_template_latest_version" {
  description = "Latest version number of the launch template."
  value       = aws_launch_template.this.latest_version
}

output "iam_role_arn" {
  description = "ARN of the node IAM role (null if create_iam_resources = false)."
  value       = var.create_iam_resources ? aws_iam_role.nodes[0].arn : null
}

output "iam_instance_profile_name" {
  description = "Name of the IAM instance profile attached to nodes."
  value       = local.instance_profile_name
}

output "lb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IRSA role. Annotate the controller's ServiceAccount with this value."
  value       = var.create_lb_controller_irsa ? aws_iam_role.lb_controller[0].arn : null
}

output "external_dns_role_arn" {
  description = "ARN of the external-dns IRSA role. Annotate the external-dns ServiceAccount with this value."
  value       = var.create_external_dns_irsa ? aws_iam_role.external_dns[0].arn : null
}
