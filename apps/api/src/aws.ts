/**
 * Clientes AWS (SQS + SNS) — Fase 2.
 *
 * Em dev, apontam para o LocalStack (AWS_ENDPOINT_URL definido) e usam
 * credenciais fictícias que o LocalStack aceita. Em produção (EKS), o endpoint
 * fica vazio e o SDK usa a cadeia de credenciais padrão (IAM Role do pod).
 */

import { SQSClient, GetQueueUrlCommand } from "@aws-sdk/client-sqs";
import { SNSClient, CreateTopicCommand } from "@aws-sdk/client-sns";
import { config } from "./config.js";

const isLocal = Boolean(config.awsEndpointUrl);

const clientConfig = {
  region: config.awsRegion,
  ...(isLocal
    ? {
        endpoint: config.awsEndpointUrl,
        credentials: { accessKeyId: "test", secretAccessKey: "test" },
      }
    : {}),
};

export const sqs = new SQSClient(clientConfig);
export const sns = new SNSClient(clientConfig);

let queueUrlCache: string | null = null;
/** Resolve (e cacheia) a URL da fila SQS pelo nome. */
export async function getQueueUrl(): Promise<string> {
  if (queueUrlCache) return queueUrlCache;
  const out = await sqs.send(new GetQueueUrlCommand({ QueueName: config.queueName }));
  queueUrlCache = out.QueueUrl as string;
  return queueUrlCache;
}

let topicArnCache: string | null = null;
/** Resolve (e cacheia) o ARN do tópico SNS. CreateTopic é idempotente. */
export async function getTopicArn(): Promise<string> {
  if (topicArnCache) return topicArnCache;
  const out = await sns.send(new CreateTopicCommand({ Name: config.topicName }));
  topicArnCache = out.TopicArn as string;
  return topicArnCache;
}
