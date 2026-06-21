/**
 * Rotas de eventos, assentos e reserva (Fase 1).
 *
 * Fluxo de reserva (caminho feliz, ainda SEM a fila SQS — isso entra na Fase 2):
 *   1. valida que o assento existe e não está vendido;
 *   2. tenta adquirir o lock no Redis (exclusão mútua);
 *   3. se conseguiu, cria um pedido `pending` com prazo (TTL) e devolve o orderId.
 */

import type { FastifyInstance } from "fastify";
import { randomUUID } from "node:crypto";
import { EventModel } from "../models/event.js";
import { SeatModel } from "../models/seat.js";
import { OrderModel } from "../models/order.js";
import {
  acquireSeatLock,
  isSeatLocked,
  getSeatLockTTL,
  SEAT_LOCK_TTL_SECONDS,
} from "../services/lock.js";
import { reservations } from "../metrics.js";

export async function eventRoutes(app: FastifyInstance): Promise<void> {
  // Lista de eventos.
  app.get("/events", async () => {
    return EventModel.find().sort({ date: 1 }).lean();
  });

  // Detalhe de um evento.
  app.get<{ Params: { id: string } }>("/events/:id", async (req, reply) => {
    const event = await EventModel.findById(req.params.id).lean();
    if (!event) return reply.code(404).send({ error: "evento não encontrado" });
    return event;
  });

  // Assentos de um evento, com disponibilidade calculada:
  //   sold      -> vendido (status no Mongo)
  //   reserved  -> lock ativo no Redis (reserva temporária de outro usuário)
  //   available -> livre
  app.get<{ Params: { id: string } }>("/events/:id/seats", async (req) => {
    const seats = await SeatModel.find({ eventId: req.params.id }).sort({ code: 1 }).lean();
    return Promise.all(
      seats.map(async (seat) => {
        const locked =
          seat.status === "available" ? await isSeatLocked(String(seat._id)) : false;
        const availability =
          seat.status === "sold" ? "sold" : locked ? "reserved" : "available";
        return { ...seat, availability };
      }),
    );
  });

  // Reserva temporária de um assento.
  app.post<{
    Params: { id: string; seatId: string };
    Body: { userEmail?: string };
  }>("/events/:id/seats/:seatId/reserve", async (req, reply) => {
    const { id, seatId } = req.params;
    const userEmail = req.body?.userEmail;
    if (!userEmail) return reply.code(400).send({ error: "userEmail é obrigatório" });

    const seat = await SeatModel.findOne({ _id: seatId, eventId: id });
    if (!seat) {
      reservations.labels("not_found").inc();
      return reply.code(404).send({ error: "assento não encontrado" });
    }
    if (seat.status === "sold") {
      reservations.labels("sold").inc();
      return reply.code(409).send({ error: "assento já vendido" });
    }

    // Exclusão mútua: só um usuário consegue o lock.
    const token = randomUUID();
    const acquired = await acquireSeatLock(seatId, token);
    if (!acquired) {
      reservations.labels("conflict").inc();
      return reply.code(409).send({ error: "assento reservado por outro usuário" });
    }

    const expiresAt = new Date(Date.now() + SEAT_LOCK_TTL_SECONDS * 1000);
    const order = await OrderModel.create({
      eventId: id,
      seatId,
      userEmail,
      status: "pending",
      expiresAt,
      lockToken: token,
    });

    reservations.labels("success").inc();
    const ttl = await getSeatLockTTL(seatId);
    return reply.code(201).send({
      orderId: String(order._id),
      seatId,
      expiresAt,
      ttlSeconds: ttl,
    });
  });
}
