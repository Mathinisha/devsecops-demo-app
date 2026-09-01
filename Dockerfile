# --- Stage 1: build dependencies ---
FROM node:14
WORKDIR /app
COPY package*.json ./
RUN npm install --only=production

# --- Stage 2: final runtime image ---
FROM node:22-alpine3.21
RUN apk update && apk upgrade && apk add --no-cache dumb-init~=1.2
# npm/npx/corepack are only needed to install packages, never to run this app —
# removing them also removes their bundled deps, which is exactly what Trivy flagged
RUN rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack
RUN addgroup -S appgroup && adduser -S appuser -G appgroup
WORKDIR /app
COPY --from=builder /app/node_modules ./node_modules
COPY app.js ./
COPY package*.json ./
USER appuser
EXPOSE 3000
ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "app.js"]
