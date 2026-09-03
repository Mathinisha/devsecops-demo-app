# --- Stage 1: build dependencies ---
FROM node:22-alpine3.21 AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install --only=production

# --- Stage 2: final runtime image ---
FROM node:14-buster
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js ./
COPY package*.json ./
EXPOSE 3000
CMD ["node", "app.js"]
