#!/bin/bash
#
# ============================================================================
# USER-DATA DO MASTER (k3s server) — Plataforma de Venda de Ingressos
# ============================================================================
# Cole este conteúdo no campo "Dados do usuário" (User data) do Modelo de
# Execução / instância MASTER no AWS Academy Learner Lab.
#
# O que ele faz, no boot da EC2 (roda como root, sem interação):
#   1. Instala o k3s como SERVER usando um TOKEN ESTÁTICO (pré-compartilhado),
#      para que as workers do Auto Scaling Group entrem sozinhas no cluster.
#   2. Instala docker + git (para buildar as imagens da aplicação).
#   3. Clona o monorepo do projeto.
#   4. Builda as 3 imagens locais: api, worker e web (build de produção/nginx).
#   5. IMPORTA as imagens no containerd do k3s (k3s usa containerd, não docker;
#      por isso não precisamos de registry — combina com imagePullPolicy:IfNotPresent).
#   6. Aplica todos os manifests do cluster com kustomize (kubectl apply -k).
#
# Logs deste script ficam em: /var/log/userdata-master.log
# (acompanhe com: sudo tail -f /var/log/userdata-master.log)
# ============================================================================

set -euxo pipefail
exec > >(tee -a /var/log/userdata-master.log) 2>&1
echo ">>> [master] iniciando user-data em $(date)"

# ---------------------------------------------------------------------------
# CONFIGURAÇÃO (ajuste estes valores)
# ---------------------------------------------------------------------------
# Token estático do cluster — deve ser IGUAL ao usado no user-data das workers.
# Troque por um segredo seu; NÃO comite o valor real no repositório.
K3S_TOKEN_VALUE='trabalho-distribuidos-2026'

# Região AWS e Elastic IP (endpoint PÚBLICO estável do master, p/ SSH/navegador).
# Confira o valor real no painel EC2 -> Elastic IPs.
AWS_REGION='us-east-1'
ELASTIC_IP='54.235.246.44'

# Repositório com o código (as EC2 sobem "vazias", precisam clonar o projeto).
REPO_URL='https://github.com/JoaoMudar/TrabalhoFinalDistribuido.git'
REPO_BRANCH='main'
REPO_DIR='/opt/ingressos'

# Diretório dos manifests dentro do repo.
K8S_DIR="${REPO_DIR}/infra/k8s"

export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# 0. Associa o Elastic IP a ESTA instância (endpoint público estável do master)
# ---------------------------------------------------------------------------
# Uma EC2 nova NÃO herda o Elastic IP sozinha — alguém precisa "associar". Aqui a
# própria instância se associa no boot, usando a LabRole. Pré-requisito: a EC2
# master tem a LabRole no Instance Profile (Launch Template -> IAM instance profile).
#
# IMPORTANTE: o EIP é só p/ acesso EXTERNO (SSH, abrir o frontend, mostrar ao
# professor). As WORKERS continuam fazendo join pelo IP PRIVADO do master — de
# dentro da VPC o tráfego pro próprio EIP sofre hairpinning e o join falha.
echo ">>> [master] instalando awscli e associando Elastic IP ${ELASTIC_IP}..."
apt-get update -y
apt-get install -y awscli

# instance-id desta EC2 via IMDSv2 (metadata)
IMDS_TOKEN=$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/instance-id)

# descobre o allocation-id (eipalloc-...) a partir do IP elástico e associa.
ALLOC_ID=$(aws ec2 describe-addresses --region "${AWS_REGION}" \
  --public-ips "${ELASTIC_IP}" \
  --query 'Addresses[0].AllocationId' --output text)

aws ec2 associate-address --region "${AWS_REGION}" \
  --instance-id "${INSTANCE_ID}" \
  --allocation-id "${ALLOC_ID}" \
  --allow-reassociation
echo ">>> [master] Elastic IP ${ELASTIC_IP} associado (alloc ${ALLOC_ID})."

# ---------------------------------------------------------------------------
# 1. Instala o k3s SERVER com token estático
# ---------------------------------------------------------------------------
# --write-kubeconfig-mode 644 deixa o kubeconfig legível para usar kubectl
# sem sudo. O token fixo é o que permite o join idempotente das workers.
echo ">>> [master] instalando k3s server..."
curl -sfL https://get.k3s.io | \
  K3S_TOKEN="${K3S_TOKEN_VALUE}" \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644" \
  sh -

# kubectl deste script enxerga o cluster por esta env:
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Espera o nó ficar Ready antes de seguir.
echo ">>> [master] aguardando k3s ficar pronto..."
until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
  sleep 5
done
echo ">>> [master] k3s pronto."

# ---------------------------------------------------------------------------
# 2. Instala docker + git (para buildar as imagens da aplicação)
# ---------------------------------------------------------------------------
echo ">>> [master] instalando docker e git..."
apt-get update -y
apt-get install -y docker.io git
systemctl enable --now docker

# ---------------------------------------------------------------------------
# 3. Clona o monorepo
# ---------------------------------------------------------------------------
echo ">>> [master] clonando repositorio ${REPO_URL} (${REPO_BRANCH})..."
rm -rf "${REPO_DIR}"
git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
cd "${REPO_DIR}"

# ---------------------------------------------------------------------------
# 4. Builda as 3 imagens locais (contexto = raiz do monorepo)
# ---------------------------------------------------------------------------
# Tags batem EXATAMENTE com as referenciadas nos manifests (infra/k8s/*.yaml):
#   ingressos/api:latest  ingressos/worker:latest  ingressos/web:latest
# web usa o Dockerfile de PRODUCAO (nginx na porta 80), não o dev server.
echo ">>> [master] buildando imagens..."
docker build -t ingressos/api:latest    -f infra/docker/api.Dockerfile      .
docker build -t ingressos/worker:latest -f infra/docker/worker.Dockerfile   .
docker build -t ingressos/web:latest    -f infra/docker/web.prod.Dockerfile .

# ---------------------------------------------------------------------------
# 5. Importa as imagens no containerd do k3s
# ---------------------------------------------------------------------------
# k3s NÃO usa o docker daemon — usa containerd. Sem este passo os pods não
# encontram as imagens locais. "docker save | k3s ctr images import -" copia
# a imagem do docker para o containerd do k3s.
echo ">>> [master] importando imagens no containerd do k3s..."
for IMG in ingressos/api:latest ingressos/worker:latest ingressos/web:latest; do
  docker save "${IMG}" | k3s ctr images import -
done

# ---------------------------------------------------------------------------
# 6. Aplica todos os manifests do cluster
# ---------------------------------------------------------------------------
# kustomization.yaml aplica tudo na ordem: namespaces -> config -> mongo ->
# redis -> localstack -> api -> worker -> web -> ingress.
echo ">>> [master] aplicando manifests do k8s..."
k3s kubectl apply -k "${K8S_DIR}"

echo ">>> [master] CONCLUIDO em $(date)"
echo ">>> Verifique com: sudo k3s kubectl get pods -A"
