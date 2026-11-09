#!/usr/bin/env bash
# Roda NA VPS (chamado pelo publicar.ps1). Sobe/atualiza a API do App Frotas
# com o código em ~/frotas e publica o site (e o APK) no Caddy do CRM.
# Uso: bash ~/frotas/deploy/atualizar.sh DOMINIO
set -euo pipefail
cd "$(dirname "$0")"
DOMINIO="${1:?informe o domínio}"
SITES="$HOME/caddy-sites"

[ -f .env ] || { echo "Falta deploy/.env: rode o publicar.ps1 com -Configurar"; exit 1; }
docker ps --format '{{.Names}}' | grep -qx crm-caddy-1 \
  || { echo "O Caddy do CRM (crm-caddy-1) não está rodando."; exit 1; }

# Rede e pasta compartilhadas com o Caddy do CRM (o atualizar.sh do CRM também cria).
mkdir -p "$SITES/frotas"
docker network inspect caddy-sites >/dev/null 2>&1 || docker network create caddy-sites >/dev/null

echo "==> Construindo e subindo a API (a primeira vez demora alguns minutos)..."
docker compose up -d --build --remove-orphans
docker image prune -f >/dev/null

echo "==> Esperando a API responder..."
ok=""
for _ in $(seq 1 40); do
  # Testa de dentro do Caddy: confirma a API e a rede compartilhada de uma vez.
  if docker exec crm-caddy-1 wget -qO /dev/null http://frotas-api:8080/health 2>/dev/null; then
    ok=1; break
  fi
  sleep 3
done
[ -n "$ok" ] || { echo "A API não respondeu. Veja: cd ~/frotas/deploy && docker compose logs api --tail 100"; exit 1; }

# APK novo (se o publicar.ps1 enviou um).
if [ -f "$HOME/frotas-app.apk" ]; then
  mv "$HOME/frotas-app.apk" "$SITES/frotas/app.apk"
  echo "==> APK publicado."
fi

# Site no Caddy do CRM. O reload é atômico: se o arquivo tiver erro, o Caddy
# recusa e continua com a configuração anterior (o CRM não cai).
sed "s/DOMINIO_FROTAS/$DOMINIO/" frotas.caddy > "$SITES/frotas.caddy"
docker exec crm-caddy-1 caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile

echo "No ar: https://$DOMINIO"
