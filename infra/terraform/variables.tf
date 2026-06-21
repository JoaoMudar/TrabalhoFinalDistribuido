# ============================================================================
# Variáveis de entrada. Valores reais ficam em terraform.tfvars (NÃO commitado).
# Veja terraform.tfvars.example para um ponto de partida.
# ============================================================================

variable "aws_region" {
  description = "Região AWS (Learner Lab usa us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "key_name" {
  description = "Nome de uma key pair EXISTENTE no Learner Lab (padrão do AWS Academy é 'vockey')."
  type        = string
  default     = "vockey"
}

variable "instance_profile" {
  description = "Instance Profile da LabRole (NÃO criamos IAM; só referenciamos o que o lab já oferece)."
  type        = string
  default     = "LabInstanceProfile"
}

variable "master_instance_type" {
  description = "Tipo da EC2 master (precisa de RAM p/ buildar as 3 imagens docker)."
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "Tipo das EC2 worker (k3s agent)."
  type        = string
  default     = "t3.small"
}

variable "worker_count" {
  description = "Quantidade desejada de workers no Auto Scaling Group."
  type        = number
  default     = 2
}

variable "k3s_token" {
  description = "Token estático pré-compartilhado do cluster k3s (master e workers usam o MESMO)."
  type        = string
  default     = "trabalho-distribuidos-2026"
  sensitive   = true
}

variable "repo_url" {
  description = "URL do monorepo que a master clona e builda no boot."
  type        = string
  default     = "https://github.com/JoaoMudar/TrabalhoFinalDistribuido.git"
}

variable "repo_branch" {
  description = "Branch do repo a clonar."
  type        = string
  default     = "main"
}

variable "ssh_ingress_cidr" {
  description = "CIDR autorizado a entrar por SSH (22). Restrinja ao seu IP se possível."
  type        = string
  default     = "0.0.0.0/0"
}
