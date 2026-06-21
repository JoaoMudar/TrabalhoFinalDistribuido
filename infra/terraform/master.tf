# ============================================================================
# MASTER — uma única EC2 (aws_instance), NÃO um Auto Scaling Group.
#
# Por que não ASG? O master é um PET, não cattle: ele guarda o estado do k3s
# (etcd/sqlite) localmente. Um ASG só recriaria um nó VAZIO se o atual morresse,
# subindo um cluster novo — não é self-healing de verdade. Além disso, ASG +
# IP privado fixo é PROIBIDO pela AWS ("Auto Scaling does not support Private IP
# addresses"), e o IP privado fixo é justamente o que faz o join das workers
# funcionar de forma confiável.
#
# Com aws_instance temos: IP privado FIXO (local.master_private_ip), conhecido já
# no plan, que é injetado nas workers; e registramos o nó nos target groups do
# NLB manualmente (aws_lb_target_group_attachment). O NLB (ver lb.tf) segue como
# endpoint público (frontend na 80, kubectl externo na 6443) e entra no --tls-san.
# ============================================================================

resource "aws_instance" "master" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  key_name      = var.key_name

  iam_instance_profile = var.instance_profile

  # IP privado FIXO dentro da subnet escolhida (ver local.master_private_ip em
  # data.tf). As workers joinam por ele; o IP é conhecido no plan.
  subnet_id                   = local.master_subnet_id
  private_ip                  = local.master_private_ip
  vpc_security_group_ids      = [aws_security_group.cluster.id]
  associate_public_ip_address = true

  # Disco maior: build das 3 imagens docker consome espaço.
  root_block_device {
    volume_size = 30
    volume_type = "gp3"
  }

  # User-data = bloco de config (templated) + corpo estático (bash puro).
  # O DNS do NLB entra como --tls-san; é conhecido após o NLB ser criado, e o
  # Terraform garante essa ordem por causa da referência abaixo.
  user_data = base64encode(join("\n", [
    templatefile("${path.module}/userdata/master-config.tpl", {
      k3s_token     = var.k3s_token
      master_lb_dns = aws_lb.main.dns_name
      repo_url      = var.repo_url
      repo_branch   = var.repo_branch
    }),
    file("${path.module}/userdata/master-body.sh"),
  ]))

  # Mudou o user-data (ex.: novo token/branch) → recria a instância (sobe cluster
  # novo). Sem isto, o Terraform ignoraria a mudança de user-data numa instância
  # já criada. Equivale ao instance_refresh que o ASG fazia antes.
  user_data_replace_on_change = true

  tags = {
    Name = "ingressos-master"
    Role = "k3s-server"
  }
}

# --- Registro do master nos target groups do NLB ----------------------------
# O ASG fazia isso via target_group_arns; com aws_instance registramos à mão.
# 6443 = k3s API (kubectl externo + join das workers via NLB, se necessário).
resource "aws_lb_target_group_attachment" "master_api" {
  target_group_arn = aws_lb_target_group.api.arn
  target_id        = aws_instance.master.id
  port             = 6443
}

# 80 = app/Traefik (ServiceLB do k3s escuta em todo nó, inclusive o master).
resource "aws_lb_target_group_attachment" "master_app" {
  target_group_arn = aws_lb_target_group.app.arn
  target_id        = aws_instance.master.id
  port             = 80
}
