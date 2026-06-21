/**
 * Rotas da fila virtual (Fase 2).
 *
 *   POST /events/:id/seats/:seatId/purchase  -> entra na fila, devolve ticket
 *   GET  /queue/:ticketId                     -> posição/estado do ticket (polling)
 */

import type { FastifyInstance } from "fastify";
import { enqueuePurchase, getTicket } from "../services/queue.js";
import { enqueued } from "../metrics.js";

export async function queueRoutes(app: FastifyInstance): Promise<void> {
  app.post<{
    Params: { id: string; seatId: string };
    Body: { userEmail?: string };
  }>("/events/:id/seats/:seatId/purchase", async (req, reply) => {
    const { id, seatId } = req.params;
    const userEmail = req.body?.userEmail;
    if (!userEmail) return reply.code(400).send({ error: "userEmail é obrigatório" });

    const { ticketId, position } = await enqueuePurchase(id, seatId, userEmail);
    enqueued.inc();
    // 202 Accepted: a compra foi aceita na fila, ainda não processada.
    return reply.code(202).send({ ticketId, position, status: "queued" });
  });

  app.get<{ Params: { ticketId: string } }>("/queue/:ticketId", async (req, reply) => {
    const ticket = await getTicket(req.params.ticketId);
    if (!ticket) return reply.code(404).send({ error: "ticket não encontrado ou expirado" });
    return ticket;
  });
}
