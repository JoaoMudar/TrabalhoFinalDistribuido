# Diagramas de Arquitetura

Diagramas em Mermaid (reaproveitáveis no artigo). Refletem o que foi de fato
implementado (ver `docs/decisoes.md`, ADR-000 a 008).

## Fluxo principal — caminho feliz da compra

```mermaid
sequenceDiagram
    autonumber
    actor U as Usuário
    participant W as Frontend (React)
    participant A as API (Fastify)
    participant Q as Fila SQS<br/>(ticket-purchase-queue)
    participant K as Worker
    participant R as Redis<br/>(lock + TTL + fila)
    participant M as MongoDB
    participant S as SNS<br/>(order-confirmed)
    participant L as Lambda (e-mail)

    U->>W: Escolhe evento e assento
    W->>A: POST .../purchase (intenção)
    A->>R: Grava ticket + INCR queue:seq
    A->>Q: Envia mensagem
    A-->>W: 202 { ticketId, position }
    loop Polling (GET /queue/:id)
        W->>A: Consulta estado/posição
        A->>R: Lê ticket + contadores
    end
    K->>Q: Consome mensagem (long poll)
    Note over K,A: O worker NÃO fala com o Mongo:<br/>delega a reserva à API (fonte única de verdade)
    K->>A: POST .../reserve
    A->>R: SET lock:seat NX EX 300
    alt Lock obtido
        A->>M: Cria pedido (pending)
        A-->>K: 201 (orderId, expiresAt)
        K->>R: Atualiza ticket = reserved
        U->>W: "Paga" (mock) dentro do TTL
        W->>A: POST .../pay
        A->>R: Confere lock + libera (Lua)
        A->>M: Pedido = paid, assento = sold
        A->>S: Publica "pedido confirmado"
        S->>L: Invoca Lambda
        L-->>U: E-mail de confirmação (SES)
    else Lock falhou (assento tomado)
        A-->>K: 409
        K->>R: Atualiza ticket = failed
    end
    note over R: Se o TTL expira sem pagamento,<br/>o lock cai e o assento volta a ficar livre
```

## Visão de componentes (alto nível)

```mermaid
flowchart LR
    subgraph Cliente
        WEB[Frontend React]
    end
    subgraph Cluster["Kubernetes (kind/minikube local · k3s/EC2 na AWS)"]
        API[API REST]
        WORKER[Worker]
    end
    subgraph Mensageria
        SQS[(SQS)]
        SNS[(SNS)]
    end
    subgraph Dados
        REDIS[(Redis<br/>locks + fila)]
        MONGO[(MongoDB<br/>dados)]
    end
    LAMBDA[Lambda e-mail]

    WEB -->|REST /api| API
    API -->|enfileira| SQS
    API --> REDIS
    API --> MONGO
    SQS -->|long poll| WORKER
    WORKER -->|POST /reserve| API
    WORKER --> REDIS
    API -->|publica| SNS
    SNS --> LAMBDA
```

## Topologia no Kubernetes (Fase 5)

Isolamento por namespaces; entrada única pelo Ingress.

```mermaid
flowchart TB
  ing[Ingress] --> web
  subgraph ns_app["namespace: ingressos (aplicação, sem estado)"]
    web[web - Nginx + SPA]
    api[api - Fastify x2]
    worker[worker]
    web -->|/api| api
    worker -->|reserve| api
  end
  subgraph ns_data["namespace: ingressos-data (estado)"]
    mongo[(MongoDB + PVC)]
    redis[(Redis)]
    ls[LocalStack - SQS/SNS/SES]
  end
  api --> mongo
  api --> redis
  api -->|SQS/SNS| ls
  worker -->|poll SQS| ls
```

## Observabilidade (Fase 7)

```mermaid
flowchart LR
  api[API /metrics] --> prom[Prometheus]
  worker[Worker /metrics] --> prom
  prom --> graf[Grafana<br/>dashboard 'Ingressos']
  subgraph Métricas de domínio
    direction TB
    d1[queue_depth]
    d2[enqueued vs processed]
    d3[reservations/payments por resultado]
    d4[latência HTTP]
  end
  api -.expõe.-> d1
```

## Implantação na AWS Academy (Fase 6 — planejada)

```mermaid
flowchart TB
  subgraph LL["AWS Academy Learner Lab (us-east-1)"]
    subgraph EC2["EC2 + k3s (cluster Kubernetes)"]
      pods[web · api · worker]
    end
    sqs[(SQS real)]
    sns[(SNS real)]
    lambda[Lambda real]
    ses[SES]
  end
  pods -->|usa LabRole| sqs
  pods --> sns
  sns --> lambda
  lambda --> ses
  note["IAM travado: só a LabRole<br/>credenciais temporárias<br/>destruir após a demo"]
```
