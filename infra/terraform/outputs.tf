# ============================================================================
# Saídas úteis após o apply (acesso e verificação).
# Endpoint público estável = DNS do NLB. O master agora é uma aws_instance com
# IP fixo, então também expomos os IPs dele diretamente (útil pra SSH/debug).
# ============================================================================

output "master_public_ip" {
  description = "IP público do master (SSH e debug)."
  value       = aws_instance.master.public_ip
}

output "master_private_ip" {
  description = "IP privado FIXO do master (usado no join das workers)."
  value       = aws_instance.master.private_ip
}

output "lb_dns_name" {
  description = "DNS do NLB — endpoint estável do cluster (frontend e k3s API)."
  value       = aws_lb.main.dns_name
}

output "frontend_url" {
  description = "URL do frontend via NLB (porta 80 -> Traefik nos nós)."
  value       = "http://${aws_lb.main.dns_name}"
}

output "k3s_api_endpoint" {
  description = "Endpoint do k3s API via NLB (porta 6443) p/ kubectl externo."
  value       = "https://${aws_lb.main.dns_name}:6443"
}

output "check_nodes" {
  description = "Na master, confira o cluster com este comando."
  value       = "sudo k3s kubectl get nodes -o wide"
}

output "ssh_master" {
  description = "Comando pronto p/ SSH no master."
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.master.public_ip}"
}

# --- Mensageria real (messaging.tf) -----------------------------------------

output "sqs_queue_url" {
  description = "URL da fila SQS de compra."
  value       = aws_sqs_queue.purchase.url
}

output "sns_order_confirmed_arn" {
  description = "ARN do tópico SNS de pedido confirmado (a API publica aqui)."
  value       = aws_sns_topic.order_confirmed.arn
}

output "sns_order_emails_arn" {
  description = "ARN do tópico SNS de notificação por e-mail (a Lambda publica aqui)."
  value       = aws_sns_topic.order_emails.arn
}

output "lambda_name" {
  description = "Nome da Lambda de confirmação por e-mail."
  value       = aws_lambda_function.email.function_name
}

output "email_subscription_reminder" {
  description = "LEMBRETE: confirme a inscrição de e-mail antes da demo."
  value       = "Abra a caixa de ${var.notify_email} e clique em 'Confirm subscription' (assunto: AWS Notification - Subscription Confirmation). Sem isso o e-mail NÃO chega."
}
