# ============================================================================
# MENSAGERIA REAL NA AWS (Fase 6) — SQS + SNS + Lambda de e-mail.
#
# Por que este arquivo existe: até aqui o Terraform só subia o cluster k3s, e a
# aplicação dentro dele falava com um LocalStack interno (onde a Lambda NÃO roda,
# pois o LocalStack executa Lambda via socket do Docker, indisponivel no pod).
# Resultado: o e-mail de confirmacao nunca era enviado na nuvem.
#
# Aqui provisionamos os recursos REAIS. A aplicacao (api/worker), rodando nos
# pods do master, usa as credenciais da LabRole via IMDS (ver metadata_options
# em master.tf) e o overlay infra/k8s/overlays/aws ESVAZIA o AWS_ENDPOINT_URL,
# fazendo o SDK falar com a AWS de verdade em vez do LocalStack.
#
# Fluxo do e-mail (decisao do usuario — ver ADR-009):
#   pagamento -> API publica no SNS "order-confirmed"
#             -> SNS invoca a Lambda "email-confirmation"
#             -> Lambda formata e publica no SNS "order-emails"
#             -> assinatura de e-mail do "order-emails" entrega na caixa do
#                destinatario fixo (var.notify_email).
# Mantemos a Lambda no caminho (requisito obrigatorio da avaliacao) e evitamos
# o sandbox do SES (que exigiria verificar cada destinatario).
# ============================================================================

# --- LabRole: referenciada, NUNCA criada (restricao do Learner Lab) ----------
# A Lambda precisa de uma role de execucao; usamos a LabRole pre-existente.
data "aws_iam_role" "lab" {
  name = var.lab_role_name
}

# --- Fila virtual de compra (consumida pelo worker) --------------------------
# Mesmo nome que a app resolve por GetQueueUrl (config QUEUE_NAME).
resource "aws_sqs_queue" "purchase" {
  name                       = var.queue_name
  visibility_timeout_seconds = 30
}

# --- Topico "pedido confirmado": a API publica aqui apos o pagamento ---------
# Mesmo nome que a app resolve por CreateTopic (idempotente, config TOPIC_NAME).
resource "aws_sns_topic" "order_confirmed" {
  name = var.topic_name
}

# --- Topico de notificacao por e-mail (a Lambda publica aqui) ----------------
resource "aws_sns_topic" "order_emails" {
  name = var.email_topic_name
}

# Assinatura de e-mail: a confirmacao chega neste endereco fixo. Ao dar apply, a
# AWS envia um e-mail "AWS Notification - Subscription Confirmation" para
# var.notify_email; e PRECISO clicar no link UMA VEZ para ativar a entrega.
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.order_emails.arn
  protocol  = "email"
  endpoint  = var.notify_email
}

# --- Empacota a Lambda a partir do dist/ (compilado por tsc) ------------------
# Rode antes:  npm run build --workspace services/lambda-email
# O AWS SDK v3 (clients sns/ses) ja vem no runtime nodejs20.x, entao o zip leva
# so o handler compilado + package.json (sem node_modules).
data "archive_file" "lambda_email" {
  type        = "zip"
  source_dir  = "${path.module}/../../services/lambda-email/dist"
  output_path = "${path.module}/lambda-email.zip"
}

resource "aws_lambda_function" "email" {
  function_name = var.lambda_name
  role          = data.aws_iam_role.lab.arn
  runtime       = "nodejs20.x"
  handler       = "handler.handler"
  timeout       = 30

  filename         = data.archive_file.lambda_email.output_path
  source_code_hash = data.archive_file.lambda_email.output_base64sha256

  environment {
    variables = {
      # Presenca desta var faz o handler publicar no SNS (em vez de usar SES).
      NOTIFY_TOPIC_ARN = aws_sns_topic.order_emails.arn
    }
  }
}

# Permite que o SNS "order-confirmed" invoque a Lambda.
resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.email.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.order_confirmed.arn
}

# Assina a Lambda no topico de pedidos confirmados.
resource "aws_sns_topic_subscription" "to_lambda" {
  topic_arn = aws_sns_topic.order_confirmed.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.email.arn
}
