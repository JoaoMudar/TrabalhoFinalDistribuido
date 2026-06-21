/**
 * Ponto de entrada da API REST.
 *
 * Fase 1 — backend core: conecta MongoDB e Redis, registra as rotas do fluxo
 * de compra (eventos, assentos, reserva, pagamento) e popula dados de exemplo.
 * O /health continua servindo como liveness/readiness probe no K8s (Fase 5).
 */

import Fastify from "fastify";
import cors from "@fastify/cors";
import { config } from "./config.js";
import { connectMongo, disconnectMongo } from "./db/mongo.js";
import { redis } from "./db/redis.js";
import { eventRoutes } from "./routes/events.js";
import { orderRoutes } from "./routes/orders.js";
import { queueRoutes } from "./routes/queue.js";
import { metricsPlugin } from "./metrics.js";
import { seedIfEmpty } from "./seed.js";

const app = Fastify({
  logger: {
    level: config.logLevel,
  },
});

/** Health check — smoke test local e probe no Kubernetes. */
app.get("/health", async () => {
  return {
    status: "ok",
    service: "api",
    phase: "fase-7",
    timestamp: new Date().toISOString(),
  };
});

/** Sobe a API: dependências primeiro, depois as rotas, por fim o listen. */
async function start(): Promise<void> {
  try {
    await connectMongo();
    app.log.info({ mongoUrl: config.mongoUrl }, "MongoDB conectado");

    await redis.ping();
    app.log.info({ redisUrl: config.redisUrl }, "Redis conectado");

    await app.register(cors, { origin: true });
    await app.register(metricsPlugin); // /metrics + cronômetro de requisições
    await app.register(eventRoutes);
    await app.register(orderRoutes);
    await app.register(queueRoutes);

    await seedIfEmpty(app.log);

    await app.listen({ port: config.port, host: config.host });
    app.log.info("API no ar (Fase 1 — fluxo de compra com lock no Redis)");
  } catch (err) {
    app.log.error(err);
    process.exit(1);
  }
}

// Encerramento gracioso (importante em ambiente containerizado).
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, async () => {
    app.log.info(`Recebido ${signal}, encerrando...`);
    await app.close();
    await disconnectMongo();
    redis.disconnect();
    process.exit(0);
  });
}

void start();
