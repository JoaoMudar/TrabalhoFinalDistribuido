# ============================================================================
# WORKERS — Launch Template + Auto Scaling Group.
# O user-data recebe o IP PRIVADO do master automaticamente; cada worker que
# o ASG subir faz join sozinha. Resolve o "ASG não joina direto".
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

  # IP privado do master injetado no template do agent.
  user_data = base64encode(templatefile("${path.module}/userdata/worker.tpl", {
    k3s_token          = var.k3s_token
    master_private_ip  = aws_instance.master.private_ip
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

  launch_template {
    id      = aws_launch_template.worker.id
    version = "$Latest"
  }

  # Garante que o master (e seu IP privado) já existam antes de subir workers.
  depends_on = [aws_instance.master]

  tag {
    key                 = "Name"
    value               = "ingressos-worker"
    propagate_at_launch = true
  }
}
