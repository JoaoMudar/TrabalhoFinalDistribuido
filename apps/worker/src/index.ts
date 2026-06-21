/**
 * Worker consumidor da fila virtual (Fase 2).
 *
 * Responsabilidade única: consumir a fila SQS num RITMO CONTROLADO (backpressure)
 * e disparar a reserva do assento. Para manter a API como única fonte de verdade
 * do domínio, o worker NÃO fala com o Mongo: ele chama o endpoint de reserva da
 * API (que faz o lock no Redis + grava o pedido). O resultado é escrito no
 * estado do ticket no Redis (compartilhado com a API) para o usuário acompanhar.
 *
 * Fluxo por mensagem:
 *   1. recebe { ticketId, eventId, seatId, userEmail }
 *   2. marca o ticket como "processing"
 *   3. POST /events/:id/seats/:seatId/reserve na API
 *      - 201 -> ticket "reserved" (orderId, expiresAt)
 *      - 409 -> ticket "failed" (assento já reservado/vendido)
 *   4. incrementa o contador de processados (move a fila)
 *   5. apaga a mensagem da SQS
 *   6. aguarda WORKER_RATE_MS antes da próxima (suaviza o pico)
 */

import http from "node:http";
import pino from "pino";
import client from "prom-client";
import { Redis } from "ioredis";
import {
  SQSClient,
  GetQueueUrlCommand,
  ReceiveMessageCommand,
  DeleteMessageCommand,
} from "@aws-sdk/client-sqs";

const logger = pino({ level: process.env.LOG_LEVEL ?? "info" });

// ---- Configuração ----
const redisUrl = process.env.REDIS_URL ?? "redis://redis:6379";
const awsEndpointUrl = process.env.AWS_ENDPOINT_URL ?? "http://localstack:4566";
const awsRegion = process.env.AWS_REGION ?? "us-east-1";
const queueName = process.env.QUEUE_NAME ?? "ticket-purchase-queue";
const apiUrl = process.env.API_URL ?? "http://api:8080";
// Ritmo de consumo: 1 compra a cada N ms (demonstra o smoothing de carga).
const rateMs = Number(process.env.WORKER_RATE_MS ?? "500");

const isLocal = Boolean(awsEndpointUrl);
const sqs = new SQSClient({
  region: awsRegion,
  ...(isLocal
    ? { endpoint: awsEndpointUrl, credentials: { accessKeyId: "test", secretAccessKey: "test" } }
    : {}),
});

const redis = new Redis(redisUrl, { maxRetriesPerRequest: null });

// ---- Observabilidade (Fase 7): métricas Prometheus expostas em /metrics ----
const metricsPort = Number(process.env.METRICS_PORT ?? "9100");
const registry = new client.Registry();
registry.setDefaultLabels({ service: "worker" });
client.collectDefaultMetrics({ register: registry });

/** Mensagens processadas por resultado: reserved | failed | error. */
const processedTotal = new client.Counter({
  name: "worker_messages_processed_total",
  help: "Mensagens da fila processadas pelo worker, por resultado",
  labelNames: ["result"],
  registers: [registry],
});

/** Duração do processamento de cada mensagem (inclui a chamada à API). */
const processingDuration = new client.Histogram({
  name: "worker_processing_duration_seconds",
  help: "Duração do processamento de cada mensagem da fila",
  buckets: [0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5],
  registers: [registry],
});

// Profundidade da fila (igual à da API): seq - processed, lido do Redis.
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

// Servidor HTTP mínimo só para expor /metrics ao Prometheus.
http
  .createServer(async (req, res) => {
    if (req.url === "/metrics") {
      res.setHeader("Content-Type", registry.contentType);
      res.end(await registry.metrics());
    } else if (req.url === "/health") {
      res.end("ok");
    } else {
      res.statusCode = 404;
      res.end();
    }
  })
  .listen(metricsPort, () => logger.info({ metricsPort }, "métricas do worker em /metrics"));

let running = true;
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Mescla campos no estado do ticket guardado no Redis (preserva o resto). */
async function updateTicket(ticketId: string, patch: Record<string, unknown>): Promise<void> {
  const key = `ticket:${ticketId}`;
  const raw = await redis.get(key);
  if (!raw) return; // ticket expirou
  const state = { ...JSON.parse(raw), ...patch };
  // Mantém o TTL restante da chave.
  const ttl = await redis.ttl(key);
  if (ttl > 0) await redis.set(key, JSON.stringify(state), "EX", ttl);
  else await redis.set(key, JSON.stringify(state));
}

interface PurchaseMessage {
  ticketId: string;
  eventId: string;
  seatId: string;
  userEmail: string;
}

/** Processa uma mensagem: chama a reserva na API e atualiza o ticket.
 *  Retorna o resultado ("reserved" | "failed") para fins de métrica. */
async function handleMessage(msg: PurchaseMessage): Promise<"reserved" | "failed"> {
  await updateTicket(msg.ticketId, { status: "processing" });

  const res = await fetch(
    `${apiUrl}/events/${msg.eventId}/seats/${msg.seatId}/reserve`,
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ userEmail: msg.userEmail }),
    },
  );
  const body = (await res.json().catch(() => ({}))) as Record<string, unknown>;

  if (res.status === 201) {
    await updateTicket(msg.ticketId, {
      status: "reserved",
      orderId: body.orderId,
      expiresAt: body.expiresAt,
    });
    logger.info({ ticketId: msg.ticketId, orderId: body.orderId }, "assento reservado");
    return "reserved";
  } else {
    await updateTicket(msg.ticketId, {
      status: "failed",
      error: (body.error as string) ?? `reserva falhou (HTTP ${res.status})`,
    });
    logger.warn({ ticketId: msg.ticketId, status: res.status }, "reserva não concluída");
    return "failed";
  }
}

async function main(): Promise<void> {
  const { QueueUrl } = await sqs.send(new GetQueueUrlCommand({ QueueName: queueName }));
  const queueUrl = QueueUrl as string;
  logger.info({ queueUrl, apiUrl, rateMs }, "Worker iniciado (Fase 2 — consumindo a fila SQS)");

  while (running) {
    // Long polling: espera até 20s por mensagens (econômico, sem busy-loop).
    // Erros transitórios (ex.: LocalStack reiniciando) NÃO derrubam o worker:
    // logamos, esperamos e tentamos de novo (resiliência a falhas).
    let out;
    try {
      out = await sqs.send(
        new ReceiveMessageCommand({
          QueueUrl: queueUrl,
          MaxNumberOfMessages: 1,
          WaitTimeSeconds: 20,
        }),
      );
    } catch (err) {
      logger.error(err, "erro ao receber da SQS — nova tentativa em 2s");
      await sleep(2000);
      continue;
    }

    for (const message of out.Messages ?? []) {
      const endTimer = processingDuration.startTimer();
      try {
        const payload = JSON.parse(message.Body ?? "{}") as PurchaseMessage;
        const result = await handleMessage(payload);
        endTimer();
        processedTotal.labels(result).inc();
        // Move a fila (usado para calcular a posição dos que ainda esperam).
        await redis.incr("queue:processed");
        // Sucesso (mesmo 409 é terminal): remove a mensagem.
        await sqs.send(
          new DeleteMessageCommand({ QueueUrl: queueUrl, ReceiptHandle: message.ReceiptHandle }),
        );
      } catch (err) {
        endTimer();
        processedTotal.labels("error").inc();
        // Erro transitório (ex.: API fora do ar): NÃO apaga a mensagem.
        // Ela reaparece após o visibility timeout para nova tentativa.
        logger.error(err, "erro ao processar mensagem — será reentregue");
      }
      // Backpressure: ritmo controlado de consumo.
      await sleep(rateMs);
    }
  }
}

// Encerramento gracioso.
for (const signal of ["SIGINT", "SIGTERM"] as const) {
  process.on(signal, () => {
    logger.info(`Recebido ${signal}, encerrando worker...`);
    running = false;
    redis.disconnect();
    process.exit(0);
  });
}

main().catch((err) => {
  logger.error(err, "worker falhou ao iniciar");
  process.exit(1);
});
