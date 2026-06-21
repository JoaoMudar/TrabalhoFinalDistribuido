# ============================================================================
# LOAD BALANCER "GERAL" — um único Network Load Balancer (NLB) com 2 listeners.
# Existe por dois motivos, agora que o master vive num ASG (sem IP fixo):
#   * porta 6443 -> endpoint ESTÁVEL do k3s API. As workers e o kubectl
#     passam a falar com o cluster pelo DNS do NLB (não mais pelo IP privado
#     do master, que deixou de ser conhecido no plan).
#   * porta 80   -> entrada HTTP da aplicação. O Traefik/ServiceLB do k3s
#     escuta a porta 80 em TODO nó, então o LB distribui entre master+workers.
# É L4/TCP: deixamos o roteamento HTTP (L7) por conta do Traefik dentro do k3s.
# ============================================================================

resource "aws_lb" "main" {
  name               = "ingressos-nlb"
  load_balancer_type = "network"
  internal           = false
  subnets            = data.aws_subnets.default.ids

  # Distribui o tráfego entre as AZs mesmo que o alvo esteja em outra zona.
  enable_cross_zone_load_balancing = true

  tags = {
    Name = "ingressos-nlb"
  }
}

# --- Target group do k3s API (6443) — só o master entra aqui ---------------
resource "aws_lb_target_group" "api" {
  name        = "ingressos-tg-api"
  port        = 6443
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  # Health check TCP: basta o master aceitar conexão na 6443.
  health_check {
    protocol            = "TCP"
    port                = "6443"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name = "ingressos-tg-api"
  }
}

# --- Target group da aplicação (80) — master + workers entram aqui ---------
resource "aws_lb_target_group" "app" {
  name        = "ingressos-tg-app"
  port        = 80
  protocol    = "TCP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "instance"

  # Health check TCP na 80: confirma que o Traefik está escutando no nó.
  health_check {
    protocol            = "TCP"
    port                = "80"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 10
  }

  tags = {
    Name = "ingressos-tg-app"
  }
}

# --- Listeners: cada porta encaminha para o seu target group ----------------
resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.main.arn
  port              = 6443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_lb_listener" "app" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
