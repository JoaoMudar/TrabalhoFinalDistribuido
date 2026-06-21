# Dockerfile do worker (Node + TS). Mesma estratégia multi-stage da API.
# Contexto de build = raiz do monorepo.

# ---- Stage 1: build ----
FROM node:20-alpine AS build
WORKDIR /repo

COPY package.json package-lock.json* ./
COPY tsconfig.base.json ./
COPY apps/worker/package.json apps/worker/package.json

RUN npm install --workspace apps/worker

COPY apps/worker ./apps/worker
RUN npm run build --workspace apps/worker

# ---- Stage 2: runtime ----
FROM node:20-alpine AS runtime
WORKDIR /repo
ENV NODE_ENV=production

COPY package.json package-lock.json* ./
COPY apps/worker/package.json apps/worker/package.json
RUN npm install --omit=dev --workspace apps/worker

COPY --from=build /repo/apps/worker/dist ./apps/worker/dist

CMD ["node", "apps/worker/dist/index.js"]
