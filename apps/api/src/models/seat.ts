/**
 * Modelo de Assento (Fase 1).
 *
 * O status no Mongo é só `available` ou `sold` (estados PERMANENTES). O estado
 * intermediário "reservado" é representado pelo LOCK no Redis com TTL — assim,
 * se o usuário não pagar, o lock expira sozinho e o assento volta a ficar
 * disponível, sem precisar de job de limpeza. Essa é a exclusão mútua
 * distribuída que o trabalho precisa demonstrar.
 */

import { Schema, model, InferSchemaType } from "mongoose";

const seatSchema = new Schema(
  {
    eventId: { type: Schema.Types.ObjectId, ref: "Event", required: true, index: true },
    code: { type: String, required: true }, // ex.: "A12"
    section: { type: String, required: true },
    price: { type: Number, required: true },
    status: { type: String, enum: ["available", "sold"], default: "available" },
  },
  { timestamps: true },
);

// Não pode haver dois assentos com o mesmo código no mesmo evento.
seatSchema.index({ eventId: 1, code: 1 }, { unique: true });

export type Seat = InferSchemaType<typeof seatSchema>;
export const SeatModel = model("Seat", seatSchema);
