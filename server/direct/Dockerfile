FROM node:24-alpine@sha256:44fce696f38ba8c987c4db89954051000bbd05ffd8d8659ba15ed4a8602e937f
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts --no-audit --no-fund
COPY coordinator.mjs monitor.mjs ./
ENV AIM_DIRECT_BIND=0.0.0.0 AIM_DIRECT_STATE=/data/coordinator.json
USER node
EXPOSE 8789
CMD ["node", "coordinator.mjs"]
