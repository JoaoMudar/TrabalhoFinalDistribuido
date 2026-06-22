/**
 * Lambda de confirmação por e-mail (Fase 3 + Fase 6).
 *
 * Assina o tópico SNS "order-confirmed". Quando um pedido é pago, a API publica
 * no SNS, o SNS invoca esta Lambda e ela envia a confirmação. O envio fica
 * TOTALMENTE desacoplado do fluxo de compra.
 *
 * Dois modos de entrega (escolhidos por variável de ambiente):
 *  - NOTIFY_TOPIC_ARN definido (Fase 6 / AWS Academy): publica a confirmação
 *    num segundo tópico SNS que tem uma assinatura de e-mail. Evita o sandbox
 *    do SES (que exigiria verificar cada destinatário) e mantém a Lambda no
 *    caminho — requisito obrigatório da avaliação. Ver ADR-009.
 *  - caso contrário (dev local / LocalStack): envia via SES, como na Fase 3
 *    (o e-mail aparece em http://localhost:4566/_aws/ses).
 *
 * O AWS SDK v3 (clients sns/ses) é fornecido pelo runtime do Lambda
 * (nodejs20.x), por isso não precisa ser empacotado no .zip.
 */

import type { SNSEvent } from "aws-lambda";
import { SESClient, SendEmailCommand } from "@aws-sdk/client-ses";
import { SNSClient, PublishCommand } from "@aws-sdk/client-sns";

// De DENTRO da Lambda, em dev, falamos com o LocalStack via LOCALSTACK_HOSTNAME
// (injetado automaticamente). Em produção (AWS real) o endpoint fica indefinido
// e o SDK usa o serviço real.
const endpoint =
  process.env.AWS_ENDPOINT_URL ||
  (process.env.LOCALSTACK_HOSTNAME
    ? `http://${process.env.LOCALSTACK_HOSTNAME}:4566`
    : undefined);

// AWS_REGION é injetada pelo próprio runtime do Lambda.
const region = process.env.AWS_REGION ?? "us-east-1";
const localCreds = { accessKeyId: "test", secretAccessKey: "test" };

const ses = new SESClient({
  region,
  ...(endpoint ? { endpoint, credentials: localCreds } : {}),
});
const sns = new SNSClient({
  region,
  ...(endpoint ? { endpoint, credentials: localCreds } : {}),
});

const MAIL_FROM = process.env.MAIL_FROM ?? "no-reply@ingressos.local";
const NOTIFY_TOPIC_ARN = process.env.NOTIFY_TOPIC_ARN;

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
      `Evento:  ${order.eventId}\n` +
      `Comprador: ${order.userEmail}\n\n` +
      "Apresente este e-mail na entrada. Bom show!";

    try {
      if (NOTIFY_TOPIC_ARN) {
        // Fase 6: publica no tópico de notificação (assinatura de e-mail entrega).
        await sns.send(
          new PublishCommand({
            TopicArn: NOTIFY_TOPIC_ARN,
            Subject: subject,
            Message: body,
          }),
        );
        console.log(
          `[lambda-email] confirmação publicada em ${NOTIFY_TOPIC_ARN} (pedido ${order.orderId})`,
        );
      } else {
        // Dev local: envia via SES (visível no SES viewer do LocalStack).
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
      }
    } catch (err) {
      console.error("[lambda-email] falha ao entregar a confirmação:", err);
      throw err; // relança para o SNS reentregar a notificação
    }
  }
};
