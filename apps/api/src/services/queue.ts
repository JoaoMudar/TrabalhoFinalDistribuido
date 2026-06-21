/**
 * Fila virtual de compra (Fase 2).
 *
 * No pico, em vez de bater direto no banco, a intenção de compra entra numa
 * fila SQS e o usuário recebe um TICKET com sua posição. O worker consome a
 * fila num ritmo controlado (backpressure) e processa a reserva. O estado do
 * ticket vive no Redis (compartilhado entre API e worker).
 *
 * Chaves no Redis:
 *   queue:seq        contador de tickets enfileirados (ordem de chegada)
 *   queue:processed  contador de tickets já consumidos pelo worker
 *   ticket:{id}      estado do ticket (JSON)
 */

import { randomUUID } from "node:crypto";
import { SendMessageCommand } from "@aws-sdk/client-sqs";
import { redis } from "../db/redis.js";
import { sqs, getQueueUrl } from "../aws.js";

/** Tickets expiram do Redis após 1h (limpeza automática). */
const TICKET_TTL_SECONDS = 60 * 60;

export type TicketStatus = "queued" | "processing" | "reserved" | "failed";

export interface TicketState {
  status: TicketStatus;
  seq: number;
  eventId: string;
  seatId: string;
  userEmail: string;
  orderId?: string;
  expiresAt?: string;
  error?: string;
  createdAt: string;
}

function ticketKey(ticketId: string): string {
  return `ticket:${ticketId}`;
}

/** Quantas pessoas ainda estão na frente (aproximação FIFO via contadores). */
async function computePosition(seq: number): Promise<number> {
  const processed = Number(await redis.get("queue:processed")) || 0;
  return Math.max(0, seq - processed - 1);
}

/** Coloca uma intenção de compra na fila. Retorna o ticket e a posição. */
export async function enqueuePurchase(
  eventId: string,
  seatId: string,
  userEmail: string,
): Promise<{ ticketId: string; position: number }> {
  const ticketId = randomUUID();
  const seq = await redis.incr("queue:seq");

  const state: TicketState = {
    status: "queued",
    seq,
    eventId,
    seatId,
    userEmail,
    createdAt: new Date().toISOString(),
  };
  await redis.set(ticketKey(ticketId), JSON.stringify(state), "EX", TICKET_TTL_SECONDS);

  // Mensagem para o worker consumir.
  const queueUrl = await getQueueUrl();
  await sqs.send(
    new SendMessageCommand({
      QueueUrl: queueUrl,
      MessageBody: JSON.stringify({ ticketId, eventId, seatId, userEmail }),
    }),
  );

  return { ticketId, position: await computePosition(seq) };
}

/** Estado atual de um ticket (com posição recalculada se ainda na fila). */
export async function getTicket(
  ticketId: string,
): Promise<(TicketState & { position: number }) | null> {
  const raw = await redis.get(ticketKey(ticketId));
  if (!raw) return null;
  const state = JSON.parse(raw) as TicketState;
  const position = state.status === "queued" ? await computePosition(state.seq) : 0;
  return { ...state, position };
}
