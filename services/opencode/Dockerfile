# opencode coding sidecar. Postgres can only speak HTTP, so this thin server
# runs `opencode run` for it (the "hands" that edit code), exactly like the
# Playwright sidecar runs a browser. opencode is pointed at the same self-hosted
# vLLM as its model provider (config written at boot from env, see server.js).
FROM node:22-bookworm-slim

# git: clone repos to work in. ca-certificates: TLS for the opencode install +
# outbound model calls.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates \
 && rm -rf /var/lib/apt/lists/*

ENV NODE_ENV=production

# The opencode CLI (https://opencode.ai). If the npm distribution changes, swap
# this for their install script: curl -fsSL https://opencode.ai/install | bash
RUN npm install -g opencode-ai

WORKDIR /app
COPY package.json ./
COPY server.js ./

ENV PORT=5000
ENV OPENCODE_CONFIG=/app/opencode.json
ENV WORKSPACE_DIR=/workspace

EXPOSE 5000
CMD ["node", "server.js"]
