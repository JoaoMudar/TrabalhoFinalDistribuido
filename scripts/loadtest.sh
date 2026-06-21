#!/bin/bash
# Roda o teste de carga (Fase 8) com k6 via Docker, sem instalar nada.
# Usa a rede do compose (fabiano_default) para falar direto com o "api".
#
# Uso:
#   ./scripts/loadtest.sh                 # pico padrao (50 req/s)
#   PEAK=100 HOLD=30s ./scripts/loadtest.sh
#
# Acompanhe ao vivo no Grafana: http://localhost:3000 (dashboard "Ingressos").
set -euo pipefail

PEAK="${PEAK:-50}"
RAMP="${RAMP:-10s}"
HOLD="${HOLD:-20s}"
NETWORK="${NETWORK:-fabiano_default}"

LOAD_DIR="$(cd "$(dirname "$0")/../tests/load" && pwd)"

echo "==> Rodando k6 (pico=${PEAK} rps, ramp=${RAMP}, hold=${HOLD})"
echo "    Veja a fila no Grafana: http://localhost:3000"

docker run --rm -i \
  --network "$NETWORK" \
  -v "${LOAD_DIR}:/scripts" \
  grafana/k6 run /scripts/purchase-burst.js \
  -e API=http://api:8080 \
  -e PEAK="$PEAK" -e RAMP="$RAMP" -e HOLD="$HOLD"
