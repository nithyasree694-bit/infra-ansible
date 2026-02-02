# Region & environment
aws_region            = "ap-south-1"
environment           = "production"
project_name          = "devops-webapp"

# Your VPC
vpc_id                = "vpc-0eff6848d8ed2be0b"
subnet_id             = ""   # leave empty to auto-pick the first subnet in that VPC

# Security group behavior
reuse_existing_sg     = true
existing_sg_name      = "web-firewall"

# EC2 & SSH
instance_type         = "t3.micro"
apache_instance_count = 2
nginx_instance_count  = 2

# Key pair management
keypair_name          = "25-hp-mumbai"
create_key_pair       = true
public_key_openssh    = ""    # leave empty to auto-generate a new keypair (PEM will be saved locally)
ansible_user          = "ubuntu"
