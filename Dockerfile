ARG NODE_VERSION=22

# ─────────────────────────────────────────────────────────────────────────────
# Stage 1 — deps: install ALL dependencies (dev included for build)
# ─────────────────────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS deps

RUN corepack enable
WORKDIR /app

COPY package.json pnpm-lock.yaml ./
RUN corepack install
COPY prisma ./prisma/

RUN pnpm install --frozen-lockfile

# ─────────────────────────────────────────────────────────────────────────────
# Stage 2 — builder: compile TypeScript, generate Prisma client
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS builder

COPY . .

RUN pnpm exec prisma generate
RUN pnpm build

# ─────────────────────────────────────────────────────────────────────────────
# Stage 3 — prod-deps: production-only node_modules
# ─────────────────────────────────────────────────────────────────────────────
FROM deps AS prod-deps

RUN pnpm prune --prod

# ─────────────────────────────────────────────────────────────────────────────
# Stage 4 — runtime: minimal final image
# ─────────────────────────────────────────────────────────────────────────────
FROM node:${NODE_VERSION}-alpine AS runtime

RUN apk add --no-cache dumb-init

RUN addgroup -S appgroup \
 && adduser  -S appuser -G appgroup

WORKDIR /app

COPY --from=prod-deps --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder   --chown=appuser:appgroup /app/dist          ./dist
COPY --from=builder   --chown=appuser:appgroup /app/prisma        ./prisma
COPY --from=builder   --chown=appuser:appgroup /app/package.json  ./package.json

ENV NODE_ENV=production \
    PORT=3000

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

ENTRYPOINT ["/usr/bin/dumb-init", "--"]
CMD ["node", "dist/main.js"]
