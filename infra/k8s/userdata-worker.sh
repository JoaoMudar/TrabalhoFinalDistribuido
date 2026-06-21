#!/bin/bash
#
# ============================================================================
# USER-DATA DAS WORKERS (k3s agent) — Plataforma de Venda de Ingressos
# ============================================================================
# Cole este conteúdo no campo "Dados do usuário" (User data) do Modelo de
# Execução usado pelo Auto Scaling Group das WORKERS (Worker-1, Worker-2, ...).
#
# Como usa TOKEN ESTÁTICO + endpoint fixo do master, qualquer worker nova que
# o ASG suba entra sozinha no cluster no boot — sem rodar script na mão.
#
# Pré-requisitos:
#   - O master já estar no ar (subir o master ANTES do ASG das workers).
#   - Security Group liberando do worker -> master:
#       6443/TCP  (API do k3s / join)
#       8472/UDP  (flannel VXLAN / rede dos pods)
#       10250/TCP (kubelet / métricas)
#
# Logs: /var/log/userdata-worker.log
# (acompanhe com: sudo tail -f /var/log/userdata-worker.log)
# ============================================================================

set -euxo pipefail
exec > >(tee -a /var/log/userdata-worker.log) 2>&1
echo ">>> [worker] iniciando user-data em $(date)"

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO (ajuste estes valores)
# ---------------------------------------------------------------------------
# Token estático do cluster — DEVE ser IDÊNTICO ao do user-data do master.
K3S_TOKEN_VALUE='trabalho-distribuidos-2026'

# Endpoint ESTÁVEL do master (Elastic IP, DNS privado, ou IP fixo).
# Troque pelo endereço real do seu master. NÃO use IP que muda a cada boot.
MASTER_ENDPOINT='ELASTIC_IP_OU_DNS_DO_MASTER'

# ---------------------------------------------------------------------------
# Instala o k3s como AGENT e faz join no cluster do master
# ---------------------------------------------------------------------------
# K3S_URL define o master a contatar; K3S_TOKEN autentica o join. A presença
# de K3S_URL faz o instalador subir em modo "agent" (worker) automaticamente.
echo ">>> [worker] instalando k3s agent e fazendo join em https://${MASTER_ENDPOINT}:6443 ..."
curl -sfL https://get.k3s.io | \
  K3S_URL="https://${MASTER_ENDPOINT}:6443" \
  K3S_TOKEN="${K3S_TOKEN_VALUE}" \
  sh -

echo ">>> [worker] CONCLUIDO em $(date)"
echo ">>> Confirme no MASTER com: sudo k3s kubectl get nodes -o wide"
