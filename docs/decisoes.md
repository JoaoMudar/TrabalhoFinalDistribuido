# Decisões de Arquitetura (ADRs)

Registro de TODAS as decisões de arquitetura do projeto. Vira a seção de
**metodologia** do artigo. Formato leve de ADR (Architecture Decision Record).

---

## ADR-000 — Decisões da Fase 0 (Scaffolding)

**Data:** 2026-06-16
**Status:** Aceito

### Contexto
Início do projeto. Precisávamos definir as fundações do monorepo antes de
escrever lógica de negócio, mantendo a stack já fixada no `CLAUDE.md`.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Framework da API | **Fastify** | Mais performático que Express e com validação/serialização por schema nativa — bom argumento de performance sob carga (tema central do trabalho). |
| Gestão do monorepo | **npm workspaces** | Já vem com o Node, zero dependências extras; simples de explicar no artigo. |
| Linguagem | **TypeScript** | Tipagem ajuda na clareza (vale nota) e previne erros nas integrações distribuídas. |
| Frontend | **React + Vite** | SPA leve, dev server rápido com hot reload. |
| Dev local | **docker-compose + LocalStack** | Emula SQS/SNS/Lambda sem custo na AWS; sobe tudo com um comando. |
| Logs | **pino** | Logs estruturados (JSON), insumo para observabilidade (Fase 7). |

### Recursos de mensageria criados no boot (LocalStack)
- Fila SQS: `ticket-purchase-queue` (fila virtual de compra).
- Tópico SNS: `order-confirmed` (dispara a Lambda de e-mail).

### Portas (dev)
| Serviço | Porta |
|---|---|
| Frontend (web) | 5173 |
| API | 8080 |
| LocalStack | 4566 |
| Redis | 6379 |
| MongoDB | 27017 |

### Consequências
- Esqueleto sobe inteiro com `docker-compose up`; cada serviço já isolado em seu container.
- Lógica de negócio, conexões reais a Mongo/Redis e integração SQS/SNS ficam para as Fases 1–3.

---

## ADR-001 — Decisões da Fase 1 (Backend core)

**Data:** 2026-06-17
**Status:** Aceito

### Contexto
Implementação do fluxo de compra: modelos de dados, endpoints REST e a exclusão
mútua distribuída para não vender o mesmo assento duas vezes.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| ODM do MongoDB | **Mongoose** | Schemas explícitos e tipados (clareza vale nota); índices únicos declarativos. |
| Cliente Redis | **ioredis** | Suporte direto a `SET NX EX` e a scripts Lua (liberação atômica do lock). |
| Validação de input | **Schemas nativos do Fastify** | Evita dependência extra; serialização rápida sob carga. |
| Estado do assento | **`available`/`sold` no Mongo + lock no Redis** | O estado "reservado" é efêmero → vive só no Redis com TTL. Se o pagamento não vem, o lock expira sozinho e o assento se liberta, **sem job de limpeza**. |

### Exclusão mútua distribuída (núcleo do trabalho)
- Lock por assento: `SET lock:seat:{id} {token} EX 300 NX`.
  - `NX` garante atomicidade — só **um** processo adquire (exclusão mútua).
  - `EX 300` (5 min) = reserva temporária com expiração automática.
- Liberação segura via **script Lua** (compare-and-delete): só o dono do `token`
  (guardado no pedido, campo oculto `lockToken`) libera o lock.
- Disponibilidade exibida = `sold` (Mongo) **ou** `reserved` (lock ativo) **ou** `available`.

### Endpoints
`GET /events`, `GET /events/:id`, `GET /events/:id/seats`,
`POST /events/:id/seats/:seatId/reserve`, `POST /orders/:orderId/pay`, `GET /orders/:orderId`.

### Validação (testes via curl no docker-compose)
- Reserva → `201` com `orderId`/`expiresAt`/`ttlSeconds`.
- Reserva concorrente do mesmo assento → `409` (lock negado).
- Pagamento dentro do TTL → assento `sold`, pedido `paid` (idempotente).
- Pagamento após expiração do lock → `410` (reserva caiu).

### Consequências
- Fluxo de compra funciona de ponta a ponta localmente.
- A reserva ainda é **síncrona** (direto na API). A fila virtual SQS entra na
  Fase 2, colocando-se **na frente** deste fluxo para absorver picos.
- A publicação no SNS após o pagamento (gancho `TODO` em `orders.ts`) entra na Fase 3.

---

## ADR-002 — Decisões da Fase 2 (Mensageria: SQS + SNS)

**Data:** 2026-06-17
**Status:** Aceito

### Contexto
Para absorver picos de acesso, a compra não pode bater direto no banco. Era
preciso uma **fila virtual** que enfileire as intenções de compra e as processe
num ritmo controlado, dando feedback de posição ao usuário.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Fila | **AWS SQS** (LocalStack em dev) | Fila gerenciada, long polling, redelivery por visibility timeout. |
| Notificação | **AWS SNS** | Pub/sub: desacopla o pagamento do envio de e-mail (Fase 3). |
| SDK | **AWS SDK v3** (`@aws-sdk/client-sqs`, `-sns`) | Modular, mesmo cliente para dev (LocalStack) e prod (IAM Role). |
| **Quem faz a reserva** | **Worker chama o endpoint `reserve` da API** | Evita duplicar lógica de lock/Mongo. A API segue como única fonte de verdade do domínio; o worker cuida só do consumo controlado (backpressure). |
| Posição na fila | **Contadores no Redis** (`queue:seq`, `queue:processed`) | Cálculo O(1) da posição (`seq - processed - 1`), aproximação FIFO suficiente para o feedback. |
| Estado do ticket | **`ticket:{id}` no Redis (TTL 1h)** | Compartilhado entre API (escreve ao enfileirar) e worker (atualiza ao processar); o frontend faz polling em `GET /queue/:id`. |

### Fluxo da fila virtual
1. `POST /events/:id/seats/:seatId/purchase` → API grava o ticket no Redis,
   envia mensagem à SQS e devolve `202 { ticketId, position }`.
2. Frontend faz polling em `GET /queue/:ticketId`.
3. Worker faz long polling na SQS (até 20s), e para cada mensagem:
   marca `processing` → chama `reserve` na API → grava `reserved`/`failed` →
   `INCR queue:processed` → apaga a mensagem → aguarda `WORKER_RATE_MS` (smoothing).
4. No pagamento, a API publica `{orderId, eventId, seatId, userEmail}` no
   tópico SNS `order-confirmed` (sem derrubar o pagamento se o SNS falhar).

### Backpressure
O `WORKER_RATE_MS` (padrão 500ms) limita o ritmo de consumo, provando o
amortecimento de carga: sob pico, as mensagens se acumulam na SQS e são
drenadas de forma estável, em vez de saturar o banco.

### Validação (docker-compose)
- `purchase` → `202`; polling evolui `queued` → `reserved` com `orderId`.
- Concorrência no mesmo assento: um ticket `reserved`, outro `failed`
  ("assento reservado por outro usuário") — exclusão mútua preservada na fila.
- Pagamento → log `evento publicado no SNS order-confirmed`.

### Consequências
- A reserva síncrona (`reserve`) continua existindo, mas o caminho recomendado
  para o frontend é o assíncrono (`purchase` + polling).
- Falta a Lambda assinar o SNS e enviar o e-mail (Fase 3).

---

## ADR-003 — Decisões da Fase 3 (Lambda de e-mail)

**Data:** 2026-06-17
**Status:** Aceito

### Contexto
Após o pagamento, o e-mail de confirmação deve ser enviado de forma totalmente
desacoplada do fluxo de compra (serverless), atendendo ao requisito "Lambda".

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Gatilho | **SNS → Lambda** | Pub/sub assíncrono: o pagamento publica e segue; a Lambda reage. Falha no e-mail não afeta a compra. |
| Envio | **SES** (LocalStack) | Serviço gerenciado de e-mail; em dev as mensagens ficam inspecionáveis em `GET /_aws/ses`. |
| Empacotamento | **CommonJS** (`module: commonjs`, sem `type: module`) | Evita atritos de ESM no runtime do Lambda; `handler.handler` carrega direto. |
| AWS SDK na Lambda | **Fornecido pelo runtime** (`nodejs20.x`) | Não vai no `.zip` (fica como devDependency só p/ tipos) → artefato menor. |
| Deploy | **Script pós-`up`** (`scripts/deploy-lambda.{ps1,sh}`) | O `localstack-init` roda no boot, antes de a Lambda existir compilada; o deploy compila, empacota, cria a função e assina o SNS. |
| Execução de Lambda no LocalStack | **socket do Docker montado** + `LAMBDA_DOCKER_NETWORK` | O LocalStack executa a Lambda num container próprio; precisa do socket e de estar na mesma rede para a Lambda chamar o SES de volta. |

### Fluxo serverless
`POST /orders/:id/pay` → API publica no SNS `order-confirmed` → SNS invoca a
Lambda `email-confirmation` → Lambda envia e-mail via SES
(`no-reply@ingressos.local` → e-mail do comprador).

### Resiliência (lição aprendida)
Ao recriar o container do LocalStack, o worker (long polling na SQS) caía com
`ECONNREFUSED` e encerrava o processo. Tornamos o loop de consumo tolerante a
falhas transitórias (loga, espera 2s e tenta de novo) e adicionamos
`restart: unless-stopped` a API e worker no compose.

### Validação (docker-compose)
- Pagamento → mensagem aparece em `http://localhost:4566/_aws/ses` com
  remetente, destinatário, assunto e corpo corretos.
- Log da Lambda: `[lambda-email] e-mail enviado para <email> (MessageId=...)`.

### Consequências
- Componente "Lambda" e o uso pleno de SNS+SES atendidos.
- Em produção (Fase 6), troca-se o LocalStack pelo SES real (exige verificar
  domínio/remetente) e a Lambda é provisionada via Terraform.

---

## ADR-004 — Decisões da Fase 4 (Frontend)

**Data:** 2026-06-17
**Status:** Aceito

### Contexto
SPA que exercita o fluxo distribuído de ponta a ponta e dá feedback de fila ao
usuário, evidenciando a arquitetura na apresentação.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Caminho de compra | **Fila (`purchase` + polling)**, não a reserva síncrona | Espelha a arquitetura: a requisição entra na SQS, não bate direto no banco. |
| Comunicação com a API | **Proxy `/api` do Vite** | O frontend não precisa saber a URL real da API (vale para dev e para o Ingress no K8s). |
| Estado da UI | **Máquina de estados** (`events→seats→queue→checkout→done`) | Fluxo linear e fácil de explicar; cada passo = uma etapa da arquitetura. |
| Dev no container | **Bind mount + Vite HMR** | Hot-reload do código do host sem rebuild da imagem (também contornou indisponibilidade do registry). |

### Telas
1. **Eventos** + e-mail de confirmação.
2. **Mapa de assentos** (verde=livre, laranja=reservado, cinza=vendido).
3. **Fila** com posição (polling em `GET /queue/:ticketId`).
4. **Checkout** com contagem regressiva do TTL da reserva.
5. **Confirmação** (informa que o e-mail saiu via SNS→Lambda→SES).

### Validação
- Página em `http://localhost:5173` (HTTP 200); proxy `/api/events` retorna dados.
- Fluxo `purchase → reserved → pay → assento sold` executado pelo caminho real
  do frontend (através do proxy do Vite).

### Consequências
- Aplicação completa (front + back) funcional localmente — fecha o bloco de
  desenvolvimento. Faltam empacotamento/K8s (Fase 5) e AWS real (Fase 6).

---

## ADR-005 — Ambiente de nuvem: AWS Academy Learner Lab + k3s/EC2

**Data:** 2026-06-17
**Status:** Aceito

### Contexto
A entrega na nuvem (Fase 6) e a demonstração ao professor serão feitas no
**AWS Academy Learner Lab**, e não numa conta AWS comum. O Learner Lab tem
restrições que invalidam parte do plano original (EKS + IAM próprio via Terraform).

### Restrições do Learner Lab (premissas de projeto)
- **IAM travado:** não se pode criar roles/policies; só existe a role pré-provisionada
  `LabRole` (ou `voclabs`). Recursos que exigem role (EC2 instance profile, Lambda)
  reutilizam a `LabRole`.
- **Credenciais temporárias:** expiram a cada ~3–4h e incluem `aws_session_token`;
  recopiadas do painel "AWS Details" a cada sessão. Nada de chave longa no repo.
- **Orçamento limitado (~US$50–100)** e recursos podem ser ceifados.
- **Região** tipicamente fixada em `us-east-1`. **ECR** pode estar indisponível.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Onde provisionar | **AWS Academy Learner Lab** | Crédito da disciplina, sem cartão; é onde a demo será mostrada ao professor. |
| Cluster Kubernetes | **k3s sobre EC2** (não EKS) | EKS costuma ser bloqueado/caro no Learner Lab. k3s é um Kubernetes real, leve, roda em 1–2 EC2 e cabe no orçamento — atende ao requisito "cluster Kubernetes". |
| IAM | **Reutilizar `LabRole`** | O lab proíbe criar IAM; Terraform apenas referencia a role existente (`data`/variável), nunca declara `aws_iam_role`/`aws_iam_policy`. |
| Registro de imagens | **Docker Hub** (ou `docker save/load` nas EC2) | ECR pode faltar no lab. |
| Ciclo de vida | **provisionar → demonstrar → `terraform destroy`** | Orçamento limitado e recursos efêmeros; destruir logo após a apresentação. |
| Mensageria/serverless | **SQS, SNS, Lambda reais** (substituem o LocalStack) | Em dev seguem no LocalStack; em produção o endpoint fica vazio e o SDK usa a cadeia de credenciais padrão (LabRole). |

### Consequências
- O `infra/terraform/` da Fase 6 deve ser escrito SEM criar IAM e parametrizando
  a `LabRole` e o `aws_session_token`.
- O `infra/k8s/` (Fase 5) é reaproveitado: mesmos manifests rodam em kind/minikube
  (local) e no k3s/EC2 (nuvem) — só muda o contexto do `kubectl`.
- A apresentação precisa contar com a expiração das credenciais (renovar antes da demo).

---

## ADR-006 — Decisões da Fase 5 (Containerização + Kubernetes)

**Data:** 2026-06-17
**Status:** Aceito (manifests e imagens validados; execução em cluster pendente de
um cluster local instalado — ver Consequências)

### Contexto
Empacotar a aplicação em imagens e orquestrá-la em Kubernetes, com os **mesmos
manifests** servindo para o cluster local (kind/minikube) e para o k3s/EC2 da
Fase 6 (AWS Academy).

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Isolamento | **Dois namespaces:** `ingressos` (app) e `ingressos-data` (Mongo/Redis/LocalStack) | Atende ao critério "isolamento de componentes"; separa o que tem estado do que é descartável. |
| Frontend em prod | **Build do Vite servido por Nginx** (`web.prod.Dockerfile`) | O dev server do Vite não é para produção; Nginx serve estáticos e faz o proxy `/api`. |
| Proxy `/api` no Nginx | **Variável + `resolver` do cluster (injetado no boot)** | Com host literal, o Nginx falharia no start se o Service `api` não existisse (CrashLoop). Resolução em runtime torna o pod resiliente à ordem de subida e portável (kind/minikube/k3s). |
| Distribuição das imagens | **Build local + carga no cluster** (`kind load` / `minikube image load`), `imagePullPolicy: IfNotPresent` | Evita depender de registry no dev (e o ECR pode faltar no Learner Lab). |
| Réplicas | **api=2, worker=1** | API é sem estado (escala horizontal); o worker em 1 réplica mantém o `WORKER_RATE_MS` como ritmo agregado (controlável no teste de carga). |
| Probes | **readiness/liveness em `/health`** (api), exec (mongo/redis), httpGet (localstack/web) | Orquestração saudável: o K8s só roteia tráfego para pods prontos e reinicia os travados. |
| Entrada externa | **Ingress único → web** (web faz proxy interno de `/api`) | Um só ponto de entrada externo (isolamento); o backend não fica exposto. |
| LocalStack no cluster | **Apenas `sqs,sns,ses`** (sem execução de Lambda) | A execução de Lambda no LocalStack exige o socket do Docker, indisponível no pod. SNS continua recebendo o publish; o fluxo Lambda completo fica no compose (Fase 3) e na AWS real (Fase 6). |

### Validação (sem cluster, offline)
- `kubectl kustomize infra/k8s` gera **17 objetos** coerentes (2 ns, 2 cm, 5 svc,
  1 pvc, 6 deploy, 1 ingress) — YAML válido e bem combinado.
- Imagem `ingressos/web:latest` **builda**, `nginx -t` passa, o entrypoint injeta
  o resolver e `GET /` responde **200** servindo a SPA.

### Consequências
- **Falta executar num cluster vivo.** Na máquina atual não há kind/minikube e o
  Kubernetes do Docker Desktop está desligado. Para a validação end-to-end em
  cluster, basta instalar kind (ou ligar o k8s do Docker Desktop) e rodar
  `scripts/k8s-local.ps1`.
- Os mesmos manifests são reaproveitados na Fase 6 (k3s/EC2): trocar o Ingress
  para `traefik` e publicar as imagens no Docker Hub.

---

## ADR-007 — Decisões da Fase 7 (Observabilidade)

**Data:** 2026-06-17
**Status:** Aceito (validado no docker-compose)

### Contexto
A avaliação pontua observabilidade. Mais do que isso, sem métricas não é
possível **demonstrar** a tese central do trabalho (a fila amortecendo o pico)
no teste de carga (Fase 8). Precisávamos de métricas, coleta e visualização.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Biblioteca de métricas | **`prom-client`** | Padrão de fato para expor métricas Prometheus em Node; baixo overhead. |
| Coleta | **Prometheus** | Pull/scrape simples, casa com `prom-client`; consultas PromQL para o artigo. |
| Visualização | **Grafana** com datasource + dashboard **provisionados** | Sobe pronto (sem cliques na demo); o JSON do dashboard fica versionado no repo. |
| Exposição no worker | **Servidor HTTP mínimo em `/metrics`** (porta 9100) | O worker não é um servidor web; subimos um `http.createServer` só para o scrape. |
| Métricas de domínio | `queue_depth`, `queue_enqueued_total`, `worker_messages_processed_total`, `reservations_total{result}`, `payments_total{result}`, `http_request_duration_seconds` | Contam a história distribuída: fila enchendo/drenando, exclusão mútua (conflitos) e latência. |
| `queue_depth` | **Gauge com `collect()` lendo o Redis** (`seq - processed`) | Reaproveita os contadores já usados para a posição na fila; valor sempre fresco no scrape. |
| Acesso ao Grafana | **Login anônimo como Admin** | Conveniência para a apresentação (ambiente local/efêmero, sem dado sensível). |

### Validação (docker-compose)
- `GET /metrics` na API e no worker retornam métricas; após uma compra completa,
  `reservations_total{result="success"}=1`, `payments_total{result="paid"}=1`,
  `queue_enqueued_total=1`.
- Prometheus com 3 alvos `up` (api, worker, prometheus).
- Grafana saudável, datasource `prometheus` e dashboard "Ingressos Distribuídos —
  Visão Geral" provisionados automaticamente.

### Consequências
- A base de observabilidade está pronta para o **teste de carga (Fase 8)**:
  basta gerar o pico e observar `queue_depth` subir e ser drenado no ritmo do
  `WORKER_RATE_MS`.
- Em produção (Fase 6), o mesmo `prom-client` continua valendo; pode-se publicar
  no Prometheus do cluster (k3s) e/ou no CloudWatch.

---

## ADR-008 — Decisões da Fase 8 (Teste de carga)

**Data:** 2026-06-17
**Status:** Aceito (executado no docker-compose)

### Contexto
A tese central do trabalho é que a **fila virtual absorve picos** sem derrubar o
sistema. Era preciso provar isso empiricamente, gerando um pico realista e
medindo o comportamento.

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Ferramenta | **k6** (via Docker) | Scriptável em JS, roda sem instalar nada (imagem `grafana/k6`), integra com o tema e com o Grafana. |
| Perfil de carga | **`ramping-arrival-rate`** (chega a N req/s) | Modela "abertura de vendas": taxa de chegada controlada, independente da latência do servidor (é assim que um pico real se comporta). |
| Alvo | **`POST .../purchase`** (a fila) | É o caminho que deve absorver o pico; mede o desacoplamento, não o banco. |
| Rede | **rede do compose** (`--network fabiano_default`) | k6 fala direto com o `api`, sem depender de portas publicadas. |

### Resultado medido (pico de ~30 req/s por 15s)
- **463 compras enfileiradas, 100% com HTTP 202, 0 falhas**; latência p95 = ~17 ms.
- `queue_depth` subiu até **418** e passou a ser **drenada a ~2/s** (= `WORKER_RATE_MS=500`).
- Worker: `reserved` + `failed` (assentos esgotam → conflitos), confirmando a
  **exclusão mútua** (por assento, só a primeira compra vence).

### Interpretação (para o artigo)
O sistema trocou **indisponibilidade por latência de processamento**: sob pico,
ninguém recebe erro — todos entram na fila e são atendidos num ritmo sustentável.
Aumentar a vazão é só aumentar réplicas do worker ou reduzir `WORKER_RATE_MS`.

### Consequências
- Gráfico de `queue_depth` (Grafana) é a evidência visual para a apresentação.
- Parametrizável (`PEAK`, `RAMP`, `HOLD`) para gerar diferentes cenários no artigo.

---

## ADR-009 — E-mail real na AWS (mensageria da Fase 6 via Terraform)

**Data:** 2026-06-21
**Status:** Aceito

### Contexto
Na nuvem (Learner Lab) o e-mail de confirmação **nunca era enviado**. Causa: o
Terraform só provisionava o cluster k3s; a aplicação dentro do cluster continuava
falando com um **LocalStack interno** (`AWS_ENDPOINT_URL` apontando para o Service
`localstack`). E o LocalStack **não executa Lambda** nesse modo (precisa do socket
do Docker, indisponível no pod). Resultado: o pagamento publicava num SNS emulado
sem consumidor — sem Lambda, sem e-mail. Isso furava um requisito obrigatório da
avaliação (Lambda + SNS + e-mail funcionando na nuvem).

### Decisões

| Decisão | Escolha | Justificativa |
|---|---|---|
| Provisionar mensageria real | **SQS + SNS + Lambda via Terraform** (`messaging.tf`) | Recursos AWS de verdade, descartáveis com `terraform destroy`. |
| Role da Lambda | **`LabRole` referenciada** (`data aws_iam_role`) | Learner Lab não deixa criar IAM; usamos a role pré-existente. |
| Caminho do e-mail | **SNS → Lambda → SNS-email** | A Lambda assina `order-confirmed`, formata e publica em `order-emails`, que tem assinatura de e-mail. Mantém a Lambda no fluxo (requisito) e **evita o sandbox do SES** (que exigiria verificar cada destinatário). |
| Destinatário | **endereço fixo** (`var.notify_email`) | Assinaturas de e-mail do SNS são estáticas; para a demo, um endereço fixo recebe todas as confirmações (com os dados do pedido no corpo). |
| Credenciais da app no cluster | **LabRole via IMDS** | Os pods api/worker (no master) pegam as credenciais do instance profile pelo IMDS. Exigiu `metadata_options { http_put_response_hop_limit = 2 }` — o default (1) bloqueia containers (o pacote atravessa o netns do pod = +1 salto). |
| Apontar a app para a AWS real | **remover `AWS_ENDPOINT_URL` do ConfigMap** | Sem a var, o SDK usa a AWS real. Feito por `kubectl patch` no user-data do master (overlay kustomize daria ciclo: a base é ancestral do overlay). Default do código também passou a ser vazio (api/worker). |
| Empacotar a Lambda | **`archive_file` do `dist/`** | O AWS SDK v3 já vem no runtime `nodejs20.x`; o zip leva só o handler compilado. Rodar `npm run build --workspace services/lambda-email` antes do apply. |

### Consequência operacional (não esquecer na demo)
Após o `apply`, a AWS envia um e-mail de **confirmação de inscrição** para
`notify_email`. É preciso **clicar no link uma vez**; sem isso a Lambda publica
mas nada chega à caixa. O output `email_subscription_reminder` lembra disso.

### Dev local não muda
O handler ramifica por `NOTIFY_TOPIC_ARN`: com a var (AWS) publica no SNS; sem ela
(docker-compose/LocalStack) continua enviando via **SES**, visível no SES viewer.
