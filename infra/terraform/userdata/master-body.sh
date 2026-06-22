# ==========================================================================
# CORPO DO USER-DATA DO MASTER — bash puro (NÃO é template).
# Usa as variáveis definidas no bloco de config (master-config.tpl).
# Não há Elastic IP: o endpoint estável é o DNS do NLB (--tls-san abaixo).
# ==========================================================================

REPO_DIR='/opt/ingressos'
K8S_DIR="${REPO_DIR}/infra/k8s"
export DEBIAN_FRONTEND=noninteractive

# --------------------------------------------------------------------------
# 1. Docker + git (para buildar as imagens da aplicação)
# --------------------------------------------------------------------------
# Instalado PRIMEIRO, antes do k3s: o docker não é dependência do k3s (que usa
# containerd), mas se deixássemos esta etapa depois do "wait k3s Ready" e o k3s
# travasse, o docker nunca seria instalado. Fazendo aqui, ele é garantido.
#
# wait_apt: no boot o cloud-init/unattended-upgrades costuma segurar o lock do
# dpkg/apt. Sem esperar, o apt-get falharia e (com set -e) abortaria o script
# inteiro. Tentamos repetidamente até o lock liberar.
wait_apt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock >/dev/null 2>&1; do
    echo ">>> [master] aguardando liberar o lock do apt..."
    sleep 5
  done
}

echo ">>> [master] instalando docker e git..."
wait_apt; apt-get update -y
wait_apt; apt-get install -y docker.io git
systemctl enable --now docker

# --------------------------------------------------------------------------
# 2. Instala o k3s SERVER com token estático
# --------------------------------------------------------------------------
# --tls-san ${MASTER_LB_DNS}: inclui o DNS do NLB no certificado, permitindo
# usar kubectl de fora pelo load balancer (as workers fazem join pelo mesmo DNS).
echo ">>> [master] instalando k3s server..."
curl -sfL https://get.k3s.io | \
  K3S_TOKEN="${K3S_TOKEN_VALUE}" \
  INSTALL_K3S_EXEC="server --write-kubeconfig-mode 644 --tls-san ${MASTER_LB_DNS}" \
  sh -

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

echo ">>> [master] aguardando k3s ficar pronto..."
until k3s kubectl get nodes 2>/dev/null | grep -q ' Ready'; do
  sleep 5
done
echo ">>> [master] k3s pronto."

# --------------------------------------------------------------------------
# 3. Clona o monorepo
# --------------------------------------------------------------------------
echo ">>> [master] clonando ${REPO_URL} (${REPO_BRANCH})..."
rm -rf "${REPO_DIR}"
git clone --depth 1 --branch "${REPO_BRANCH}" "${REPO_URL}" "${REPO_DIR}"
cd "${REPO_DIR}"

# --------------------------------------------------------------------------
# 4. Builda as 3 imagens locais (contexto = raiz do monorepo)
# --------------------------------------------------------------------------
echo ">>> [master] buildando imagens..."
docker build -t ingressos/api:latest    -f infra/docker/api.Dockerfile      .
docker build -t ingressos/worker:latest -f infra/docker/worker.Dockerfile   .
docker build -t ingressos/web:latest    -f infra/docker/web.prod.Dockerfile .

# --------------------------------------------------------------------------
# 5. Importa as imagens no containerd do k3s (k3s usa containerd, não docker)
# --------------------------------------------------------------------------
echo ">>> [master] importando imagens no containerd do k3s..."
for IMG in ingressos/api:latest ingressos/worker:latest ingressos/web:latest; do
  docker save "${IMG}" | k3s ctr images import -
done

# --------------------------------------------------------------------------
# 6. Aplica todos os manifests do cluster
# --------------------------------------------------------------------------
echo ">>> [master] aplicando manifests do k8s..."
k3s kubectl apply -k "${K8S_DIR}"

echo ">>> [master] CONCLUIDO em $(date)"
echo ">>> Verifique com: sudo k3s kubectl get pods -A"
