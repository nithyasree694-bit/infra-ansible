########################################
# Terraform & Provider Configuration
########################################
terraform {
  required_version = ">= 1.3.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

########################################
# Variables
########################################
variable "aws_region" {
  type    = string
  default = "ap-south-1"
}

variable "environment" {
  type    = string
  default = "production"
}

variable "project_name" {
  type    = string
  default = "pipe"
}

variable "vpc_id" {
  type        = string
  description = "vpc-0eff6848d8ed2be0b."
}

variable "subnet_id" {
  type        = string
  description = "Optional: Subnet to use. If empty, the first available subnet in the VPC will be used."
  default     = ""
}

variable "reuse_existing_sg" {
  type    = bool
  default = false
}

variable "existing_sg_name" {
  type    = string
  default = "web-firewall"
}

# Key pair management
variable "keypair_name" {
  type    = string
  default = "25-hp-mumbai"
}

variable "create_key_pair" {
  type    = bool
  default = true
}

variable "public_key_openssh" {
  type    = string
  default = ""
}

variable "ansible_user" {
  type    = string
  default = "ubuntu"
}

variable "apache_instance_count" {
  type    = number
  default = 2
}

variable "nginx_instance_count" {
  type    = number
  default = 2
}

variable "instance_type" {
  type    = string
  default = "t3.micro"
}

########################################
# Locals
########################################
locals {
  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

########################################
# Data Sources
########################################
data "aws_vpc" "selected" {
  id = var.vpc_id
}

data "aws_subnets" "in_vpc" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

########################################
# Derived Selections
########################################
locals {
  selected_subnet_id = var.subnet_id != "" ? var.subnet_id :
    (length(data.aws_subnets.in_vpc.ids) > 0 ? data.aws_subnets.in_vpc.ids[0] : "")
}

########################################
# Key Pair Management
########################################
resource "tls_private_key" "generated" {
  count     = var.create_key_pair && var.public_key_openssh == "" ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  count      = var.create_key_pair ? 1 : 0
  key_name   = var.keypair_name
  public_key = var.public_key_openssh != "" ? var.public_key_openssh : tls_private_key.generated[0].public_key_openssh
}

resource "local_file" "generated_pem" {
  count           = var.create_key_pair && var.public_key_openssh == "" ? 1 : 0
  filename        = "${path.module}/generated_${var.keypair_name}.pem"
  content         = tls_private_key.generated[0].private_key_pem
  file_permission = "0600"
}

locals {
  selected_key_name = var.create_key_pair ? aws_key_pair.this[0].key_name : var.keypair_name
}

########################################
# Security Group
########################################
resource "aws_security_group" "web" {
  name        = "${var.project_name}-web-sg-${var.environment}"
  description = "Web security group"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description = "SSH from Jenkins"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["3.110.85.249/32"]
  }

