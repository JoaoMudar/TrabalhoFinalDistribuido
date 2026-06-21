#!/bin/bash
# Sobe a aplicacao em um cluster Kubernetes LOCAL (kind ou minikube). Fase 5.
# Constroi as 3 imagens, carrega no cluster e aplica os manifests.
#
# Uso:
#   ./scripts/k8s-local.sh kind       # cluster kind chamado "ingressos"
#   ./scripts/k8s-local.sh minikube
set -euo pipefail

CLUSTER="${1:-kind}"
KIND_CLUSTER_NAME="ingressos"

echo "==> Construindo imagens..."
docker build -t ingressos/api:latest    -f infra/docker/api.Dockerfile .
docker build -t ingressos/worker:latest -f infra/docker/worker.Dockerfile .
docker build -t ingressos/web:latest    -f infra/docker/web.prod.Dockerfile .

echo "==> Carregando imagens no cluster ($CLUSTER)..."
if [ "$CLUSTER" = "kind" ]; then
  kind load docker-image ingressos/api:latest    --name "$KIND_CLUSTER_NAME"
  kind load docker-image ingressos/worker:latest --name "$KIND_CLUSTER_NAME"
  kind load docker-image ingressos/web:latest    --name "$KIND_CLUSTER_NAME"
else
  minikube image load ingressos/api:latest
  minikube image load ingressos/worker:latest
  minikube image load ingressos/web:latest
fi

echo "==> Aplicando manifests..."
kubectl apply -k infra/k8s

echo "==> Aguardando os pods ficarem prontos..."
kubectl -n ingressos-data rollout status deploy/mongo      --timeout=180s
kubectl -n ingressos-data rollout status deploy/redis      --timeout=180s
kubectl -n ingressos-data rollout status deploy/localstack --timeout=180s
kubectl -n ingressos      rollout status deploy/api        --timeout=180s
kubectl -n ingressos      rollout status deploy/web        --timeout=180s

echo ""
echo "OK! Para acessar o frontend sem Ingress:"
echo "  kubectl -n ingressos port-forward svc/web 8088:80"
echo "  depois abra http://localhost:8088"
