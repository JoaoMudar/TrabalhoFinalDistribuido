/**
 * Conexão com o MongoDB via Mongoose (Fase 1).
 *
 * O Mongo guarda os dados de domínio: eventos, assentos e pedidos.
 * Em dev a URL aponta para o container `mongo` do docker-compose; em produção
 * (EKS) virá de um Secret do Kubernetes.
 */

import mongoose from "mongoose";
import { config } from "../config.js";

/** Abre a conexão com o MongoDB. Lança erro se não conseguir conectar. */
export async function connectMongo(): Promise<void> {
  mongoose.set("strictQuery", true);
  await mongoose.connect(config.mongoUrl);
}

/** Fecha a conexão (usado no encerramento gracioso). */
export async function disconnectMongo(): Promise<void> {
  await mongoose.disconnect();
}
