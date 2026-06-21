# Sobe a aplicacao em um cluster Kubernetes LOCAL (kind ou minikube). Fase 5.
# Constroi as 3 imagens, carrega no cluster e aplica os manifests.
#
# Uso:
#   ./scripts/k8s-local.ps1 kind       # cluster kind chamado "ingressos"
#   ./scripts/k8s-local.ps1 minikube   # minikube
#
# ASCII puro (PowerShell 5.1 le UTF-8 sem BOM como ANSI).

param(
  [ValidateSet("kind", "minikube")]
  [string]$Cluster = "kind"
)

$ErrorActionPreference = "Stop"
$kindClusterName = "ingressos"

Write-Host "==> Construindo imagens..." -ForegroundColor Cyan
docker build -t ingressos/api:latest    -f infra/docker/api.Dockerfile .
docker build -t ingressos/worker:latest -f infra/docker/worker.Dockerfile .
docker build -t ingressos/web:latest    -f infra/docker/web.prod.Dockerfile .

Write-Host "==> Carregando imagens no cluster ($Cluster)..." -ForegroundColor Cyan
if ($Cluster -eq "kind") {
  kind load docker-image ingressos/api:latest    --name $kindClusterName
  kind load docker-image ingressos/worker:latest --name $kindClusterName
  kind load docker-image ingressos/web:latest    --name $kindClusterName
} else {
  minikube image load ingressos/api:latest
  minikube image load ingressos/worker:latest
  minikube image load ingressos/web:latest
}

Write-Host "==> Aplicando manifests..." -ForegroundColor Cyan
kubectl apply -k infra/k8s

Write-Host "==> Aguardando os pods ficarem prontos..." -ForegroundColor Cyan
kubectl -n ingressos-data rollout status deploy/mongo      --timeout=180s
kubectl -n ingressos-data rollout status deploy/redis      --timeout=180s
kubectl -n ingressos-data rollout status deploy/localstack --timeout=180s
kubectl -n ingressos      rollout status deploy/api        --timeout=180s
kubectl -n ingressos      rollout status deploy/web        --timeout=180s

Write-Host ""
Write-Host "OK! Para acessar o frontend sem Ingress:" -ForegroundColor Green
Write-Host "  kubectl -n ingressos port-forward svc/web 8088:80" -ForegroundColor Yellow
Write-Host "  depois abra http://localhost:8088"
