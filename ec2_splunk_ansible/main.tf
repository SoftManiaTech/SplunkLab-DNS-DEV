terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get next available key name
data "external" "key_check" {
  program = ["${path.module}/scripts/check_key.sh", var.key_name, var.aws_region]
}

locals {
  final_key_name = data.external.key_check.result.final_key_name
}

# Generate PEM key
resource "tls_private_key" "generated_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create EC2 Key Pair
resource "aws_key_pair" "generated_key_pair" {
  key_name   = local.final_key_name
  public_key = tls_private_key.generated_key.public_key_openssh
}

# Upload PEM to S3
resource "aws_s3_object" "upload_pem_key" {
  bucket  = "splunk-deployment-test"
  key     = "${var.usermail}/keys/${local.final_key_name}.pem"
  content = tls_private_key.generated_key.private_key_pem
}

resource "random_id" "sg_suffix" {
  byte_length = 2
}

# Security Group
resource "aws_security_group" "splunk_sg" {
  name        = "splunk-security-group-${random_id.sg_suffix.hex}"
  description = "Security group for Splunk server"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 8000
    to_port     = 9999
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Get Latest RHEL 9 AMI
data "aws_ami" "rhel9" {
  most_recent = true

  filter {
    name   = "name"
    values = ["RHEL-9.*x86_64-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  owners = ["309956199498"]
}

# ✅ Create 3 EC2 Instances: SH, IDX, HF
resource "aws_instance" "Splunk_sh_idx_hf" {
  count                = 3
  ami                  = data.aws_ami.rhel9.id
  instance_type        = var.instance_type
  key_name             = aws_key_pair.generated_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = var.storage_size
  }

  user_data = file("splunk-setup.sh")

  tags = {
    Name          = element(["${var.instance_name}-SearchHead", "${var.instance_name}-Indexer", "${var.instance_name}-HF"], count.index)
    AutoStop      = "true"
    Owner         = var.usermail
    UserEmail     = var.usermail
    RunQuotaHours = var.quotahours
    Category      = var.category
    PlanStartDate = var.planstartdate
  }
}

# ✅ Create EC2 Instance: UF
resource "aws_instance" "Splunk_uf" {
  ami                    = data.aws_ami.rhel9.id
  instance_type          = var.instance_type
  key_name               = aws_key_pair.generated_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = var.storage_size
  }

  user_data = file("splunk-setup-UF.sh")

  tags = {
    Name          = "${var.instance_name}-UF"
    AutoStop      = "true"
    Owner         = var.usermail
    UserEmail     = var.usermail
    RunQuotaHours = var.quotahours
    Category      = var.category
    PlanStartDate = var.planstartdate
  }
}


# ✅ Generate Ansible Inventory File
resource "local_file" "inventory" {
  content = <<EOT
[search_head]
${aws_instance.Splunk_sh_idx_hf[0].tags.Name} ansible_host=${aws_instance.Splunk_sh_idx_hf[0].public_ip} ansible_user=ec2-user private_ip=${aws_instance.Splunk_sh_idx_hf[0].private_ip}

[indexer]
${aws_instance.Splunk_sh_idx_hf[1].tags.Name} ansible_host=${aws_instance.Splunk_sh_idx_hf[1].public_ip} ansible_user=ec2-user private_ip=${aws_instance.Splunk_sh_idx_hf[1].private_ip}

[heavy_forwarder]
${aws_instance.Splunk_sh_idx_hf[2].tags.Name} ansible_host=${aws_instance.Splunk_sh_idx_hf[2].public_ip} ansible_user=ec2-user private_ip=${aws_instance.Splunk_sh_idx_hf[2].private_ip}

[universal_forwarder]
${aws_instance.Splunk_uf.tags.Name} ansible_host=${aws_instance.Splunk_uf.public_ip} ansible_user=ec2-user private_ip=${aws_instance.Splunk_uf.private_ip}

[splunk:children]
search_head
indexer
heavy_forwarder
EOT

  filename = "${path.module}/inventory.ini"
}

# ✅ Output Public IPs of SH, IDX, HF
output "instance_public_ips" {
  value = aws_instance.Splunk_sh_idx_hf[*].public_ip
}

# ✅ Output Public IP of UF
output "uf_instance_public_ip" {
  value = aws_instance.Splunk_uf.public_ip
}

# ✅ Output Key Name
output "final_key_name" {
  value = local.final_key_name
}

# ✅ Output PEM S3 Path
output "s3_key_path" {
  value = "${var.usermail}/keys/${local.final_key_name}.pem"
}
