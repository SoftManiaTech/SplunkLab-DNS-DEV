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
resource "aws_instance" "Splunk_sh_idx_hf_uf" {
  count         = 4
  ami           = data.aws_ami.rhel9.id
  instance_type = var.instance_type
  key_name      = aws_key_pair.generated_key_pair.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = var.storage_size
  }

  tags = {
    Name          = element(["${var.instance_name}-SearchHead", "${var.instance_name}-Indexer", "${var.instance_name}-HF", "${var.instance_name}-UF"], count.index)
    AutoStop      = true
    Owner         = var.usermail
    UserEmail     = var.usermail
    RunQuotaHours = var.quotahours
    Category      = var.category
    PlanStartDate = var.planstartdate
  }
} 


# ✅ Output Public IPs
output "instance_public_ips" {
  value = aws_instance.Splunk_sh_idx_hf_uf[*].public_ip
}

# ✅ Output Key Name
output "final_key_name" {
  value = local.final_key_name
}

# ✅ Output PEM S3 Path
output "s3_key_path" {
  value = "${var.usermail}/keys/${local.final_key_name}.pem"
}