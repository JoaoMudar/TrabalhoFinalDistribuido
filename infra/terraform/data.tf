# ============================================================================
# Dados existentes no lab que NÃO criamos — só referenciamos.
# ============================================================================

# VPC default da conta do lab (não criamos rede nova p/ ficar simples e barato).
data "aws_vpc" "default" {
  default = true
}

# AZs que REALMENTE oferecem cada tipo de instância. Em us-east-1 a zona
# us-east-1e é legada e não suporta a família T3 — por isso não dá pra usar
# qualquer subnet da VPC default cegamente.
data "aws_ec2_instance_type_offerings" "master" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.master_instance_type]
  }
}

data "aws_ec2_instance_type_offerings" "worker" {
  location_type = "availability-zone"
  filter {
    name   = "instance-type"
    values = [var.worker_instance_type]
  }
}

locals {
  # AZs que servem para AMBOS os tipos (master e worker).
  usable_azs = sort(setintersection(
    toset(data.aws_ec2_instance_type_offerings.master.locations),
    toset(data.aws_ec2_instance_type_offerings.worker.locations),
  ))
}

# Subnets da VPC default APENAS nas AZs utilizáveis — o master pega a primeira
# e o ASG distribui as workers entre todas elas.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "availability-zone"
    values = local.usable_azs
  }
}

# AMI mais recente do Ubuntu 22.04 (Canonical) — base limpa, sem k3s pré-instalado.
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}
