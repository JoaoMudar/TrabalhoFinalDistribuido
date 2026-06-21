# Roda o teste de carga (Fase 8) com k6 via Docker, sem instalar nada.
# Usa a rede do compose (fabiano_default) para falar direto com o "api".
#
# Uso:
#   ./scripts/loadtest.ps1                 # pico padrao (50 req/s)
#   ./scripts/loadtest.ps1 -Peak 100 -Hold 30s
#
# Acompanhe ao vivo no Grafana: http://localhost:3000 (dashboard "Ingressos").
# ASCII puro (PowerShell 5.1).

param(
  [int]$Peak = 50,
  [string]$Ramp = "10s",
  [string]$Hold = "20s",
  [string]$Network = "fabiano_default"
)

$loadDir = (Resolve-Path "$PSScriptRoot/../tests/load").Path

Write-Host "==> Rodando k6 (pico=$Peak rps, ramp=$Ramp, hold=$Hold)" -ForegroundColor Cyan
Write-Host "    Veja a fila no Grafana: http://localhost:3000" -ForegroundColor Yellow

docker run --rm -i `
  --network $Network `
  -v "${loadDir}:/scripts" `
  grafana/k6 run /scripts/purchase-burst.js `
  -e API=http://api:8080 `
  -e PEAK=$Peak -e RAMP=$Ramp -e HOLD=$Hold
