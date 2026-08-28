# syntax=docker/dockerfile:1

# ── Stage 1: builder ─────────────────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

COPY package*.json ./

RUN npm ci --omit=dev && \
    npm cache clean --force

# ── Stage 2: production ───────────────────────────────────────────────────────
FROM node:20-alpine AS production

# Install wget for healthcheck
RUN apk add --no-cache wget

# Create non-root user
RUN addgroup -g 1000 -S appgroup && \
    adduser  -u 1000 -S appuser -G appgroup

WORKDIR /app

# Copy node_modules from builder
COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules

# Copy application source
COPY --chown=appuser:appgroup src/ ./src/
COPY --chown=appuser:appgroup package.json ./

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD wget -qO- http://localhost:3000/health || exit 1

CMD ["node", "src/index.js"]
