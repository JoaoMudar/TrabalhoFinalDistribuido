# ============================================================================
# MASTER — Launch Template + Auto Scaling Group (1 nó fixo: min=max=desired=1).
# Vive num ASG só para padronizar o provisionamento (user-data no template) e
# dar self-healing do NÓ. Tem um IP privado FIXO (local.master_private_ip): as
# workers joinam por ele. O NLB (ver lb.tf) é o endpoint público (frontend na 80
# e kubectl externo na 6443) e entra no --tls-san do k3s.
#
# CAVEAT: o ASG recria o NÓ se ele morrer, mas NÃO preserva o estado do cluster
# (o k3s guarda etcd/sqlite localmente). Uma substituição sobe um cluster novo
# que re-builda imagens e re-aplica os manifests. Para a demo é aceitável; HA
# real do control plane fica como trabalho futuro.
# ============================================================================

resource "aws_launch_template" "master" {
  name_prefix   = "ingressos-master-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.master_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile
  }

  # Interface de rede com IP privado FIXO (ver local.master_private_ip em
  # data.tf). Quando o IP é fixado aqui, a SG precisa vir DENTRO da interface
  # (não dá pra usar vpc_security_group_ids no nível do template ao mesmo tempo).
  network_interfaces {
    device_index                = 0
    subnet_id                   = local.master_subnet_id
    private_ip_address          = local.master_private_ip
    security_groups             = [aws_security_group.cluster.id]
    associate_public_ip_address = true
  }

  # Disco maior: build das 3 imagens docker consome espaço.
  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 30
      volume_type = "gp3"
    }
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

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ingressos-master"
      Role = "k3s-server"
    }
  }
}

resource "aws_autoscaling_group" "master" {
  name             = "ingressos-master-asg"
  desired_capacity = 1
  min_size         = 1
  max_size         = 1
  # Uma subnet só: precisa casar com a subnet do IP privado fixo do master.
  vpc_zone_identifier = [local.master_subnet_id]

  # Master entra nos DOIS target groups: 6443 (k3s API) e 80 (app/Traefik).
  target_group_arns = [
    aws_lb_target_group.api.arn,
    aws_lb_target_group.app.arn,
  ]

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  # Todo apply que mudar o launch template (ex.: user-data) recicla o nó sozinho.
  # min_healthy_percentage = 0 é OBRIGATÓRIO aqui: como é 1 nó só, o refresh
  # precisa poder derrubar a única instância pra subir a nova (com qualquer valor
  # >0 o refresh travaria por não conseguir manter "saudável" o mínimo exigido).
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 0
      instance_warmup        = 120
    }
  }

  tag {
    key                 = "Name"
    value               = "ingressos-master"
    propagate_at_launch = true
  }
}
