# Dockerfile da API (Fastify + TS). Multi-stage: build TS -> runtime enxuto.
# O contexto de build é a RAIZ do monorepo (ver docker-compose.yml), por isso
# os caminhos abaixo são relativos à raiz.

# ---- Stage 1: dependências + build ----
FROM node:20-alpine AS build
WORKDIR /repo

# Manifests primeiro (cache de camadas). Workspace npm precisa do package.json raiz.
COPY package.json package-lock.json* ./
COPY tsconfig.base.json ./
COPY apps/api/package.json apps/api/package.json

# Instala dependências do workspace da API.
RUN npm install --workspace apps/api

# Código-fonte e build.
COPY apps/api ./apps/api
RUN npm run build --workspace apps/api

# ---- Stage 2: runtime ----
FROM node:20-alpine AS runtime
WORKDIR /repo
ENV NODE_ENV=production

COPY package.json package-lock.json* ./
COPY apps/api/package.json apps/api/package.json
RUN npm install --omit=dev --workspace apps/api

COPY --from=build /repo/apps/api/dist ./apps/api/dist

EXPOSE 8080
CMD ["node", "apps/api/dist/server.js"]
