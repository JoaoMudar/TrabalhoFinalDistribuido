# 📍 STATUS DO PROJETO — onde paramos / o que falta

> **Para que serve este arquivo:** ponto de retomada entre sessões. Leia isto
> primeiro ao recomeçar. Resumo do que já roda, como subir, e o que falta fazer.
> Mantenha atualizado ao fim de cada fase (é barato e evita reconstruir contexto).
>
> **Última atualização:** 2026-06-17 — Fases 1–4, **7 (observabilidade) e 8
> (teste de carga) feitas**; Fase 5 (K8s) com código pronto (falta cluster vivo).
> Ambiente de nuvem definido: **AWS Academy Learner Lab + k3s/EC2** (ver ADR-005).

---

## ✅ O que já está PRONTO e VALIDADO (Fases 0–4)

A aplicação distribuída roda **inteira de ponta a ponta** em Docker (local).

| Fase | Entrega | Estado | Onde está |
|------|---------|:------:|-----------|
| 0 | Scaffolding (monorepo, docker-compose, esqueletos) | ✅ | raiz, `apps/*`, `services/*` |
| 1 | Backend core: modelos Mongo, endpoints REST, lock Redis com TTL | ✅ | `apps/api/` |
| 2 | Mensageria: fila SQS + worker (backpressure) + publish SNS | ✅ | `apps/worker/`, `apps/api/src/services/queue.ts` |
| 3 | Lambda de e-mail assinando o SNS (SNS→Lambda→SES) | ✅ | `services/lambda-email/`, `scripts/deploy-lambda.*` |
| 4 | Frontend React (eventos→assentos→fila→checkout→confirmação) | ✅ | `apps/web/` |

**Cada decisão dessas fases está documentada** em `docs/decisoes.md` (ADR-000 a ADR-004) — isso vira a metodologia do artigo.

### Provas de que funciona (já validadas em sessão anterior)
- **Fase 1:** reserva → `201`; reserva concorrente do mesmo assento → `409`; pagamento dentro do TTL → assento `sold` (idempotente); pagamento após expiração → `410`.
- **Fase 2:** `purchase` → `202`; polling evolui `queued`→`reserved`; concorrência na fila: um `reserved`, outro `failed` (exclusão mútua preservada).
- **Fase 3:** pagamento → e-mail aparece em `http://localhost:4566/_aws/ses`; log da Lambda confirma envio.
- **Fase 4:** fluxo completo pelo frontend (via proxy `/api` do Vite): `purchase → reserved → pay → sold`.

---

## 🚀 Como subir tudo do zero (checklist de retomada)

```bash
# 1. (uma vez) dependências dos workspaces
npm install

# 2. subir a stack (LocalStack + Redis + Mongo + API + worker + web)
docker compose up --build -d

# 3. implantar a Lambda de e-mail no LocalStack (assina o SNS)
#    Windows (PowerShell):
./scripts/deploy-lambda.ps1
#    Linux/macOS:
./scripts/deploy-lambda.sh
```

Acessos: **web** http://localhost:5173 · **API** http://localhost:8080/health ·
**LocalStack** http://localhost:4566 · **e-mails (SES)** http://localhost:4566/_aws/ses

Derrubar: `docker compose down`.

### ⚠️ Lições aprendidas / armadilhas (não tropeçar de novo)
- **PowerShell 5.1**: scripts `.ps1` devem ser **ASCII puro** (sem acento/emoji/✔) — senão dá erro de parser. POST com JSON: usar `curl.exe -H "Content-Type: application/json"` (o `Invoke-RestMethod` manda content-type errado → 415).
- **Endpoint `/pay`**: exige corpo; o frontend manda `body:"{}"`. Por curl, mandar sem content-type ou com `-d '{}'`.
- **Recriar o LocalStack derruba o worker** (long-poll cai com `ECONNREFUSED`). Já mitigado: retry no loop do worker + `restart: unless-stopped` no compose. Após recriar a stack, **rode o `deploy-lambda` de novo** (a Lambda não persiste).
- **Rede do Docker registry instável** já bloqueou rebuild (`node:20-alpine`). Contorno: `docker compose up -d --no-build` para recriar a partir da imagem existente.
- **PowerShell + arrays**: `Invoke-RestMethod ... | Where-Object {...}` trata o array como item único. Atribua a uma variável primeiro, depois filtre.

---

## ⬜ O que FALTA (Fases 5–9)

As próximas fases **mudam de natureza** (não são mais "código que roda local com Docker compose"):

### Fase 5 — Containerização + manifests K8s (kind/minikube) 🚧 CÓDIGO PRONTO
- **Feito:** `infra/k8s/` completo (namespaces, configmap, mongo+PVC, redis, localstack, api, worker, web, ingress, kustomization) + `infra/docker/web.prod.Dockerfile` (Nginx) + `infra/docker/nginx.conf` + entrypoint + scripts `scripts/k8s-local.{ps1,sh}` + `infra/k8s/README.md`. Detalhes/decisões: **ADR-006**.
- **Validado offline:** `kubectl kustomize infra/k8s` → 17 objetos OK; imagem `ingressos/web` builda, `nginx -t` passa, `GET /` → 200.
- **FALTA (próximo passo real):** rodar num **cluster vivo**. Na máquina há `docker`+`kubectl`, mas **NÃO há kind/minikube** e o k8s do Docker Desktop está desligado. Opções: ligar Kubernetes no Docker Desktop (Settings → Kubernetes → Enable) **ou** instalar kind, depois rodar `./scripts/k8s-local.ps1`.
- **Custo:** zero (local).
- **Limitação documentada:** Lambda de e-mail não executa no cluster (LocalStack precisa do socket do Docker); SNS ainda recebe o publish. Fluxo Lambda completo fica no compose (Fase 3) e na AWS real (Fase 6).

### Fase 6 — AWS/Terraform no **AWS Academy Learner Lab** (k3s/EC2) ⚠️ CRÉDITOS LIMITADOS
- **Ambiente DEFINIDO:** AWS Academy **Learner Lab** (não é conta AWS comum). Para mostrar ao professor.
- **Cluster:** **k3s instalado sobre EC2** (não EKS — EKS costuma ser bloqueado/caro no Learner Lab).
- **O quê:** `infra/terraform/` provisionando EC2 (+ k3s), SQS, SNS, Lambda; deploy real.
- **🔒 Restrições do Learner Lab (obrigatório respeitar):**
  - **Não criar IAM** — usar só a role pré-existente `LabRole` (referenciar, nunca declarar `aws_iam_role`/`aws_iam_policy`).
  - **Credenciais temporárias** (com `aws_session_token`) que expiram em ~3–4h → copiar do painel "AWS Details" a cada sessão; nunca commitar.
  - **Região** geralmente `us-east-1`. **ECR** pode faltar → usar Docker Hub ou `docker save/load`.
  - Orçamento ~US$50–100: provisionar → demonstrar → **`terraform destroy` imediatamente**.
- **Pré-requisito:** acesso ao Learner Lab ativo. **NÃO iniciar sem aval explícito do usuário** (consome créditos).

### Fase 7 — Observabilidade ✅ FEITA (validada no compose)
- **Feito:** `/metrics` na API e no worker (`prom-client`); métricas de domínio (`queue_depth`, `queue_enqueued_total`, `worker_messages_processed_total`, `reservations_total`, `payments_total`, `http_request_duration_seconds`); Prometheus + Grafana no `docker-compose` com datasource e dashboard **provisionados** (`infra/observability/`). Decisões: **ADR-007**.
- **Acessos:** Prometheus http://localhost:9090 · Grafana http://localhost:3000 (login anônimo Admin, dashboard "Ingressos").
- **Validado:** 3 alvos `up` no Prometheus; métricas de domínio populando após uma compra; Grafana com datasource+dashboard OK.
- **Pendente (opcional):** manifests de Prometheus/Grafana para o K8s (hoje só no compose) — fácil de portar se a Fase 5 for ao cluster.

### Fase 8 — Teste de carga (k6) ✅ FEITA
- **Feito:** `tests/load/purchase-burst.js` (k6, perfil `ramping-arrival-rate`) + `scripts/loadtest.{ps1,sh}` (roda k6 via Docker na rede do compose). Decisões: **ADR-008**.
- **Resultado medido:** pico ~30 req/s → 463 compras, 100% HTTP 202, 0 erros, p95 ≈ 17 ms; `queue_depth` chegou a **418** e drenou a ~2/s. Prova o backpressure + exclusão mútua.
- **Como repetir:** `./scripts/loadtest.ps1 -Peak 100 -Hold 30s` e ver no Grafana.
- **Custo:** zero (local).

### Fase 9 — Artigo + diagramas + apresentação
- **O quê:** escrever `docs/artigo/` a partir dos ADRs; diagramas mermaid em `docs/diagramas/`; slides.
- **Sem dependências externas.** Pode ser feito a qualquer momento.

---

## 🧭 Recomendação de ordem para retomar

1. **Fase 5 (K8s local)** — se o usuário tiver kind/minikube. Senão, pular.
2. **Fase 7 (Observabilidade)** e **Fase 8 (Carga)** — ambas locais, sem custo, e geram material forte para o artigo/apresentação.
3. **Fase 9 (Artigo)** — escrever em paralelo, já há muito ADR pronto.
4. **Fase 6 (AWS real)** — **por último e só com aval**, por causa do custo. Provisionar, demonstrar/coletar evidências, e `terraform destroy` logo em seguida.

> **Decisão em aberto (perguntar ao usuário ao retomar):** por qual fase seguir, e
> se tem kind/minikube instalado (Fase 5) e se/quando vai querer pagar pela AWS (Fase 6).
