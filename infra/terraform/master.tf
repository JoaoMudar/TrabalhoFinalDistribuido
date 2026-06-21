# ============================================================================
# MASTER — Launch Template + Auto Scaling Group (1 nó fixo: min=max=desired=1).
# Vive num ASG só para padronizar o provisionamento (user-data no template) e
# dar self-healing do NÓ. O endpoint estável NÃO é mais um Elastic IP, e sim o
# DNS do NLB (ver lb.tf): o --tls-san do k3s e o join das workers usam esse DNS.
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

  vpc_security_group_ids = [aws_security_group.cluster.id]

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
  name                = "ingressos-master-asg"
  desired_capacity    = 1
  min_size            = 1
  max_size            = 1
  vpc_zone_identifier = data.aws_subnets.default.ids

  # Master entra nos DOIS target groups: 6443 (k3s API) e 80 (app/Traefik).
  target_group_arns = [
    aws_lb_target_group.api.arn,
    aws_lb_target_group.app.arn,
  ]

  launch_template {
    id      = aws_launch_template.master.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "ingressos-master"
    propagate_at_launch = true
  }
}
