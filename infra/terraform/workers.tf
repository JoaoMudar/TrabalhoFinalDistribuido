# ============================================================================
# WORKERS — Launch Template + Auto Scaling Group.
# O user-data recebe o DNS do NLB (endpoint do k3s API) automaticamente; cada
# worker que o ASG subir faz join sozinha. Resolve o "ASG não joina direto".
# ============================================================================

resource "aws_launch_template" "worker" {
  name_prefix   = "ingressos-worker-"
  image_id      = data.aws_ami.ubuntu.id
  instance_type = var.worker_instance_type
  key_name      = var.key_name

  iam_instance_profile {
    name = var.instance_profile
  }

  vpc_security_group_ids = [aws_security_group.cluster.id]

  block_device_mappings {
    device_name = "/dev/sda1"
    ebs {
      volume_size = 20
      volume_type = "gp3"
    }
  }

  # IP privado FIXO do master injetado no template do agent (join confiável,
  # dentro da VPC, sem depender do health check do NLB).
  user_data = base64encode(templatefile("${path.module}/userdata/worker.tpl", {
    k3s_token         = var.k3s_token
    master_private_ip = local.master_private_ip
  }))

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "ingressos-worker"
      Role = "k3s-agent"
    }
  }
}

resource "aws_autoscaling_group" "workers" {
  name                = "ingressos-workers-asg"
  desired_capacity    = var.worker_count
  min_size            = var.worker_count
  max_size            = var.worker_count + 2
  vpc_zone_identifier = data.aws_subnets.default.ids

  # Workers entram no target group da app (80) p/ o NLB distribuir HTTP nelas.
  target_group_arns = [aws_lb_target_group.app.arn]

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  # Todo apply que mudar o launch template (ex.: user-data) recicla as workers
  # sozinho, uma de cada vez. min_healthy_percentage = 50 com 2 nós mantém pelo
  # menos 1 worker no ar enquanto a outra é substituída; warmup dá tempo do join.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
      instance_warmup        = 120
    }
  }

  # Garante que o master (ASG) já exista antes de subir as workers.
  depends_on = [aws_autoscaling_group.master]

  tag {
    key                 = "Name"
    value               = "ingressos-worker"
    propagate_at_launch = true
  }
}
