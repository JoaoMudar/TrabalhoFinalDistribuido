/**
 * Modelo de Evento (Fase 1).
 * Um evento (ex.: um show) possui vários assentos à venda.
 */

import { Schema, model, InferSchemaType } from "mongoose";

const eventSchema = new Schema(
  {
    name: { type: String, required: true },
    date: { type: Date, required: true },
    venue: { type: String, required: true },
    description: { type: String, default: "" },
  },
  { timestamps: true },
);

export type Event = InferSchemaType<typeof eventSchema>;
export const EventModel = model("Event", eventSchema);
