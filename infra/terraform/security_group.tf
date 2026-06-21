# ============================================================================
# Security Group único, compartilhado por master e workers.
# Resolve a dor que vocês tiveram: as portas internas do k3s ficam liberadas
# ENTRE os nós (regra self-referência), e só SSH/HTTP ficam expostos pra fora.
# ============================================================================

resource "aws_security_group" "cluster" {
  name        = "ingressos-k3s-sg"
  description = "k3s cluster (master + workers) - portas internas entre nos, SSH/HTTP externos"
  vpc_id      = data.aws_vpc.default.id

  # --- Tráfego INTERNO do cluster: tudo liberado entre membros do mesmo SG ---
  # Cobre 6443/TCP (API/join), 8472/UDP (flannel VXLAN) e 10250/TCP (kubelet)
  # de uma vez, usando o IP PRIVADO — que foi o que funcionou no join.
  ingress {
    description = "Todo trafego entre nos do cluster (mesmo SG)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  # --- SSH para você administrar/depurar ---
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  # --- HTTP/HTTPS do ingress (Traefik do k3s) p/ abrir o frontend no navegador ---
  ingress {
    description = "HTTP (ingress)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (ingress)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # --- Faixa de NodePort (caso exponha algum Service via NodePort na demo) ---
  ingress {
    description = "NodePort range"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Saída liberada (puxar k3s, imagens do Docker Hub, pacotes apt/npm).
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "ingressos-k3s-sg"
  }
}
