#!/bin/bash
# ==========================================================================
# BLOCO DE CONFIG DO MASTER — gerado pelo Terraform (templatefile).
# Só define variáveis; o corpo do script vem de master-body.sh (concatenado).
# ==========================================================================
set -euxo pipefail
exec > >(tee -a /var/log/userdata-master.log) 2>&1
echo ">>> [master] iniciando user-data em $(date)"

# Valores injetados pelo Terraform:
K3S_TOKEN_VALUE='${k3s_token}'
MASTER_EIP='${master_eip}'
REPO_URL='${repo_url}'
REPO_BRANCH='${repo_branch}'
