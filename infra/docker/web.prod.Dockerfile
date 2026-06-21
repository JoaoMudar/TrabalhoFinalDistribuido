# Build de PRODUÇÃO do frontend para o Kubernetes (Fase 5).
#
# Diferente do web.Dockerfile (que roda o dev server do Vite com hot reload),
# aqui compilamos o SPA e servimos os estáticos com Nginx, que também faz o
# proxy de /api para o backend (ver infra/docker/nginx.conf).
# Contexto de build = raiz do monorepo.

# ---- Stage 1: build do SPA ----
FROM node:20-alpine AS build
WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/web/package.json apps/web/package.json
RUN npm install --workspace apps/web

COPY apps/web ./apps/web
RUN npm run build --workspace apps/web

# ---- Stage 2: runtime Nginx ----
FROM nginx:1.27-alpine AS runtime

# Config do Nginx (SPA + proxy /api -> Service "api").
COPY infra/docker/nginx.conf /etc/nginx/conf.d/default.conf

# Entrypoint que injeta o DNS resolver do cluster no boot (ver nginx.conf).
COPY infra/docker/docker-nginx-entrypoint.sh /docker-nginx-entrypoint.sh
RUN chmod +x /docker-nginx-entrypoint.sh

# Estáticos compilados pelo Vite.
COPY --from=build /repo/apps/web/dist /usr/share/nginx/html

EXPOSE 80
ENTRYPOINT ["/docker-nginx-entrypoint.sh"]
