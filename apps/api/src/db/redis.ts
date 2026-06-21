/**
 * Cliente Redis via ioredis (Fase 1).
 *
 * O Redis é usado para a EXCLUSÃO MÚTUA DISTRIBUÍDA: o lock temporário de
 * assento (SET NX + TTL). Na Fase 2 também guardará a posição na fila virtual.
 *
 * Um único cliente é compartilhado por toda a API (ioredis já faz pool/lazy
 * connect internamente).
 */

import { Redis } from "ioredis";
import { config } from "../config.js";

export const redis = new Redis(config.redisUrl, {
  // Em ambiente containerizado o Redis pode subir alguns instantes depois;
  // deixamos o ioredis tentar reconectar em vez de derrubar a API.
  maxRetriesPerRequest: null,
});
