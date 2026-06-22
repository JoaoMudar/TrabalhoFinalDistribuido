/**
 * Configuração centralizada da API.
 *
 * Lê variáveis de ambiente e aplica defaults seguros para o desenvolvimento
 * local (docker-compose). Em produção (EKS) essas variáveis virão de
 * ConfigMaps/Secrets do Kubernetes.
 *
 * Na Fase 0 ainda NÃO abrimos conexões reais com Mongo/Redis/AWS — apenas
 * carregamos os endpoints para já deixar o contrato pronto para a Fase 1.
 */

/** Lê uma env var com fallback para um default. */
function env(key: string, fallback: string): string {
  const value = process.env[key];
  return value && value.length > 0 ? value : fallback;
}

export const config = {
  /** Porta HTTP da API. */
  port: Number(env("PORT", "8080")),

  /** Host de bind (0.0.0.0 para funcionar dentro do container). */
  host: env("HOST", "0.0.0.0"),

  /** String de conexão do MongoDB (dados: eventos, assentos, pedidos). */
  mongoUrl: env("MONGO_URL", "mongodb://localhost:27017/ingressos"),

  /** String de conexão do Redis (locks com TTL + posição na fila virtual). */
  redisUrl: env("REDIS_URL", "redis://localhost:6379"),

  /**
   * Endpoint da AWS. Em dev (docker-compose / .env) vem setado para o LocalStack;
   * VAZIO por padrão → o SDK usa a AWS real (credenciais da LabRole via IMDS, na
   * Fase 6). Não usar fallback para localhost aqui: no cluster AWS o ConfigMap
   * remove esta var (overlay infra/k8s/overlays/aws) e queremos a AWS de verdade.
   */
  awsEndpointUrl: env("AWS_ENDPOINT_URL", ""),

  /** Região AWS. */
  awsRegion: env("AWS_REGION", "us-east-1"),

  /** Nome da fila SQS (fila virtual de compra). */
  queueName: env("QUEUE_NAME", "ticket-purchase-queue"),

  /** Nome do tópico SNS ("pedido confirmado" -> Lambda de e-mail). */
  topicName: env("TOPIC_NAME", "order-confirmed"),

  /** Nível de log do pino. */
  logLevel: env("LOG_LEVEL", "info"),
} as const;
