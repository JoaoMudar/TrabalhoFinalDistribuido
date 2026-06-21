/**
 * Seed de dados de demonstração (Fase 1).
 *
 * Roda no boot da API: se ainda não houver eventos, cria um evento de exemplo
 * com um mapa de assentos. Assim o frontend e os testes via curl já têm dados
 * para trabalhar, sem passo manual.
 */

import type { FastifyBaseLogger } from "fastify";
import { EventModel } from "./models/event.js";
import { SeatModel } from "./models/seat.js";

export async function seedIfEmpty(log: FastifyBaseLogger): Promise<void> {
  const existing = await EventModel.estimatedDocumentCount();
  if (existing > 0) {
    log.info("seed ignorado — já existem eventos no banco");
    return;
  }

  const event = await EventModel.create({
    name: "Show da Banda Distribuída",
    date: new Date("2026-09-20T21:00:00Z"),
    venue: "Arena Cloud",
    description: "Turnê de lançamento — ingressos com assento marcado.",
  });

  // Mapa simples: 4 fileiras (A–D) com 10 assentos cada.
  const seats = [];
  for (const row of ["A", "B", "C", "D"]) {
    for (let n = 1; n <= 10; n++) {
      seats.push({
        eventId: event._id,
        code: `${row}${n}`,
        section: "Pista Premium",
        price: 250,
      });
    }
  }
  await SeatModel.insertMany(seats);

  log.info({ eventId: String(event._id), seats: seats.length }, "seed inicial criado");
}
