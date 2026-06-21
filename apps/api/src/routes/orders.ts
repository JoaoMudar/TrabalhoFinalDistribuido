/**
 * Rotas de pedido e pagamento (Fase 1).
 *
 * O pagamento é um MOCK (sem gateway real). A regra distribuída importante:
 * só confirma se o lock do assento AINDA estiver ativo no Redis. Se o TTL
 * expirou, a reserva caiu e o usuário precisa refazer a compra.
 *
 * Na Fase 3, após confirmar, publicaremos no SNS "order-confirmed" para a
 * Lambda enviar o e-mail (ver TODO abaixo).
 */

import type { FastifyInstance } from "fastify";
import { PublishCommand } from "@aws-sdk/client-sns";
import { OrderModel } from "../models/order.js";
import { SeatModel } from "../models/seat.js";
import { isSeatLocked, releaseSeatLock } from "../services/lock.js";
import { sns, getTopicArn } from "../aws.js";
import { payments } from "../metrics.js";

export async function orderRoutes(app: FastifyInstance): Promise<void> {
  // Status de um pedido (lockToken fica oculto por padrão).
  app.get<{ Params: { orderId: string } }>("/orders/:orderId", async (req, reply) => {
    const order = await OrderModel.findById(req.params.orderId).lean();
    if (!order) return reply.code(404).send({ error: "pedido não encontrado" });
    return order;
  });

  // Mock de pagamento.
  app.post<{ Params: { orderId: string } }>("/orders/:orderId/pay", async (req, reply) => {
    // Precisamos do lockToken (select:false) para liberar o lock depois.
    const order = await OrderModel.findById(req.params.orderId).select("+lockToken");
    if (!order) return reply.code(404).send({ error: "pedido não encontrado" });

    if (order.status === "paid") {
      return { status: "paid", orderId: String(order._id) };
    }
    if (order.status !== "pending") {
      payments.labels("conflict").inc();
      return reply.code(409).send({ error: `pedido está '${order.status}'` });
    }

    // A reserva ainda vale? (lock no Redis ativo)
    const stillLocked = await isSeatLocked(String(order.seatId));
    if (!stillLocked) {
      order.status = "expired";
      await order.save();
      payments.labels("expired").inc();
      return reply.code(410).send({ error: "reserva expirou — refaça a compra" });
    }

    // Pagamento aprovado (mock): vende o assento e confirma o pedido.
    order.status = "paid";
    order.paidAt = new Date();
    await order.save();
    await SeatModel.updateOne({ _id: order.seatId }, { status: "sold" });
    await releaseSeatLock(String(order.seatId), order.lockToken as string);
    payments.labels("paid").inc();

    // Fase 2/3: publica o evento "pedido confirmado" no SNS. A Lambda de e-mail
    // (Fase 3) assina esse tópico. O envio fica TOTALMENTE desacoplado da compra:
    // se o SNS falhar, o pagamento continua válido (apenas logamos o erro).
    try {
      const topicArn = await getTopicArn();
      await sns.send(
        new PublishCommand({
          TopicArn: topicArn,
          Subject: "order-confirmed",
          Message: JSON.stringify({
            orderId: String(order._id),
            eventId: String(order.eventId),
            seatId: String(order.seatId),
            userEmail: order.userEmail,
            paidAt: order.paidAt,
          }),
        }),
      );
      app.log.info({ orderId: String(order._id) }, "evento publicado no SNS order-confirmed");
    } catch (err) {
      app.log.error(err, "falha ao publicar no SNS (pagamento mantido)");
    }

    return {
      status: "paid",
      orderId: String(order._id),
      seatId: String(order.seatId),
    };
  });
}
