terraform {
  required_version = ">= 1.8"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.7"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

# Required for Route53 query logging — CloudWatch log groups for Route53 must be in us-east-1.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile
}

provider "talos" {}

provider "tls" {}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ─── Kubeconfig retrieval ─────────────────────────────────────────────────────
# Reads from the talos_cluster_kubeconfig resource created in talos.tf after
# bootstrap. On a fresh cluster, apply talos.tf resources first (-target or
# the dedicated cluster stage), then run a full apply to configure Helm.
locals {
  _cluster_kube = yamldecode(talos_cluster_kubeconfig.this.kubeconfig_raw)
}

# ─── Helm provider ────────────────────────────────────────────────────────────

provider "helm" {
  kubernetes {
    host                   = local._cluster_kube.clusters[0].cluster.server
    cluster_ca_certificate = base64decode(local._cluster_kube.clusters[0].cluster["certificate-authority-data"])
    client_certificate     = base64decode(local._cluster_kube.users[0].user["client-certificate-data"])
    client_key             = base64decode(local._cluster_kube.users[0].user["client-key-data"])
  }
}
