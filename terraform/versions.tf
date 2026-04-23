terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.4"
    }
  }

  # Uncomment after creating the bucket + table once.
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "k8s-simple-app/terraform.tfstate"
  #   region         = "us-east-1"
  #   dynamodb_table = "your-tfstate-lock"
  #   encrypt        = true
  # }
}
