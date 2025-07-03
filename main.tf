terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
  region     = var.region
}

# 🔸 Generate unique SG name
resource "random_id" "sg_suffix" {
  byte_length = 2
}

# ✅ Get Latest RHEL 9.x AMI
data "aws_ami" "latest_rhel" {
  most_recent = true
  owners      = ["309956199498"]

  filter {
    name   = "name"
    values = ["RHEL-9.?*-x86_64-*"]
  }
}

# ✅ Security Group
resource "aws_security_group" "splunk_sg" {
  name        = "splunk-security-group-${random_id.sg_suffix.hex}"
  description = "Allow Splunk ports"

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

# ✅ Create 3 EC2 Instances: SH, IDX, HF
resource "aws_instance" "Splunk_sh_idx_hf" {
  count         = 3
  ami           = data.aws_ami.latest_rhel.id
  instance_type = "t3.medium"
  key_name      = var.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = 30
  }

  user_data = file("splunk-setup.sh")

  tags = {
    Name          = element(["Search-Head", "Indexer", "HF"], count.index)
    AutoStop      = true
    Owner         = var.usermail
    UserEmail     = var.usermail
    RunQuotaHours = var.quotahours
    Category      = var.category
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("${var.key_name}.pem")
      host        = self.public_ip
    }

    inline = [
      "echo '${var.ssh_public_key}' >> ~/.ssh/authorized_keys"
    ]
  }
}

# ✅ Create 1 EC2 Instance: UF
resource "aws_instance" "Splunk_uf" {
  ami                    = data.aws_ami.latest_rhel.id
  instance_type          = "t3.medium"
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.splunk_sg.id]

  root_block_device {
    volume_size = 30
  }

  user_data = file("splunk-setup-UF.sh")

  tags = {
    Name = "UF"
  }

  provisioner "remote-exec" {
    connection {
      type        = "ssh"
      user        = "ec2-user"
      private_key = file("${var.key_name}.pem")
      host        = self.public_ip
    }

    inline = [
      "echo '${var.ssh_public_key}' >> ~/.ssh/authorized_keys"
    ]
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
