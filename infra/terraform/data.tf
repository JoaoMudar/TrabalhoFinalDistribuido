# ============================================================================
# Dados existentes no lab que NÃO criamos — só referenciamos.
# ============================================================================

# VPC default da conta do lab (não criamos rede nova p/ ficar simples e barato).
data "aws_vpc" "default" {
  default = true
}

# Subnets da VPC default — o ASG distribui as workers entre elas.
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
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
