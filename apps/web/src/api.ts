/**
 * Cliente da API REST (Fase 4).
 *
 * Todas as chamadas passam por "/api", que o Vite faz proxy para o backend
 * (ver vite.config.ts). Assim o frontend não precisa saber a URL real da API.
 */

const BASE = "/api";

async function http<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    headers: { "Content-Type": "application/json" },
    ...init,
  });
  if (!res.ok) {
    const body = (await res.json().catch(() => ({}))) as { error?: string };
    throw new Error(body.error ?? `HTTP ${res.status}`);
  }
  return res.json() as Promise<T>;
}

export interface EventDTO {
  _id: string;
  name: string;
  date: string;
  venue: string;
  description?: string;
}

export type Availability = "available" | "reserved" | "sold";

export interface SeatDTO {
  _id: string;
  code: string;
  section: string;
  price: number;
  status: string;
  availability: Availability;
}

export interface TicketDTO {
  status: "queued" | "processing" | "reserved" | "failed";
  position: number;
  orderId?: string;
  expiresAt?: string;
  error?: string;
}

export const api = {
  listEvents: () => http<EventDTO[]>("/events"),

  listSeats: (eventId: string) => http<SeatDTO[]>(`/events/${eventId}/seats`),

  /** Entra na fila virtual de compra. Devolve o ticket para acompanhar. */
  purchase: (eventId: string, seatId: string, userEmail: string) =>
    http<{ ticketId: string; position: number; status: string }>(
      `/events/${eventId}/seats/${seatId}/purchase`,
      { method: "POST", body: JSON.stringify({ userEmail }) },
    ),

  /** Consulta o estado/posição de um ticket na fila (polling). */
  ticket: (ticketId: string) => http<TicketDTO>(`/queue/${ticketId}`),

  /** Mock de pagamento (corpo "{}" para satisfazer o parser JSON do Fastify). */
  pay: (orderId: string) =>
    http<{ status: string; orderId: string }>(`/orders/${orderId}/pay`, {
      method: "POST",
      body: "{}",
    }),
};
