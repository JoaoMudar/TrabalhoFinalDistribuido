# Provider AWS. As CREDENCIAIS NÃO ficam aqui: o Terraform lê do ~/.aws/credentials
# (perfil "default"), onde você cola as credenciais TEMPORÁRIAS do Learner Lab
# (Access Key + Secret + aws_session_token) a cada sessão. Nada de segredo no repo.
provider "aws" {
  region = var.aws_region

  # Tags aplicadas a TODOS os recursos — facilita achar e destruir o que é do trabalho.
  default_tags {
    tags = {
      Project = "ingressos-distribuidos"
      Owner   = "trabalho-distribuidos-2026"
      Managed = "terraform"
    }
  }
}
