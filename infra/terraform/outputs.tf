# ============================================================================
# Saídas úteis após o apply (acesso e verificação).
# Sem EIP/instância fixa: o endpoint estável agora é o DNS do NLB.
# ============================================================================

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

# O master vive num ASG, então não há IP fixo. Use a CLI para descobri-lo:
output "find_master_ip" {
  description = "Descobre o IP público do nó master (que está no ASG)."
  value       = "aws ec2 describe-instances --filters 'Name=tag:Role,Values=k3s-server' 'Name=instance-state-name,Values=running' --query 'Reservations[].Instances[].PublicIpAddress' --output text"
}
