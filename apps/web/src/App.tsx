/**
 * SPA de venda de ingressos (Fase 4).
 *
 * Fluxo (máquina de estados em `step`):
 *   events  -> lista de eventos
 *   seats   -> mapa de assentos (cores: livre / reservado / vendido)
 *   queue   -> fila virtual: polling da posição do ticket
 *   checkout-> reserva confirmada, pagamento (mock) dentro do TTL
 *   done    -> confirmação (e-mail disparado via SNS+Lambda no backend)
 *
 * O caminho de compra usa a FILA (purchase + polling), espelhando a arquitetura
 * distribuída: a requisição não bate direto no banco, entra na fila SQS.
 */

import { useEffect, useState } from "react";
import { api, type EventDTO, type SeatDTO, type TicketDTO } from "./api";

type Step = "events" | "seats" | "queue" | "checkout" | "done";

export function App() {
  const [step, setStep] = useState<Step>("events");
  const [email, setEmail] = useState("jppiresjppires@gmail.com");
  const [error, setError] = useState<string | null>(null);

  const [events, setEvents] = useState<EventDTO[]>([]);
  const [event, setEvent] = useState<EventDTO | null>(null);
  const [seats, setSeats] = useState<SeatDTO[]>([]);
  const [seat, setSeat] = useState<SeatDTO | null>(null);

  const [ticketId, setTicketId] = useState<string | null>(null);
  const [ticket, setTicket] = useState<TicketDTO | null>(null);
  const [orderId, setOrderId] = useState<string | null>(null);

  // Carrega eventos ao abrir.
  useEffect(() => {
    api.listEvents().then(setEvents).catch((e) => setError(e.message));
  }, []);

  // Polling da fila enquanto o ticket está em andamento.
  useEffect(() => {
    if (step !== "queue" || !ticketId) return;
    const id = setInterval(async () => {
      try {
        const t = await api.ticket(ticketId);
        setTicket(t);
        if (t.status === "reserved" && t.orderId) {
          setOrderId(t.orderId);
          setStep("checkout");
        } else if (t.status === "failed") {
          setError(t.error ?? "não foi possível reservar o assento");
          setStep("seats");
          void refreshSeats(event!._id);
        }
      } catch (e) {
        setError((e as Error).message);
      }
    }, 800);
    return () => clearInterval(id);
  }, [step, ticketId, event]);

  async function refreshSeats(eventId: string) {
    const s = await api.listSeats(eventId);
    setSeats(s);
  }

  async function openEvent(ev: EventDTO) {
    setError(null);
    setEvent(ev);
    await refreshSeats(ev._id);
    setStep("seats");
  }

  async function chooseSeat(s: SeatDTO) {
    if (s.availability !== "available" || !event) return;
    if (!email.trim()) {
      setError("informe um e-mail para a confirmação");
      return;
    }
    setError(null);
    setSeat(s);
    try {
      const { ticketId, position } = await api.purchase(event._id, s._id, email.trim());
      setTicketId(ticketId);
      setTicket({ status: "queued", position });
      setStep("queue");
    } catch (e) {
      setError((e as Error).message);
    }
  }

  async function pay() {
    if (!orderId) return;
    setError(null);
    try {
      await api.pay(orderId);
      setStep("done");
    } catch (e) {
      setError((e as Error).message);
    }
  }

  function restart() {
    setStep("events");
    setEvent(null);
    setSeat(null);
    setTicket(null);
    setTicketId(null);
    setOrderId(null);
    setError(null);
  }

  return (
    <main className="container">
      <header>
        <h1>🎟️ Ingressos Distribuídos</h1>
        <p className="subtitle">
          Fila virtual · reserva com TTL · confirmação assíncrona
        </p>
      </header>

      {error && <div className="alert">⚠️ {error}</div>}

      {step === "events" && (
        <Events events={events} onPick={openEvent} email={email} setEmail={setEmail} />
      )}

      {step === "seats" && event && (
        <Seats
          event={event}
          seats={seats}
          onPick={chooseSeat}
          onBack={restart}
          onRefresh={() => refreshSeats(event._id)}
        />
      )}

      {step === "queue" && ticket && (
        <Queue ticket={ticket} seat={seat} />
      )}

      {step === "checkout" && seat && (
        <Checkout seat={seat} expiresAt={ticket?.expiresAt} onPay={pay} />
      )}

      {step === "done" && seat && (
        <Done seat={seat} email={email} onRestart={restart} />
      )}
    </main>
  );
}

function Events(props: {
  events: EventDTO[];
  onPick: (e: EventDTO) => void;
  email: string;
  setEmail: (v: string) => void;
}) {
  return (
    <section>
      <label className="field">
        E-mail para confirmação
        <input
          type="email"
          value={props.email}
          onChange={(e) => props.setEmail(e.target.value)}
          placeholder="voce@exemplo.com"
        />
      </label>
      <h2>Eventos</h2>
      {props.events.length === 0 && <p>Carregando eventos…</p>}
      <ul className="event-list">
        {props.events.map((ev) => (
          <li key={ev._id} className="card" onClick={() => props.onPick(ev)}>
            <strong>{ev.name}</strong>
            <span>{new Date(ev.date).toLocaleString("pt-BR")}</span>
            <span className="muted">{ev.venue}</span>
          </li>
        ))}
      </ul>
    </section>
  );
}

function Seats(props: {
  event: EventDTO;
  seats: SeatDTO[];
  onPick: (s: SeatDTO) => void;
  onBack: () => void;
  onRefresh: () => void;
}) {
  return (
    <section>
      <button className="link" onClick={props.onBack}>← eventos</button>
      <h2>{props.event.name}</h2>
      <div className="legend">
        <span><i className="dot available" /> livre</span>
        <span><i className="dot reserved" /> reservado</span>
        <span><i className="dot sold" /> vendido</span>
        <button className="link" onClick={props.onRefresh}>atualizar</button>
      </div>
      <div className="seat-grid">
        {props.seats.map((s) => (
          <button
            key={s._id}
            className={`seat ${s.availability}`}
            disabled={s.availability !== "available"}
            onClick={() => props.onPick(s)}
            title={`${s.code} · R$ ${s.price}`}
          >
            {s.code}
          </button>
        ))}
      </div>
    </section>
  );
}

function Queue(props: { ticket: TicketDTO; seat: SeatDTO | null }) {
  const { ticket } = props;
  return (
    <section className="center">
      <div className="spinner" />
      <h2>Você está na fila</h2>
      {ticket.status === "queued" && (
        <p>Posição na fila: <strong>{ticket.position}</strong></p>
      )}
      {ticket.status === "processing" && <p>Processando sua reserva…</p>}
      {props.seat && <p className="muted">Assento {props.seat.code}</p>}
      <p className="muted">Aguarde — sua vez será processada pelo worker.</p>
    </section>
  );
}

function Checkout(props: { seat: SeatDTO; expiresAt?: string; onPay: () => void }) {
  const remaining = useCountdown(props.expiresAt);
  return (
    <section className="center">
      <h2>✅ Assento reservado!</h2>
      <p>
        Assento <strong>{props.seat.code}</strong> · {props.seat.section} · R$ {props.seat.price}
      </p>
      {remaining !== null && (
        <p className={remaining <= 0 ? "alert" : "muted"}>
          {remaining > 0
            ? `Conclua o pagamento em ${formatTime(remaining)}`
            : "Reserva expirada"}
        </p>
      )}
      <button className="primary" onClick={props.onPay} disabled={remaining !== null && remaining <= 0}>
        Pagar (mock)
      </button>
    </section>
  );
}

function Done(props: { seat: SeatDTO; email: string; onRestart: () => void }) {
  return (
    <section className="center">
      <h2>🎉 Pagamento confirmado!</h2>
      <p>Seu ingresso para o assento <strong>{props.seat.code}</strong> está garantido.</p>
      <p className="muted">
        Um e-mail de confirmação foi enviado para <strong>{props.email}</strong> (via SNS → Lambda → SES).
      </p>
      <button className="primary" onClick={props.onRestart}>Comprar outro</button>
    </section>
  );
}

/** Conta o tempo restante (em segundos) até `expiresAt`. */
function useCountdown(expiresAt?: string): number | null {
  const [remaining, setRemaining] = useState<number | null>(null);
  useEffect(() => {
    if (!expiresAt) return;
    const target = new Date(expiresAt).getTime();
    const tick = () => setRemaining(Math.round((target - Date.now()) / 1000));
    tick();
    const id = setInterval(tick, 1000);
    return () => clearInterval(id);
  }, [expiresAt]);
  return remaining;
}

function formatTime(seconds: number): string {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${String(s).padStart(2, "0")}`;
}
