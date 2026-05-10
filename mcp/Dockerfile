FROM docker.io/library/node:22-slim
WORKDIR /app
COPY package*.json ./
RUN npm install --omit=dev
COPY index.js .
EXPOSE 8890
ENV PORT=8890
CMD ["node", "index.js"]
