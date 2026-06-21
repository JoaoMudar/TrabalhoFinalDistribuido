# ============================================================================
# Saídas úteis após o apply (acesso e verificação).
# ============================================================================

output "master_public_ip" {
  description = "Elastic IP do master (use para SSH e abrir o frontend)."
  value       = aws_eip.master.public_ip
}

output "master_private_ip" {
  description = "IP privado do master (endpoint de join das workers)."
  value       = aws_instance.master.private_ip
}

output "ssh_master" {
  description = "Comando pronto p/ acessar a master."
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_eip.master.public_ip}"
}

output "frontend_url" {
  description = "URL do frontend via ingress (Traefik na porta 80)."
  value       = "http://${aws_eip.master.public_ip}"
}

output "check_nodes" {
  description = "Na master, confira o cluster com este comando."
  value       = "sudo k3s kubectl get nodes -o wide"
}
