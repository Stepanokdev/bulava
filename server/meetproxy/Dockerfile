FROM node:22-alpine
WORKDIR /app
COPY server.js ./
COPY public ./public
USER node
ENV DATA_DIR=/app/data
EXPOSE 3000
CMD ["node", "server.js"]
