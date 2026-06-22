# Fase 6 — Infra AWS com Terraform (Learner Lab)

Provisiona o cluster k3s na AWS de forma reproduzível e descartável:

- **1 EC2 master** (k3s server) com IP privado fixo; endpoint público via NLB.
- **Auto Scaling Group de workers** (k3s agent) que fazem **join sozinhas** pelo IP privado do master.
- **Security Group** liberando as portas internas do cluster entre os nós e SSH/HTTP pra fora.
- **Mensageria real** (`messaging.tf`): fila **SQS**, tópico **SNS** `order-confirmed`,
  **Lambda** de e-mail e tópico **SNS** `order-emails` com assinatura de e-mail.
- Master clona o repo, builda as 3 imagens (api/worker/web), importa no containerd, aplica
  os manifests e **remove `AWS_ENDPOINT_URL`** do ConfigMap → a app passa a usar a AWS real.

Tudo usando a **LabRole** (não cria IAM), em `us-east-1`.

## Fluxo do e-mail de confirmação (Fase 3 na nuvem)

```
pagamento → API publica no SNS "order-confirmed"
          → SNS invoca a Lambda "email-confirmation"
          → Lambda formata e publica no SNS "order-emails"
          → assinatura de e-mail entrega na caixa de notify_email
```

A app (api/worker) autentica na AWS com as credenciais da **LabRole** obtidas via **IMDS**
da EC2 (por isso `metadata_options { http_put_response_hop_limit = 2 }` no master/worker —
sem isso os pods não alcançam o IMDS). Antes era só LocalStack interno (Lambda não roda lá),
e por isso o e-mail nunca saía.

> ⚠️ **Confirme a inscrição de e-mail!** Logo após o `apply`, a AWS envia um e-mail
> *"AWS Notification - Subscription Confirmation"* para `notify_email`. **Clique no link**
> uma vez; sem isso a Lambda publica mas nada chega à caixa. O output
> `email_subscription_reminder` lembra disso.

## Pré-requisitos

1. **Credenciais temporárias do Learner Lab** coladas em `~/.aws/credentials` (botão *AWS Details → AWS CLI*). Expiram a cada ~3-4h — recole quando expirar.
2. **Terraform >= 1.5** instalado.
3. A key pair **`vockey`** existe no lab (padrão do AWS Academy). Baixe o `vockey.pem` se for usar SSH.

## Uso

```bash
cd infra/terraform

cp terraform.tfvars.example terraform.tfvars   # ajuste: defina notify_email!

# Empacota a Lambda a partir do código compilado (o Terraform zipa o dist/):
npm run build --workspace services/lambda-email   # rode na RAIZ do repo

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
