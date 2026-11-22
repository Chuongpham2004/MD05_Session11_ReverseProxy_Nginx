# MD05 Session 11 — Reverse Proxy với Nginx

| Bài | Nội dung | Cấu hình |
|---|---|---|
| [Bài 1](nginx/bai1/README.md) | Reverse Proxy cơ bản: port 80 → `localhost:3000`, `proxy_pass`, bẫy **502 Bad Gateway**, HTTPS với Let's Encrypt | [`default`](nginx/bai1/default), [`default-ssl`](nginx/bai1/default-ssl) |
| [Bài 2](nginx/bai2/README.md) | Path-based routing: `/api/` → `:8080`, còn lại → `:3000`; header `Host`, `X-Real-IP`, bẫy **`X-Forwarded-For`** | [`default`](nginx/bai2/default) |
| [Bài 3](nginx/bai3/README.md) | HTTPS với Let's Encrypt: cài certbot, `certbot --nginx`, cấu hình 443 viết tay (`ssl_certificate` / `ssl_certificate_key`), bẫy **gia hạn 90 ngày** (systemd timer / cron). Đã triển khai thật trên VPS | [`api.my-ecommerce.com`](nginx/bai3/api.my-ecommerce.com), [`renew/`](nginx/bai3/renew) |
| [Bài 4](nginx/bai4/README.md) | Tối ưu: `client_max_body_size 10M` (sửa lỗi 413), nén **Gzip** (JS/CSS/JSON giảm 67–93%), bẫy **`reload` và `restart`** (đo thực tế: 0 và 207 request lỗi) | [`default`](nginx/bai4/default) |
| [Bài 5](nginx/bai5/README.md) | Phân tích: **Nginx (edge) và Spring Cloud Gateway**, so sánh thế mạnh, sơ đồ data flow, vì sao không bỏ Nginx. Thực nghiệm: chặn 73% traffic rác, failover, trang bảo trì | [`edge.conf`](nginx/bai5/edge.conf) |
| [Bài 6](nginx/bai6/README.md) | Load Balancing: `upstream` Round Robin 3 backend (8080/8081/8082), failover bằng `max_fails` + `proxy_next_upstream`, subdomain `admin.` bằng `server_name`. Bẫy **thiếu `zone`** khiến Round Robin dồn hết vào 8080 | [`nginx.conf`](nginx/bai6/nginx.conf), [`vps/`](nginx/bai6/vps) (production `chuong.omniev.tech`) |

Các cấu hình HTTP đã được chạy thử bằng `nginx -t` và request thật trên Docker (`nginx:1.27-alpine`). Riêng `default-ssl` cần tên miền và chứng chỉ thật nên chỉ test được trên VPS.
