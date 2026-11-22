#!/usr/bin/env bash
# Chạy KHÔNG cần sudo (user thuộc nhóm docker).
# 3 instance backend + 1 "React Admin", CHỈ bind 127.0.0.1 -> Internet không gọi thẳng được,
# bắt buộc đi qua Nginx.
set -euo pipefail
cd "$(dirname "$0")"
IMG=nginx:latest

for port in 8080 8081 8082; do
  docker rm -f "backend-$port" >/dev/null 2>&1 || true
  docker run -d --name "backend-$port" --restart unless-stopped \
    -p "127.0.0.1:$port:80" -e INSTANCE="backend-$port" \
    -v "$PWD/backend/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
    --memory 32m "$IMG" >/dev/null
  echo "backend-$port  -> 127.0.0.1:$port"
done

docker rm -f react-admin >/dev/null 2>&1 || true
docker run -d --name react-admin --restart unless-stopped \
  -p 127.0.0.1:4000:80 \
  -v "$PWD/admin:/usr/share/nginx/html:ro" \
  --memory 32m "$IMG" >/dev/null
echo "react-admin   -> 127.0.0.1:4000"
