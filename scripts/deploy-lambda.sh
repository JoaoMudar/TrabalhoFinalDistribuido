#!/bin/bash
# Deploy da Lambda de e-mail no LocalStack (Fase 3) — Linux/macOS.
# Equivalente ao deploy-lambda.ps1. Uso: ./scripts/deploy-lambda.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LAMBDA_DIR="$ROOT/services/lambda-email"
DIST="$LAMBDA_DIR/dist"
ZIP="$LAMBDA_DIR/function.zip"

CONTAINER="fabiano-localstack-1"
REGION="us-east-1"
ACCOUNT="000000000000"
FN_NAME="email-confirmation"
TOPIC_ARN="arn:aws:sns:${REGION}:${ACCOUNT}:order-confirmed"
LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT}:function:${FN_NAME}"

echo "[deploy-lambda] instalando deps e compilando..."
(cd "$ROOT" && npm install --silent && npm run build --workspace services/lambda-email)

echo "[deploy-lambda] empacotando function.zip..."
cp "$LAMBDA_DIR/package.json" "$DIST/package.json"
rm -f "$ZIP"
(cd "$DIST" && zip -qr "$ZIP" .)

echo "[deploy-lambda] copiando zip para o container..."
docker cp "$ZIP" "${CONTAINER}:/tmp/function.zip"

if docker exec "$CONTAINER" awslocal lambda get-function --function-name "$FN_NAME" >/dev/null 2>&1; then
  echo "[deploy-lambda] função existe — atualizando código..."
  docker exec "$CONTAINER" awslocal lambda update-function-code \
    --function-name "$FN_NAME" --zip-file fileb:///tmp/function.zip >/dev/null
else
  echo "[deploy-lambda] criando função..."
  docker exec "$CONTAINER" awslocal lambda create-function \
    --function-name "$FN_NAME" \
    --runtime nodejs20.x \
    --handler handler.handler \
    --role "arn:aws:iam::${ACCOUNT}:role/lambda-role" \
    --timeout 30 \
    --zip-file fileb:///tmp/function.zip >/dev/null
fi

docker exec "$CONTAINER" awslocal lambda wait function-active-v2 --function-name "$FN_NAME"

docker exec "$CONTAINER" awslocal lambda add-permission \
  --function-name "$FN_NAME" --statement-id sns-invoke \
  --action "lambda:InvokeFunction" --principal sns.amazonaws.com \
  --source-arn "$TOPIC_ARN" >/dev/null 2>&1 || echo "[deploy-lambda] permissão já existia (ok)"

if docker exec "$CONTAINER" awslocal sns list-subscriptions-by-topic --topic-arn "$TOPIC_ARN" | grep -q "$LAMBDA_ARN"; then
  echo "[deploy-lambda] assinatura SNS->Lambda já existe (ok)"
else
  echo "[deploy-lambda] assinando a Lambda no tópico SNS..."
  docker exec "$CONTAINER" awslocal sns subscribe \
    --topic-arn "$TOPIC_ARN" --protocol lambda \
    --notification-endpoint "$LAMBDA_ARN" >/dev/null
fi

echo "[deploy-lambda] concluído ✔"
