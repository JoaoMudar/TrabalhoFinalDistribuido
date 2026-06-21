/**
 * Modelo de Pedido (Fase 1).
 *
 * Ciclo de vida:
 *   pending  -> assento reservado (lock no Redis ativo), aguardando pagamento
 *   paid     -> pagamento confirmado, assento vendido
 *   expired  -> TTL do lock expirou antes do pagamento
 *   cancelled-> cancelado explicitamente (uso futuro)
 *
 * `lockToken` guarda o dono do lock no Redis para liberá-lo com segurança
 * (só quem criou a reserva pode liberar). Fica oculto por padrão (select:false).
 */

import { Schema, model, InferSchemaType } from "mongoose";

const orderSchema = new Schema(
  {
    eventId: { type: Schema.Types.ObjectId, ref: "Event", required: true },
    seatId: { type: Schema.Types.ObjectId, ref: "Seat", required: true },
    userEmail: { type: String, required: true },
    status: {
      type: String,
      enum: ["pending", "paid", "expired", "cancelled"],
      default: "pending",
    },
    expiresAt: { type: Date, required: true },
    paidAt: { type: Date },
    lockToken: { type: String, required: true, select: false },
  },
  { timestamps: true },
);

export type Order = InferSchemaType<typeof orderSchema>;
export const OrderModel = model("Order", orderSchema);
