# MD05 Session 11 — Reverse Proxy với Nginx

| Bài | Nội dung | Cấu hình |
|---|---|---|
| [Bài 1](nginx/bai1/README.md) | Reverse Proxy cơ bản: port 80 → `localhost:3000`, `proxy_pass`, bẫy **502 Bad Gateway**, HTTPS với Let's Encrypt | [`default`](nginx/bai1/default), [`default-ssl`](nginx/bai1/default-ssl) |
| [Bài 2](nginx/bai2/README.md) | Path-based routing: `/api/` → `:8080`, còn lại → `:3000`; header `Host`, `X-Real-IP`, bẫy **`X-Forwarded-For`** | [`default`](nginx/bai2/default) |

Các cấu hình HTTP đã được chạy thử bằng `nginx -t` và request thật trên Docker (`nginx:1.27-alpine`). Riêng `default-ssl` cần tên miền và chứng chỉ thật nên chỉ test được trên VPS.
