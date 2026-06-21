#!/bin/bash
# Script de inicialização do LocalStack.
# Executado automaticamente quando o LocalStack fica "ready" (ver volume montado
# em /etc/localstack/init/ready.d no docker-compose.yml).
#
# Cria os recursos de mensageria que o sistema usará (nomes coerentes com o
# fluxo descrito no CLAUDE.md). A integração no código entra na Fase 2.

set -euo pipefail

echo "[localstack-init] criando recursos de mensageria..."

# Fila virtual de compra (Fase 2). Visibility timeout de 30s como ponto de partida.
awslocal sqs create-queue \
  --queue-name ticket-purchase-queue \
  --attributes VisibilityTimeout=30

# Tópico de "pedido confirmado" -> aciona a Lambda de e-mail (Fase 3).
awslocal sns create-topic \
  --name order-confirmed

# Identidade SES do remetente (Fase 3). A Lambda envia o e-mail de confirmação
# a partir deste endereço; no LocalStack basta "verificar" a identidade.
awslocal ses verify-email-identity --email-address no-reply@ingressos.local

echo "[localstack-init] recursos criados:"
awslocal sqs list-queues
awslocal sns list-topics
awslocal ses list-identities
echo "[localstack-init] concluído."
