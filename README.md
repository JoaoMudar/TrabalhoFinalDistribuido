# 🎟️ Plataforma de Venda de Ingressos

Trabalho semestral de **Sistemas Distribuídos** — aplicação completa rodando em
um sistema distribuído na AWS.

## Problemática
Venda de ingressos para eventos populares, onde há **picos súbitos de acesso**
(ex.: abertura de vendas de um show). O desafio distribuído é: não vender o mesmo
assento duas vezes, suportar a carga e dar feedback ao usuário sem derrubar o sistema.

## Solução (resumo)
1. **Fila virtual (SQS):** no pico, as compras entram numa fila; o usuário recebe
   uma posição em vez de bater direto no banco. Workers consomem em ritmo controlado.
2. **Reserva temporária (Redis + TTL):** ao chegar a vez, o assento é travado no
   Redis com TTL (~5 min). Sem pagamento, o lock expira e o assento volta a ficar livre.
3. **Confirmação assíncrona (SNS + Lambda):** pagamento confirmado publica no SNS;
   uma Lambda dispara o e-mail de confirmação, desacoplado do fluxo de compra.
4. **Persistência (MongoDB):** eventos, assentos, pedidos e usuários.

Diagramas em [`docs/diagramas/arquitetura.md`](docs/diagramas/arquitetura.md).

## Mapeamento requisito → componente

| Requisito da avaliação      | Como atendemos                                  |
|-----------------------------|-------------------------------------------------|
| Cluster Kubernetes          | k3s sobre EC2 (AWS Academy) rodando API + workers + frontend |
| Lambda                      | Envio de e-mail de confirmação                  |
| SQS                         | Fila virtual de compra                          |
| SNS                         | Evento "pedido confirmado" → Lambda             |
| Banco distribuído           | Redis (locks/TTL) + MongoDB (dados)             |
| Front + back                | SPA React + API REST                            |
| Observabilidade             | CloudWatch + Prometheus/Grafana                 |
| Isolamento de componentes   | Namespaces no K8s + filas desacoplando serviços |

## Stack
Node.js + TypeScript · Fastify (API) · React + Vite (web) · MongoDB · Redis ·
AWS SQS/SNS/Lambda · Kubernetes (EKS) · Terraform · LocalStack (dev) · pino.

## Estrutura do monorepo
```
apps/
  api/            backend REST (Fastify)
  worker/         consumidor da fila SQS
  web/            frontend React (Vite)
services/
  lambda-email/   Lambda de confirmação por e-mail
infra/
  terraform/      IaC AWS (Fase 6)
  k8s/            manifests Kubernetes (Fase 5)
  docker/         Dockerfiles
docs/
  artigo/         rascunho do artigo
  diagramas/      diagramas mermaid
  decisoes.md     ADRs (metodologia do artigo)
scripts/          utilitários (init do LocalStack)
docker-compose.yml
```

## Pré-requisitos
- [Docker](https://www.docker.com/) + Docker Compose
- [Node.js](https://nodejs.org/) 20+ (apenas para rodar/desenvolver fora dos containers)

## Como rodar (dev local)
```bash
# 1. Instalar dependências dos workspaces
npm install

# 2. Subir toda a stack (LocalStack + Redis + Mongo + API + worker + web)
docker-compose up --build

# 3. Deploy da Lambda de e-mail no LocalStack (assina o SNS)
#    Windows:
./scripts/deploy-lambda.ps1
#    Linux/macOS:
./scripts/deploy-lambda.sh
```

> A Lambda é implantada por script separado porque é compilada/empacotada
> **depois** que o LocalStack já subiu (o init do LocalStack roda no boot).

Verificar o e-mail de confirmação (após um pagamento), via SES do LocalStack:
```bash
curl http://localhost:4566/_aws/ses   # lista os e-mails "enviados"
```

Serviços disponíveis:

| Serviço          | URL / Porta                     |
|------------------|---------------------------------|
| Frontend (web)   | http://localhost:5173           |
| API              | http://localhost:8080/health    |
| API /metrics     | http://localhost:8080/metrics   |
| LocalStack (AWS) | http://localhost:4566           |
| Prometheus       | http://localhost:9090           |
| Grafana          | http://localhost:3000 (dashboard "Ingressos") |
| Redis            | localhost:6379                  |
| MongoDB          | localhost:27017                 |

Smoke test rápido:
```bash
curl http://localhost:8080/health
# {"status":"ok","service":"api","phase":"fase-0", ...}
```

Para derrubar tudo: `docker-compose down`.

## API REST (Fase 1)

| Método | Rota | Descrição |
|---|---|---|
| GET | `/health` | Liveness/readiness (probe do K8s) |
| GET | `/events` | Lista eventos |
| GET | `/events/:id` | Detalhe do evento |
| GET | `/events/:id/seats` | Assentos com disponibilidade (`available`/`reserved`/`sold`) |
| POST | `/events/:id/seats/:seatId/reserve` | Reserva temporária (lock Redis + TTL); body `{ "userEmail": "..." }` |
| POST | `/orders/:orderId/pay` | Mock de pagamento → confirma se o lock ainda vale + publica no SNS |
| GET | `/orders/:orderId` | Status do pedido |
| POST | `/events/:id/seats/:seatId/purchase` | **Fila virtual**: enfileira na SQS, devolve `ticketId` + posição |
| GET | `/queue/:ticketId` | Posição/estado do ticket na fila (polling) |

Exemplo de fluxo:
```bash
EID=$(curl -s localhost:8080/events | jq -r '.[0]._id')
SID=$(curl -s localhost:8080/events/$EID/seats | jq -r '.[0]._id')
ORDER=$(curl -s -X POST localhost:8080/events/$EID/seats/$SID/reserve \
  -H 'Content-Type: application/json' -d '{"userEmail":"a@a.com"}' | jq -r .orderId)
curl -s -X POST localhost:8080/orders/$ORDER/pay
```

## Observabilidade (Fase 7)

Logs estruturados (pino) + métricas Prometheus + dashboards Grafana.

- **API** e **worker** expõem `/metrics` (formato Prometheus). Além das métricas
  padrão do Node, há métricas de domínio:
  - `queue_depth` — itens aguardando na fila virtual (prova do backpressure);
  - `queue_enqueued_total` vs `worker_messages_processed_total` — entrada × saída;
  - `reservations_total{result}` e `payments_total{result}`;
  - `http_request_duration_seconds` — latência por rota.
- **Prometheus** (`:9090`) faz scrape de api e worker a cada 5s.
- **Grafana** (`:3000`, login anônimo como Admin) já sobe com o datasource e o
  dashboard **"Ingressos Distribuídos — Visão Geral"** provisionados.

Tudo definido em `infra/observability/` e adicionado ao `docker-compose.yml`.
Esses gráficos são o insumo da seção de resultados do artigo (e do teste de
carga, Fase 8).

## Teste de carga (Fase 8)

Simula o **pico de abertura de vendas** com [k6](https://k6.io/) (via Docker,
sem instalar nada) batendo na fila virtual.

```powershell
# Windows
./scripts/loadtest.ps1                 # pico padrão (50 req/s)
./scripts/loadtest.ps1 -Peak 100 -Hold 30s
```
```bash
# Linux/macOS
./scripts/loadtest.sh                   # PEAK=100 HOLD=30s ./scripts/loadtest.sh
```

Acompanhe ao vivo no **Grafana** (http://localhost:3000): a `queue_depth` sobe
durante o pico e é drenada no ritmo do worker.

**Resultado de referência** (pico ~30 req/s por 15s): 463 compras enfileiradas,
100% HTTP 202, **0 erros**, p95 ≈ 17 ms; `queue_depth` chegou a 418 e foi drenada
a ~2/s. O sistema troca indisponibilidade por latência de processamento — a fila
absorve o pico. Script em [`tests/load/purchase-burst.js`](tests/load/purchase-burst.js).

## Roadmap

> 📍 **Onde paramos / o que falta:** ver [`docs/STATUS.md`](docs/STATUS.md) — ponto
> de retomada entre sessões (estado atual, como subir, próximos passos e armadilhas).

| Fase | Descrição | Status |
|------|-----------|:------:|
| 0 | Scaffolding (estrutura, docker-compose, esqueletos, README) | ✅ |
| 1 | Backend core (modelos Mongo, endpoints, lock Redis com TTL) | ✅ |
| 2 | Mensageria (SQS + worker + SNS no LocalStack) | ✅ |
| 3 | Lambda de e-mail assinando o SNS | ✅ |
| 4 | Frontend (evento, assentos, fila, confirmação) | ✅ |
| 5 | Containerização + manifests K8s (kind/minikube) | 🚧 código pronto; falta rodar em cluster |
| 6 | AWS/Terraform no **AWS Academy Learner Lab** (k3s/EC2, SQS, SNS, Lambda reais) | ⬜ |
| 7 | Observabilidade (logs, métricas, Prometheus/Grafana) | ✅ |
| 8 | Teste de carga (k6) | ✅ |
| 9 | Artigo + diagramas + apresentação | ⬜ |
