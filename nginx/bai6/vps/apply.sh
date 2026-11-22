#!/usr/bin/env bash
# Chạy trên VPS:  sudo bash ~/bai6/apply.sh
# Backup -> copy config -> nginx -t -> reload (không restart). Sai thì tự rollback.
set -euo pipefail
cd "$(dirname "$0")"
TS=$(date +%F-%H%M)
SA=/etc/nginx/sites-available
SE=/etc/nginx/sites-enabled

cp -a "$SA/chuong.omniev.tech" "$SA/chuong.omniev.tech.bak.$TS"
install -m 644 chuong.omniev.tech       "$SA/chuong.omniev.tech"
install -m 644 admin.chuong.omniev.tech "$SA/admin.chuong.omniev.tech"
ln -sf "$SA/admin.chuong.omniev.tech" "$SE/admin.chuong.omniev.tech"

if nginx -t; then
  systemctl reload nginx
  echo ">>> reload OK (backup: $SA/chuong.omniev.tech.bak.$TS)"
else
  echo ">>> nginx -t FAIL -> rollback"
  cp -a "$SA/chuong.omniev.tech.bak.$TS" "$SA/chuong.omniev.tech"
  rm -f "$SE/admin.chuong.omniev.tech" "$SA/admin.chuong.omniev.tech"
  nginx -t && systemctl reload nginx
  exit 1
fi

# HTTPS cho subdomain admin (cần bản ghi DNS A admin.chuong -> IP VPS)
if getent ahostsv4 admin.chuong.omniev.tech >/dev/null; then
  certbot --nginx -d admin.chuong.omniev.tech --redirect --non-interactive --keep-until-expiring
  nginx -t && systemctl reload nginx
  echo ">>> HTTPS admin OK"
else
  echo ">>> CHUA co DNS admin.chuong.omniev.tech -> bo qua certbot. Them DNS roi chay lai script."
fi
