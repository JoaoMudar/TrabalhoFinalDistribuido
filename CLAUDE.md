# CLAUDE.md — Plataforma de Venda de Ingressos (Trabalho Distribuídos AWS)

## Contexto do projeto
Trabalho semestral acadêmico da disciplina de Sistemas Distribuídos. O objetivo é
construir uma aplicação completa rodando em um sistema distribuído na AWS, com
front-end + back-end funcionais, cluster Kubernetes, mensageria, Lambda e banco
distribuído. A entrega final inclui apresentação + artigo científico.

**Problemática escolhida:** venda de ingressos para eventos populares, onde há
picos súbitos de acesso (ex.: abertura de vendas de um show). O desafio distribuído
é garantir que não se venda o mesmo assento duas vezes, suportar a carga, e dar
feedback ao usuário sem derrubar o sistema.

## Solução proposta (resumo da arquitetura)
1. **Fila virtual (SQS):** no pico, requisições de compra entram numa fila. O usuário
   recebe uma posição na fila em vez de bater direto no banco. Workers consomem a fila
   num ritmo controlado (smoothing de carga / backpressure).
2. **Reserva temporária de assento (Redis com TTL):** ao chegar a vez do usuário, o
   assento é travado no Redis com um TTL (ex.: 5 min). Se ele não concluir o pagamento,
   o lock expira e o assento volta a ficar disponível. Garante exclusão mútua distribuída.
3. **Confirmação por e-mail (Lambda + SNS):** após pagamento confirmado, publica-se um
   evento no SNS; uma Lambda assina o tópico e dispara o e-mail de confirmação
   (desacoplamento total do fluxo de compra).
4. **Persistência (MongoDB):** eventos, assentos, pedidos e usuários. Banco
   distribuído/documentos.

## Critérios de avaliação (NÃO esquecer nenhum — total 10 pts)
- **Apresentação (3 pts)**
- **Desenvolvimento (2 pts):** design/desenho do projeto, modelos de arquitetura,
  deploy da aplicação, observabilidade, distribuição e isolamento dos componentes.
- **Artigo (1 pt):** precisa refletir exatamente o que foi desenvolvido.
- **Componentes obrigatórios (4 pts):**
  - [ ] Pelo menos um cluster Kubernetes (EKS)
  - [ ] Lambda
  - [ ] Mensageria (SQS + SNS)
  - [ ] Banco distribuído (Redis + MongoDB)
  - [ ] Front-end + back-end funcionais

## Mapeamento requisito → componente (rastreabilidade para o artigo)
| Requisito da avaliação      | Como atendemos                                  |
|-----------------------------|-------------------------------------------------|
| Cluster Kubernetes          | k3s sobre EC2 (Learner Lab) rodando API + workers + frontend |
| Lambda                      | Envio de e-mail de confirmação                  |
| SQS                         | Fila virtual de compra                          |
| SNS                         | Evento "pedido confirmado" → Lambda             |
| Banco distribuído           | Redis (locks/TTL) + MongoDB (dados)             |
| Front + back                | SPA + API REST                                  |
| Observabilidade             | CloudWatch (logs/métricas) + Prometheus/Grafana |
| Isolamento de componentes   | Namespaces no K8s + filas desacoplando serviços |

## Stack técnica (decisões fixas — não trocar sem perguntar)
- **Backend:** Node.js + TypeScript (Express ou Fastify) — API REST.
- **Workers:** processo Node separado que consome SQS.
- **Frontend:** React + Vite (SPA simples: lista de eventos → mapa de assentos → fila → checkout → confirmação).
- **Banco:** MongoDB (dados), Redis (locks com TTL + posição na fila).
- **Mensageria:** AWS SQS (fila), AWS SNS (notificação).
- **Serverless:** AWS Lambda (e-mail via SES ou SNS→e-mail).
- **Orquestração:** Kubernetes — **k3s sobre EC2** na AWS (Learner Lab), kind/minikube local.
- **IaC:** Terraform para os recursos AWS (EC2+k3s, SQS, SNS, Lambda); **sem criar IAM** (usa a `LabRole` pré-existente do Learner Lab).
- **Dev local:** docker-compose com LocalStack (emula SQS/SNS/Lambda), Redis e Mongo.
- **Observabilidade:** logs estruturados (pino), CloudWatch em prod, Prometheus + Grafana no cluster.

## Ambiente AWS para a demonstração (DECISÃO FIXA — AWS Academy Learner Lab)
A entrega na nuvem (Fase 6) será feita no **AWS Academy Learner Lab**, não numa
conta AWS comum. Isso impõe restrições que a Fase 6 PRECISA respeitar:
- **IAM travado:** não é possível criar roles/policies. Usar **somente a role
  pré-existente `LabRole`** (ARN exposto no painel do lab). Terraform NÃO deve
  declarar `aws_iam_role`/`aws_iam_policy` — apenas referenciar a `LabRole`.
- **Credenciais temporárias:** expiram a cada ~3–4h e trazem `aws_session_token`.
  São copiadas do botão "AWS Details → AWS CLI" para `~/.aws/credentials` a cada
  sessão. Nada de credenciais de longa duração no repo.
- **Região:** em geral fixada em `us-east-1`.
- **Orçamento limitado (~US$50–100)** e recursos podem ser ceifados: provisionar,
  demonstrar para o professor e **`terraform destroy` logo em seguida**.
- **Cluster Kubernetes:** EKS costuma ser bloqueado/caro no Learner Lab →
  usaremos **k3s instalado sobre instância(s) EC2** (cluster Kubernetes real,
  contorna a restrição de EKS e cabe no orçamento).
- **ECR** pode não estar disponível → alternativa: imagens no Docker Hub ou
  `docker save`/`load` nas EC2.

## Estrutura de pastas (monorepo)

/apps

/api          → backend REST

/worker       → consumidor da fila SQS

/web          → frontend React

/services

/lambda-email → função Lambda de confirmação

/infra

/terraform    → IaC AWS (EC2+k3s, SQS, SNS, Lambda; usa LabRole, não cria IAM)

/k8s          → manifests Kubernetes (deployments, services, ingress, namespaces)

/docker       → Dockerfiles

/docs

/artigo       → rascunho do artigo + diagramas

/diagramas    → arquitetura (draw.io / mermaid)

docker-compose.yml

CLAUDE.md

README.md

## Fluxo principal (caminho feliz)
1. Usuário abre evento e escolhe assento no frontend.
2. API recebe a intenção → coloca pedido na **fila SQS** e devolve um ticket de fila.
3. Frontend faz polling da posição na fila (posição guardada no Redis).
4. Worker consome a fila → tenta dar **lock no Redis (SETNX + TTL)** no assento.
   - Lock obtido → assento reservado por 5 min, retorna sucesso.
   - Lock falhou → assento já reservado, avisa o usuário.
5. Usuário "paga" (mock de pagamento) dentro do TTL.
6. Pagamento confirmado → grava pedido no Mongo → publica no **SNS**.
7. **Lambda** assina o SNS e envia e-mail de confirmação.
8. Se o TTL expira sem pagamento → assento liberado automaticamente.

## Roadmap por fases
- **Fase 0 — Scaffolding:** estrutura de pastas, docker-compose, esqueletos, README.
- **Fase 1 — Backend core:** modelos Mongo, endpoints, lock Redis com TTL (rodando local).
- **Fase 2 — Mensageria:** integração SQS (fila virtual) + worker + SNS, tudo no LocalStack.
- **Fase 3 — Lambda:** função de e-mail assinando o SNS.
- **Fase 4 — Frontend:** telas de evento, assentos, fila e confirmação.
- **Fase 5 — Containerização:** Dockerfiles + manifests K8s (rodando em kind/minikube).
- **Fase 6 — AWS/Terraform:** provisionar EKS, SQS, SNS, Lambda reais; deploy.
- **Fase 7 — Observabilidade:** logs, métricas, Prometheus/Grafana, CloudWatch.
- **Fase 8 — Teste de carga:** simular pico (k6/artillery) para provar a fila funcionando.
- **Fase 9 — Artigo + diagramas + apresentação.**

## Diretrizes de trabalho para o Claude Code
- Sempre apresentar um plano antes de gerar muito código; pedir aprovação em decisões grandes.
- Código comentado e legível — é trabalho acadêmico, a clareza vale nota.
- Cada fase deve ser rodável e testável localmente antes de avançar.
- Manter o README atualizado a cada fase (vira insumo direto do artigo).
- Gerar diagramas em mermaid sempre que descrever arquitetura (reuso no artigo).
- Priorizar custo zero/baixo na AWS: a demo na nuvem roda no **AWS Academy Learner Lab** (orçamento limitado); destruir recursos com `terraform destroy` logo após mostrar ao professor.
- Documentar TODA decisão de arquitetura num arquivo /docs/decisoes.md (vira a seção de metodologia do artigo).

## Estrutura prevista do artigo (preencher ao longo do projeto)
1. Introdução e problemática (picos de acesso em venda de ingressos)
2. Fundamentação: sistemas distribuídos, exclusão mútua, desacoplamento, mensageria
3. Arquitetura proposta (diagramas)
4. Tecnologias e justificativas (mapeamento requisito→componente acima)
5. Implementação (por componente)
6. Observabilidade e resultados do teste de carga
7. Conclusão e trabalhos futuros