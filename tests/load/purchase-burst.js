/**
 * Teste de carga — pico de compras (Fase 8).
 *
 * Simula a "abertura de vendas de um show": um PICO súbito de requisições de
 * compra batendo no endpoint da fila virtual (POST .../purchase). O objetivo
 * NÃO é medir o banco, e sim PROVAR a tese do trabalho:
 *
 *   - sob pico, as compras entram na fila (HTTP 202) sem derrubar o sistema;
 *   - a `queue_depth` (no Grafana) sobe e depois é drenada no ritmo do worker
 *     (WORKER_RATE_MS) — backpressure / smoothing de carga;
 *   - a exclusão mútua se mantém: por assento, só a primeira compra vence
 *     (as demais viram `failed`, visível em worker_messages_processed_total).
 *
 * Parâmetros (via -e):
 *   API   (default http://localhost:8080)
 *   PEAK  (default 50)   pico de requisições/segundo
 *   RAMP  (default 10s)  tempo subindo até o pico
 *   HOLD  (default 20s)  tempo segurando o pico
 *
 * Execução (Docker, sem instalar k6): use scripts/loadtest.ps1 ou .sh.
 */

import http from "k6/http";
import { check } from "k6";

const API = __ENV.API || "http://localhost:8080";
const PEAK = Number(__ENV.PEAK || 50);

export const options = {
  scenarios: {
    pico: {
      executor: "ramping-arrival-rate",
      startRate: 5,
      timeUnit: "1s",
      preAllocatedVUs: 50,
      maxVUs: 300,
      stages: [
        { target: PEAK, duration: __ENV.RAMP || "10s" }, // subida ao pico
        { target: PEAK, duration: __ENV.HOLD || "20s" }, // segura o pico
        { target: 0, duration: "5s" }, // alívio
      ],
    },
  },
  thresholds: {
    // O sistema deve continuar aceitando compras (202) sob pico, sem erros 5xx.
    http_req_failed: ["rate<0.05"],
    "checks{check:enfileirado}": ["rate>0.95"],
  },
};

// setup() roda uma vez: descobre o evento e a lista de assentos.
export function setup() {
  const ev = http.get(`${API}/events`).json();
  const eventId = ev[0]._id;
  const seats = http.get(`${API}/events/${eventId}/seats`).json();
  const seatIds = seats.map((s) => s._id);
  return { eventId, seatIds };
}

export default function (data) {
  // Assento aleatório: gera disputa pelos mesmos assentos (exclusão mútua).
  const seatId = data.seatIds[Math.floor(Math.random() * data.seatIds.length)];
  const res = http.post(
    `${API}/events/${data.eventId}/seats/${seatId}/purchase`,
    JSON.stringify({ userEmail: `load+${__VU}-${__ITER}@test.local` }),
    { headers: { "Content-Type": "application/json" } },
  );
  // 202 = aceito na fila. É o comportamento esperado sob pico.
  check(res, { enfileirado: (r) => r.status === 202 });
}
