/**
 * Lock de assento no Redis — o coração da exclusão mútua distribuída (Fase 1).
 *
 * Usamos `SET chave valor EX ttl NX`:
 *   - NX = só cria se a chave NÃO existir (operação atômica = exclusão mútua).
 *   - EX = expiração em segundos (TTL). Se o usuário não pagar, o lock some
 *          sozinho e o assento volta a ficar livre.
 *
 * O `valor` é um token único do dono da reserva: a liberação só acontece se o
 * token bater (script Lua atômico), evitando que um processo libere o lock de
 * outro.
 */

import { redis } from "../db/redis.js";

/** Tempo de reserva temporária do assento (5 minutos). */
export const SEAT_LOCK_TTL_SECONDS = 5 * 60;

function lockKey(seatId: string): string {
  return `lock:seat:${seatId}`;
}

/** Tenta adquirir o lock do assento. Retorna true se conseguiu (assento livre). */
export async function acquireSeatLock(
  seatId: string,
  token: string,
  ttlSeconds: number = SEAT_LOCK_TTL_SECONDS,
): Promise<boolean> {
  const result = await redis.set(lockKey(seatId), token, "EX", ttlSeconds, "NX");
  return result === "OK";
}

/** Diz se o assento está atualmente reservado (lock ativo). */
export async function isSeatLocked(seatId: string): Promise<boolean> {
  return (await redis.exists(lockKey(seatId))) === 1;
}

/** Segundos restantes do lock (>0), ou negativo se não existir. */
export async function getSeatLockTTL(seatId: string): Promise<number> {
  return redis.ttl(lockKey(seatId));
}

/**
 * Libera o lock SOMENTE se o token bater (compare-and-delete atômico via Lua).
 * Retorna true se liberou.
 */
export async function releaseSeatLock(seatId: string, token: string): Promise<boolean> {
  const lua = `
    if redis.call("get", KEYS[1]) == ARGV[1] then
      return redis.call("del", KEYS[1])
    else
      return 0
    end`;
  const result = (await redis.eval(lua, 1, lockKey(seatId), token)) as number;
  return result === 1;
}
