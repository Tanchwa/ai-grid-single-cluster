# Configuration validation tests using mocked providers.
# command = apply with all-mocked providers is equivalent to a plan test:
# no real AWS/Talos/Helm API calls are made. Resources are created in the
# test's ephemeral state and destroyed when the test completes.
#
# Run with: terraform test -filter=tests/cluster_plan.tftest.hcl
# No AWS credentials or live cluster required.

mock_provider "aws" {
  # Non-null id and private_ip required by toset() in kubernetes-api-lb.tf and talos.tf.
  mock_resource "aws_instance" {
    defaults = {
      id         = "i-mock"
      private_ip = "10.0.1.10"
    }
  }

  # security_group_id feeds peer_security_group_ids in the worker module.
  mock_resource "aws_security_group" {
    defaults = {
      id = "sg-mock"
    }
  }

  # ARN format is validated by aws_route53_key_signing_key.key_management_service_arn.
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:ap-east-2:123456789012:key/mock-key-id"
    }
  }

  # ARN format is validated by aws_route53_query_log.cloudwatch_log_group_arn.
  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
    }
  }

  # ARN format is validated by aws_lb_listener.load_balancer_arn.
  # dns_name is used in talos.tf cluster_endpoint and as a string (no format validation).
  mock_resource "aws_lb" {
    defaults = {
      arn      = "arn:aws:elasticloadbalancing:ap-east-2:123456789012:loadbalancer/net/mock/1234567890abcdef"
      dns_name = "mock.ap-east-2.elb.amazonaws.com"
    }
  }

  # ARN format is validated by aws_lb_listener default_action.target_group_arn.
  mock_resource "aws_lb_target_group" {
    defaults = {
      arn = "arn:aws:elasticloadbalancing:ap-east-2:123456789012:targetgroup/mock/1234567890abcdef"
    }
  }

  # zone_id / id is used as hosted_zone_id in aws_route53_key_signing_key and
  # aws_route53_hosted_zone_dnssec, and as zone_id in aws_route53_query_log.
  mock_resource "aws_route53_zone" {
    defaults = {
      id      = "Z1234567890ABCDEFGHIJ"
      zone_id = "Z1234567890ABCDEFGHIJ"
    }
  }

  # account_id is interpolated into S3 bucket names and KMS key policies.
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  # aws_iam_policy_document generates JSON in-process; the mock returns null by
  # default, which fails the required assume_role_policy attribute validation.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

# providers.tf defines a second AWS provider alias for us-east-1 Route53 query
# logging. It must be mocked separately or Terraform attempts real credential
# resolution. The CloudWatch log group (for Route53 query logging) uses this
# alias, so its ARN mock must live here.
mock_provider "aws" {
  alias = "us_east_1"

  mock_resource "aws_cloudwatch_log_group" {
    defaults = {
      arn = "arn:aws:logs:us-east-1:123456789012:log-group:mock"
    }
  }
}

mock_provider "talos" {
  # providers.tf reads kubeconfig_raw and yamldecode()s it to configure the Helm
  # provider. The mock must return structurally valid kubeconfig YAML.
  mock_data "talos_cluster_kubeconfig" {
    defaults = {
      kubeconfig_raw = "clusters:\n- cluster:\n    server: https://10.0.1.10:6443\n    certificate-authority-data: dGVzdA==\n  name: test-single\nusers:\n- user:\n    client-certificate-data: dGVzdA==\n    client-key-data: dGVzdA==\n  name: admin\n"
    }
  }
}

mock_provider "helm" {}

# Override talos_machine_configuration data sources to bypass provider-side
# validation. The data source validates talos_version format (fails with the
# empty default "v") and validates config_patches content against the Talos
# schema. Overriding the data sources avoids calling the talos provider for
# these at all.
override_data {
  target = data.talos_machine_configuration.controlplane
  values = {
    machine_configuration = "# mock controlplane machine config"
  }
}

override_data {
  target = data.talos_machine_configuration.worker
  values = {
    machine_configuration = "# mock worker machine config"
  }
}

# providers.tf reads this file via file() during init — it must exist on disk.
variables {
  cluster_name           = "test-single"
  domain_name            = "asutliff-aws.com"
  global_network_space   = "10.0.0.0/16"
  github_repository_name = "argocd-core"
  talosconfig_path       = "tests/fixtures/talosconfig.yaml"

  # The talos provider's ValidateDataSourceConfig runs even with mock_provider
  # and rejects empty strings. Valid semver strings are required to pass the
  # provider-side schema validator.
  talos_version      = "v1.9.0"
  kubernetes_version = "v1.31.0"
}

# ─── ArgoCD Helm release ──────────────────────────────────────────────────────

run "argocd_helm_release" {
  command = apply

  assert {
    condition     = helm_release.argocd.name == "argo"
    error_message = "ArgoCD release name must be 'argo'"
  }

  assert {
    condition     = helm_release.argocd.chart == "argo-cd"
    error_message = "ArgoCD chart must be 'argo-cd'"
  }

  assert {
    condition     = helm_release.argocd.version == "9.2.3"
    error_message = "ArgoCD version must be '9.2.3'"
  }

  assert {
    condition     = helm_release.argocd.namespace == "argocd"
    error_message = "ArgoCD must be deployed in the 'argocd' namespace"
  }

  assert {
    condition     = helm_release.argocd.create_namespace == true
    error_message = "ArgoCD must create the namespace if it does not exist"
  }

  assert {
    condition     = helm_release.argocd.wait == true
    error_message = "ArgoCD release must wait for all pods to be ready before reporting success"
  }
}

# ─── ArgoCD App-of-Apps bootstrap ────────────────────────────────────────────

run "argocd_bootstrap_release" {
  command = apply

  assert {
    condition     = helm_release.argocd_bootstrap.name == "argo-app-of-apps-bootstrap"
    error_message = "ArgoCD bootstrap release name must be 'argo-app-of-apps-bootstrap'"
  }

  assert {
    condition     = helm_release.argocd_bootstrap.namespace == "argocd"
    error_message = "ArgoCD bootstrap must deploy into the 'argocd' namespace"
  }
}

# ─── Outputs ─────────────────────────────────────────────────────────────────

run "argocd_url_output" {
  command = apply

  assert {
    condition     = output.argocd_url == "https://argocd.asutliff-aws.com"
    error_message = "argocd_url must be https://argocd.<domain_name>"
  }
}

# ─── Cluster node configuration ───────────────────────────────────────────────

run "controlplane_count" {
  command = apply

  # With count = 3 and mock_resource defaults, all 3 instances are created.
  assert {
    condition     = length(module.cluster_controlplane_nodes.instance_private_ips) == 3
    error_message = "Cluster must provision exactly 3 controlplane instances"
  }
}
