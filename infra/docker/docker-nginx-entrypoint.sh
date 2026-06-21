#!/bin/sh
# Entrypoint do container do frontend (Fase 5).
# Lê o primeiro nameserver do /etc/resolv.conf (o DNS do cluster Kubernetes,
# ou o DNS do Docker quando rodando isolado) e injeta no nginx.conf, para que o
# Nginx resolva o upstream da API em tempo de requisição. Depois sobe o Nginx.
set -e

RESOLVER="$(awk '/^nameserver/ { print $2; exit }' /etc/resolv.conf)"
if [ -z "$RESOLVER" ]; then
  RESOLVER="127.0.0.11" # fallback: DNS embutido do Docker
fi

sed -i "s/__DNS_RESOLVER__/${RESOLVER}/g" /etc/nginx/conf.d/default.conf
echo "[entrypoint] resolver do Nginx = ${RESOLVER}"

exec nginx -g 'daemon off;'
