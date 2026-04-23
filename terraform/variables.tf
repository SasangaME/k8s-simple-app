variable "project" {
  type        = string
  default     = "k8s-simple-app"
  description = "Project / repo name. Used as the name prefix for all AWS resources."
}

variable "region" {
  type        = string
  default     = "us-east-1"
  description = "AWS region to deploy into."
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.101.0/24", "10.20.102.0/24"]
}

variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_desired_size" {
  type    = number
  default = 2
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "tags" {
  type = map(string)
  default = {
    Project   = "k8s-simple-app"
    ManagedBy = "terraform"
  }
}
