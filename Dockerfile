# Demo A (OKRW bridge :3024) + Demo B (swap RFQ :3201 + solver daemon).
# One image, three Fly processes (see fly.toml). tsx runs TS directly.
FROM node:22-slim AS deps
WORKDIR /app
COPY relayer/package.json relayer/package-lock.json* ./relayer/
COPY swap/package.json swap/package-lock.json* ./swap/
RUN cd relayer && npm ci --omit=dev
# swap has no lockfile (demo): reproducible when present, best-effort otherwise.
RUN cd swap && (npm ci --omit=dev 2>/dev/null || npm install --omit=dev)

FROM node:22-slim AS runner
ENV NODE_ENV=production
WORKDIR /app
COPY --from=deps /app/relayer/node_modules ./relayer/node_modules
COPY --from=deps /app/swap/node_modules ./swap/node_modules
COPY relayer/package.json ./relayer/
COPY relayer/src ./relayer/src
COPY relayer/public ./relayer/public
COPY relayer/tsconfig.json ./relayer/
COPY swap/package.json ./swap/
COPY swap/src ./swap/src
COPY swap/public ./swap/public
COPY swap/tsconfig.json ./swap/
COPY scripts/fly-start.sh ./scripts/fly-start.sh
RUN chmod +x ./scripts/fly-start.sh
EXPOSE 3024 3201
CMD ["./scripts/fly-start.sh"]
