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
variable "aws_region"            { type = string, default = "ap-south-1" }
variable "environment"           { type = string, default = "production" }
variable "project_name"          { type = string, default = "pipe" }

variable "vpc_id" {
  type        = string
  description = "ID of the VPC to deploy into (e.g., vpc-xxxxxxxx)."
}

variable "subnet_id" {
  type        = string
  description = "Optional: Subnet to use. If empty, the first available subnet in the VPC will be used."
  default     = ""
}

variable "reuse_existing_sg" { type = bool, default = false }
variable "existing_sg_name"  { type = string, default = "web-firewall" }

# Key pair management
variable "keypair_name"       { type = string, default = "25-hp-mumbai" }
variable "create_key_pair"    { type = bool,   default = true }
variable "public_key_openssh" { type = string, default = "" }

variable "ansible_user"            { type = string, default = "ubuntu" }
variable "apache_instance_count"   { type = number, default = 2 }
variable "nginx_instance_count"    { type = number, default = 2 }
variable "instance_type"           { type = string, default = "t3.micro" }

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
  owners      = ["099720109477"] # Canonical

  filter { name = "name",                values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"] }
  filter { name = "virtualization-type", values = ["hvm"] }
  filter { name = "root-device-type",    values = ["ebs"] }
}

########################################
# Derived Selections
########################################
locals {
  selected_subnet_id = var.subnet_id != "" ? var.subnet_id : (
    length(data.aws_subnets.in_vpc.ids) > 0 ? data.aws_subnets.in_vpc.ids[0] : ""
  )
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

  # SSH only from your Jenkins agent public IP
  ingress {
    description = "SSH from Jenkins"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["15.207.89.170/32"]
  }

  # HTTP from anywhere
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTPS from anywhere
  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # All egress
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "${var.project_name}-web-sg-${var.environment}" })
}

locals {
  web_sg_id = aws_security_group.web.id
}

########################################
# EC2 Instances - Apache
########################################
resource "aws_instance" "apache" {
  count                       = var.apache_instance_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = [local.web_sg_id]
  key_name                    = local.selected_key_name
  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-apache-${count.index + 1}-${var.environment}"
    Role = "apache"
  })
}

########################################
# EC2 Instances - Nginx
########################################
resource "aws_instance" "nginx" {
  count                       = var.nginx_instance_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.instance_type
  subnet_id                   = local.selected_subnet_id
  vpc_security_group_ids      = [local.web_sg_id]
  key_name                    = local.selected_key_name
  associate_public_ip_address = true

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-nginx-${count.index + 1}-${var.environment}"
    Role = "nginx"
  })
}

########################################
# Outputs
########################################
output "subnet_id_used"        { value = local.selected_subnet_id, description = "Subnet used for EC2" }
output "security_group_id"     { value = local.web_sg_id,          description = "Security Group ID" }
output "apache_public_ips"     { value = [for i in aws_instance.apache : i.public_ip], description = "Apache public IPs" }
output "nginx_public_ips"      { value = [for i in aws_instance.nginx  : i.public_ip], description = "Nginx public IPs" }
output "key_name_used"         { value = local.selected_key_name,   description = "Key pair used" }
output "generated_private_key_path" {
  value       = var.create_key_pair && var.public_key_openssh == "" ? local_file.generated_pem[0].filename : ""
  description = "Generated PEM path (if any)"
  sensitive   = false
}
output "ansible_user"          { value = var.ansible_user,          description = "Default Ansible SSH user" }

# Helpful HTTP URLs (used by your Jenkins post step)
output "apache_http_urls"      { value = [for ip in aws_instance.apache : "http://${ip}"], description = "Apache HTTP URLs" }
output "nginx_http_urls"       { value = [for ip in aws_instance.nginx  : "http://${ip}"], description = "Nginx HTTP URLs" }
``
