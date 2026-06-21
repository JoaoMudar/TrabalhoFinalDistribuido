#!/bin/bash
# ==========================================================================
# USER-DATA DAS WORKERS (k3s agent) — gerado pelo Terraform (templatefile).
# O Terraform injeta o TOKEN e o IP PRIVADO do master automaticamente, então
# toda worker que o Auto Scaling Group subir entra sozinha no cluster no boot.
# Logs: /var/log/userdata-worker.log
# ==========================================================================
set -euxo pipefail
exec > >(tee -a /var/log/userdata-worker.log) 2>&1
echo ">>> [worker] iniciando user-data em $(date)"

# Valores injetados pelo Terraform:
K3S_TOKEN_VALUE='${k3s_token}'
MASTER_PRIVATE_IP='${master_private_ip}'

# Defesa: se a AMI/instância já tiver um k3s antigo preso (porta 6444 ocupada,
# o erro que vimos antes), limpa qualquer instalação anterior antes de joinar.
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then /usr/local/bin/k3s-uninstall.sh || true; fi
if [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then /usr/local/bin/k3s-agent-uninstall.sh || true; fi

# Join via IP PRIVADO do master (dentro da VPC). A presença de K3S_URL faz o
# instalador subir em modo "agent" automaticamente.
echo ">>> [worker] instalando k3s agent e fazendo join em https://$MASTER_PRIVATE_IP:6443 ..."
curl -sfL https://get.k3s.io | \
  K3S_URL="https://$MASTER_PRIVATE_IP:6443" \
  K3S_TOKEN="$K3S_TOKEN_VALUE" \
  sh -

echo ">>> [worker] CONCLUIDO em $(date)"
