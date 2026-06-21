# Deploy da Lambda de e-mail no LocalStack (Fase 3) - Windows/PowerShell.
#
# Por que um script separado (e nao o localstack-init)? O init roda no boot do
# LocalStack, antes de a Lambda existir compilada. Este script roda DEPOIS do
# 'docker-compose up': compila, empacota e registra a funcao + assinatura SNS.
#
# Uso:  ./scripts/deploy-lambda.ps1

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$lambdaDir = Join-Path $root "services/lambda-email"
$dist = Join-Path $lambdaDir "dist"
$zip = Join-Path $lambdaDir "function.zip"

$container = "fabiano-localstack-1"
$region = "us-east-1"
$account = "000000000000"
$fnName = "email-confirmation"
$topicArn = "arn:aws:sns:${region}:${account}:order-confirmed"
$lambdaArn = "arn:aws:lambda:${region}:${account}:function:${fnName}"

Write-Host "[deploy-lambda] instalando deps e compilando..."
Push-Location $root
npm install --silent
npm run build --workspace services/lambda-email
Pop-Location

Write-Host "[deploy-lambda] empacotando function.zip..."
# package.json (CommonJS) precisa ir no zip para o handler .js carregar como CJS.
Copy-Item (Join-Path $lambdaDir "package.json") (Join-Path $dist "package.json") -Force
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path (Join-Path $dist "*") -DestinationPath $zip -Force

Write-Host "[deploy-lambda] copiando zip para o container..."
docker cp $zip "${container}:/tmp/function.zip"

# A partir daqui as chamadas 'docker exec' podem escrever no stderr (esperado em
# checagens que falham de proposito). Como validamos via $LASTEXITCODE, evitamos
# que o PowerShell trate esse stderr como erro fatal.
$ErrorActionPreference = "Continue"

# Cria ou atualiza a funcao (idempotente).
$exists = $false
docker exec $container awslocal lambda get-function --function-name $fnName *> $null
if ($LASTEXITCODE -eq 0) { $exists = $true }

if ($exists) {
  Write-Host "[deploy-lambda] funcao existe - atualizando codigo..."
  docker exec $container awslocal lambda update-function-code --function-name $fnName --zip-file fileb:///tmp/function.zip | Out-Null
} else {
  Write-Host "[deploy-lambda] criando funcao..."
  docker exec $container awslocal lambda create-function --function-name $fnName --runtime nodejs20.x --handler handler.handler --role "arn:aws:iam::${account}:role/lambda-role" --timeout 30 --zip-file fileb:///tmp/function.zip | Out-Null
}

Write-Host "[deploy-lambda] aguardando funcao ficar ativa..."
docker exec $container awslocal lambda wait function-active-v2 --function-name $fnName

# Permite o SNS invocar a Lambda (ignora se ja existir).
docker exec $container awslocal lambda add-permission --function-name $fnName --statement-id sns-invoke --action "lambda:InvokeFunction" --principal sns.amazonaws.com --source-arn $topicArn *> $null
if ($LASTEXITCODE -ne 0) { Write-Host "[deploy-lambda] permissao ja existia (ok)" }

# Assina a Lambda no topico SNS, evitando duplicar a assinatura.
$subs = docker exec $container awslocal sns list-subscriptions-by-topic --topic-arn $topicArn | Out-String
if ($subs -match [regex]::Escape($lambdaArn)) {
  Write-Host "[deploy-lambda] assinatura SNS para Lambda ja existe (ok)"
} else {
  Write-Host "[deploy-lambda] assinando a Lambda no topico SNS..."
  docker exec $container awslocal sns subscribe --topic-arn $topicArn --protocol lambda --notification-endpoint $lambdaArn | Out-Null
}

Write-Host "[deploy-lambda] concluido OK"
