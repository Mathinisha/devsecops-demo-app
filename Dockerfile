# --- Stage 1: build dependencies ---
FROM node:20.15.1-alpine3.20 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

# --- Stage 2: final runtime image ---
FROM node:20.15.1-alpine3.20
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js ./
COPY package*.json ./
USER appuser
EXPOSE 3000
CMD ["node", "app.js"]
