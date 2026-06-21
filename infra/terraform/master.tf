# ============================================================================
# MASTER — EC2 fixa + Elastic IP (endpoint público estável).
# O aws_eip_association resolve a dor de "a instância não nasce com o EIP":
# o Terraform cria o EIP e o gruda na master automaticamente.
# ============================================================================

# Elastic IP gerenciado pelo Terraform (criado e destruído junto com o resto).
resource "aws_eip" "master" {
  domain = "vpc"

  tags = {
    Name = "ingressos-master-eip"
  }
}

resource "aws_instance" "master" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.master_instance_type
  key_name               = var.key_name
  iam_instance_profile   = var.instance_profile
  vpc_security_group_ids = [aws_security_group.cluster.id]
  # primeira subnet da VPC default
  subnet_id = data.aws_subnets.default.ids[0]

  # Disco maior: build das 3 imagens docker consome espaço.
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # User-data = bloco de config (templated) + corpo estático (bash puro).
  # O EIP entra como --tls-san; é conhecido antes da instância porque o
  # aws_eip é criado primeiro.
  user_data = join("\n", [
    templatefile("${path.module}/userdata/master-config.tpl", {
      k3s_token   = var.k3s_token
      master_eip  = aws_eip.master.public_ip
      repo_url    = var.repo_url
      repo_branch = var.repo_branch
    }),
    file("${path.module}/userdata/master-body.sh"),
  ])

  tags = {
    Name = "ingressos-master"
    Role = "k3s-server"
  }
}

# Gruda o EIP na master (o que faltava no fluxo manual de vocês).
resource "aws_eip_association" "master" {
  instance_id   = aws_instance.master.id
  allocation_id = aws_eip.master.id
}
