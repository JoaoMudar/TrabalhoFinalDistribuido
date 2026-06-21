# Dockerfile do frontend (React + Vite).
# Na Fase 0 rodamos o servidor de desenvolvimento do Vite (com hot reload),
# que é o suficiente para validar o scaffolding. O build de produção servido
# por Nginx fica para a Fase 5 (containerização para o K8s).
# Contexto de build = raiz do monorepo.

FROM node:20-alpine
WORKDIR /repo

COPY package.json package-lock.json* ./
COPY apps/web/package.json apps/web/package.json

RUN npm install --workspace apps/web

COPY apps/web ./apps/web

EXPOSE 5173
# --host já está no script "dev" para expor fora do container.
CMD ["npm", "run", "dev", "--workspace", "apps/web"]
