# Fase 6 — Infra AWS com Terraform (Learner Lab)

Provisiona o cluster k3s na AWS de forma reproduzível e descartável:

- **1 EC2 master** (k3s server) com **Elastic IP** grudado automaticamente.
- **Auto Scaling Group de workers** (k3s agent) que fazem **join sozinhas** pelo IP privado do master.
- **Security Group** liberando as portas internas do cluster entre os nós e SSH/HTTP pra fora.
- Master clona o repo, builda as 3 imagens (api/worker/web), importa no containerd e aplica os manifests.

Tudo usando a **LabRole** (não cria IAM), em `us-east-1`.

## Pré-requisitos

1. **Credenciais temporárias do Learner Lab** coladas em `~/.aws/credentials` (botão *AWS Details → AWS CLI*). Expiram a cada ~3-4h — recole quando expirar.
2. **Terraform >= 1.5** instalado.
3. A key pair **`vockey`** existe no lab (padrão do AWS Academy). Baixe o `vockey.pem` se for usar SSH.

## Uso

```bash
cd infra/terraform

cp terraform.tfvars.example terraform.tfvars   # ajuste se quiser

terraform init
terraform plan
terraform apply        # responda "yes"
```

Ao final, os **outputs** mostram o IP público, o comando SSH e a URL do frontend.

### Acompanhar o boot

```bash
# SSH na master (use o output ssh_master)
ssh -i vockey.pem ubuntu@<EIP>

# logs do provisionamento
sudo tail -f /var/log/userdata-master.log

# quando terminar, confira os nós (master + workers devem aparecer Ready)
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
```

O frontend abre em `http://<EIP>` (output `frontend_url`).

## Destruir (faça logo após mostrar ao professor)

```bash
terraform destroy     # responda "yes"
```

Isso apaga EC2, ASG, EIP e SG — zera o custo. **Não esqueça**: orçamento do lab é limitado.

## Notas de arquitetura

- **Workers joinam pelo IP PRIVADO** do master. Pelo Elastic IP, de dentro da VPC, o join falha (hairpinning) — por isso o privado é o endpoint interno. O EIP é só p/ acesso externo (SSH/navegador/kubectl).
- O EIP é incluído no `--tls-san` do k3s server, então dá pra usar `kubectl` de fora pelo IP público se quiser.
- A AMI é Ubuntu 22.04 **limpa** (sem k3s pré-instalado), evitando o conflito de porta 6444 que trava o agent. Mesmo assim o user-data da worker faz uma limpeza defensiva antes do join.
- Se aumentar `worker_count`, o ASG sobe mais workers e cada uma entra sozinha no cluster.
