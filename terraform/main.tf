# One EC2 instance with k3s, in the account's default VPC.

terraform {
  required_version = ">= 1.16"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "6.68.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Latest Ubuntu 24.04 image published by Canonical.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_key_pair" "this" {
  key_name   = "platform-infra"
  public_key = file("~/.ssh/id_ed25519.pub")
}

resource "aws_security_group" "k3s" {
  name        = "platform-infra-k3s"
  description = "SSH from my IP only"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.my_ip]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "k3s" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "t3.small"
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.k3s.id]

  # Runs once on first boot. The kubeconfig is made readable so `kubectl` works without sudo.
  user_data = <<-EOT
    #!/bin/bash
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="v1.37.1+k3s1" sh -s - --write-kubeconfig-mode 644
  EOT

  tags = {
    Name = "platform-infra-k3s"
  }
}
