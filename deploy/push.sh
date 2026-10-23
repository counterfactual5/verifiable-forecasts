#!/usr/bin/env bash
# Deploys the committed tree (HEAD; uncommitted edits never leave this machine) to the live server,
# copies the keys the live run reads from the local .env, installs the hourly timer and the
# dashboard's nginx site. Usage: VF_DEPLOY_HOST=user@host bash deploy/push.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOST="${VF_DEPLOY_HOST:?set VF_DEPLOY_HOST=user@host}"
DEST=/opt/verifiable-forecasts
stage="$REPO/.local/live-deploy/export"
rm -rf "$stage" && mkdir -p "$stage"
git -C "$REPO" archive HEAD | tar -x -C "$stage"
rsync -az --delete --exclude /.env --exclude /agents/out/ --exclude /agents/.venv/ \
  --exclude /demo/out/ --exclude /dashboard/live-replay.json --exclude '/dashboard/*.tmp' \
  --exclude /analysis/data/ --exclude /analysis/.venv/ \
  "$stage/" "$HOST:$DEST/"
if [[ -f "$REPO/.env" ]]; then
  grep -E '^(MAINNET_RPC_URL|VOL_TSFM_[A-Z_]+)=' "$REPO/.env" \
    | ssh "$HOST" "umask 077 && cat > $DEST/.env && chmod 600 $DEST/.env"
fi
ssh "$HOST" "DEST=$DEST bash -s" <<'EOF'
set -euo pipefail
cd "$DEST"
uv sync --project agents --locked
uv sync --project analysis --locked
install -m 644 deploy/vf-live.service deploy/vf-live.timer /etc/systemd/system/
mkdir -p /var/www/vf-acme /root/vf-nginx-backups
tar -czf "/root/vf-nginx-backups/nginx-$(date +%Y%m%d-%H%M%S).tgz" -C /etc nginx
site() {
  sed "s/VF_CERT/$1/" deploy/nginx-vf.conf > /etc/nginx/sites-available/verifiable-forecasts
  ln -sf /etc/nginx/sites-available/verifiable-forecasts /etc/nginx/sites-enabled/verifiable-forecasts
  if nginx -t 2>/dev/null; then systemctl reload nginx
  else rm -f /etc/nginx/sites-enabled/verifiable-forecasts; nginx -t; exit 1; fi
}
domain=verifiable.llm.christmas
if [[ -d /etc/letsencrypt/live/$domain ]]; then site "$domain"
else
  site llm.christmas
  if certbot certonly --webroot -w /var/www/vf-acme -d "$domain" --non-interactive \
       --agree-tos --register-unsafely-without-email --keep-until-expiring; then site "$domain"
  else echo "certbot failed: $domain keeps the llm.christmas certificate (Cloudflare Full)" >&2; fi
fi
systemctl daemon-reload
systemctl enable --now vf-live.timer
systemctl list-timers vf-live.timer --no-pager
EOF
