/**
 * Lambda de confirmação por e-mail (Fase 3).
 *
 * Assina o tópico SNS "order-confirmed". Quando um pedido é pago, a API publica
 * no SNS, o SNS invoca esta Lambda e ela envia o e-mail de confirmação via SES.
 * O envio fica TOTALMENTE desacoplado do fluxo de compra.
 *
 * O AWS SDK v3 é fornecido pelo próprio runtime do Lambda (nodejs20.x), por
 * isso não precisa ser empacotado no .zip — fica só como devDependency (tipos).
 */

import type { SNSEvent } from "aws-lambda";
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";

// De DENTRO da Lambda, falamos com o LocalStack via LOCALSTACK_HOSTNAME
// (injetado automaticamente). Em produção (AWS real), endpoint fica indefinido
// e o SDK usa o serviço SES real.
const endpoint =
  process.env.AWS_ENDPOINT_URL ||
  (process.env.LOCALSTACK_HOSTNAME
    ? `http://${process.env.LOCALSTACK_HOSTNAME}:4566`
    : undefined);

const ses = new SESClient({
  region: process.env.AWS_REGION ?? "us-east-1",
  ...(endpoint
    ? { endpoint, credentials: { accessKeyId: "test", secretAccessKey: "test" } }
    : {}),
});

const MAIL_FROM = process.env.MAIL_FROM ?? "no-reply@ingressos.local";

interface OrderConfirmed {
  orderId: string;
  eventId: string;
  seatId: string;
  userEmail: string;
  paidAt?: string;
}

export const handler = async (event: SNSEvent): Promise<void> => {
  for (const record of event.Records ?? []) {
    const raw = record.Sns?.Message ?? "{}";

    let order: OrderConfirmed;
    try {
      order = JSON.parse(raw) as OrderConfirmed;
    } catch {
      console.error("[lambda-email] mensagem SNS inválida (ignorada):", raw);
      continue;
    }

    const subject = `Ingresso confirmado — pedido ${order.orderId}`;
    const body =
      "Olá!\n\n" +
      "Seu pagamento foi confirmado. 🎟️\n\n" +
      `Pedido:  ${order.orderId}\n` +
      `Assento: ${order.seatId}\n` +
      `Evento:  ${order.eventId}\n\n` +
      "Apresente este e-mail na entrada. Bom show!";

    try {
      const out = await ses.send(
        new SendEmailCommand({
          Source: MAIL_FROM,
          Destination: { ToAddresses: [order.userEmail] },
          Message: {
            Subject: { Data: subject },
            Body: { Text: { Data: body } },
          },
        }),
      );
      console.log(
        `[lambda-email] e-mail enviado para ${order.userEmail} (MessageId=${out.MessageId})`,
      );
    } catch (err) {
      console.error("[lambda-email] falha ao enviar via SES:", err);
      throw err; // relança para o SNS reentregar a notificação
    }
  }
};
