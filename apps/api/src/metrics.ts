/**
 * Métricas Prometheus da API (Fase 7 — observabilidade).
 *
 * Expõe `GET /metrics` no formato Prometheus e instrumenta:
 *  - métricas padrão do processo Node (CPU, memória, event loop, GC);
 *  - duração das requisições HTTP (histograma por rota/método/status);
 *  - contadores de domínio: reservas, pagamentos e entradas na fila virtual;
 *  - profundidade da fila virtual (lida do Redis a cada coleta/scrape).
 *
 * As métricas de domínio são o que prova, no teste de carga (Fase 8), que a
 * fila absorve o pico: dá para ver a fila enchendo e sendo drenada no ritmo
 * do worker.
 */

import client from "prom-client";
import type { FastifyInstance } from "fastify";
import { redis } from "./db/redis.js";

export const registry = new client.Registry();
registry.setDefaultLabels({ service: "api" });
client.collectDefaultMetrics({ register: registry });

/** Histograma de latência das requisições HTTP. */
export const httpDuration = new client.Histogram({
  name: "http_request_duration_seconds",
  help: "Duração das requisições HTTP",
  labelNames: ["method", "route", "status"],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [registry],
});

/** Reservas por resultado: success | conflict | sold | not_found. */
export const reservations = new client.Counter({
  name: "reservations_total",
  help: "Tentativas de reserva de assento por resultado",
  labelNames: ["result"],
  registers: [registry],
});

/** Pagamentos por resultado: paid | expired | conflict. */
export const payments = new client.Counter({
  name: "payments_total",
  help: "Pagamentos por resultado",
  labelNames: ["result"],
  registers: [registry],
});

/** Compras aceitas na fila virtual. */
export const enqueued = new client.Counter({
  name: "queue_enqueued_total",
  help: "Compras colocadas na fila virtual (SQS)",
  registers: [registry],
});

// Profundidade da fila = seq - processed (aproximação FIFO), lida do Redis
// no momento do scrape. É a métrica central para visualizar o backpressure.
new client.Gauge({
  name: "queue_depth",
  help: "Itens aguardando na fila virtual",
  registers: [registry],
  async collect() {
    const [seq, processed] = await Promise.all([
      redis.get("queue:seq"),
      redis.get("queue:processed"),
    ]);
    this.set(Math.max(0, Number(seq ?? 0) - Number(processed ?? 0)));
  },
});

/** Plugin Fastify: cronometra todas as requisições e expõe /metrics. */
export async function metricsPlugin(app: FastifyInstance): Promise<void> {
  app.addHook("onResponse", async (req, reply) => {
    const route = req.routeOptions?.url ?? req.url;
    if (route === "/metrics") return; // não mede a própria coleta
    httpDuration
      .labels(req.method, route, String(reply.statusCode))
      .observe(reply.elapsedTime / 1000); // elapsedTime vem em ms
  });

  app.get("/metrics", async (_req, reply) => {
    reply.header("Content-Type", registry.contentType);
    return registry.metrics();
  });
}
