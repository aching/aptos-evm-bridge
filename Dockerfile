# OKRW bridge demo: relayer + one-click web UI (testnet demo only).
FROM node:22-slim AS deps
WORKDIR /app
COPY relayer/package.json relayer/package-lock.json* ./relayer/
RUN cd relayer && npm ci --omit=dev

FROM node:22-slim AS runner
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/relayer/node_modules ./relayer/node_modules
COPY relayer/package.json ./relayer/
COPY relayer/src ./relayer/src
COPY relayer/public ./relayer/public
COPY relayer/tsconfig.json ./relayer/
# tsx runs TypeScript directly — no build step needed.
EXPOSE 3013
WORKDIR /app/relayer
CMD ["node", "--import", "tsx", "src/server.ts"]
