# Versões fixadas para reprodutibilidade (vira insumo da seção de metodologia do artigo).
terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
