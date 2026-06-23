# Separate container (chosen in planning): Microsoft's Playwright image ships
# Chromium + all OS deps, so the DB image stays small and a memory-hungry
# Chromium can't take the database down.
FROM mcr.microsoft.com/playwright:v1.49.1-jammy

# Browsers are already in the image; don't re-download on npm install.
ENV PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
ENV NODE_ENV=production

WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev
COPY server.js ./

EXPOSE 3000
CMD ["node", "server.js"]
