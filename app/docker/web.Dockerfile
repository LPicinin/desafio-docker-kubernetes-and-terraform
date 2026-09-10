# Build context: ./app/web
# Estático servido por nginx; proxy de /api parametrizável via API_UPSTREAM
# (env processada pelo entrypoint oficial do nginx via envsubst em templates/*.template).

FROM nginx:1.27-alpine

ENV API_UPSTREAM=api:8080

COPY index.html styles.css app.js /usr/share/nginx/html/
COPY nginx.conf.template /etc/nginx/templates/default.conf.template

EXPOSE 8080