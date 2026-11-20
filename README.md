# Bài 1 — Cấu hình Nginx Reverse Proxy Cơ Bản

**Tình huống:** React Frontend chạy ở port `3000` trên VPS. Người dùng chỉ cần gõ `http://domain.com` (port 80) là vào được web.

```
Client ──(port 80/443)──▶ Nginx ──(127.0.0.1:3000)──▶ React app
```

| File | Nội dung |
|---|---|
| [`nginx/bai1/default`](nginx/bai1/default) | **Bài nộp chính** — proxy port 80 → `localhost:3000` |
| [`nginx/bai1/default-ssl`](nginx/bai1/default-ssl) | Mở rộng — HTTPS với Let's Encrypt + redirect 80 → 443 |

---

## 1. Reverse Proxy là gì?

Reverse proxy là một server đứng **trước** ứng dụng, nhận request từ client rồi chuyển tiếp vào app nội bộ, sau đó trả response về cho client. Client chỉ thấy Nginx, không biết app thật chạy ở đâu.

Lợi ích: ẩn port/địa chỉ nội bộ, chỉ mở port 80/443 ra ngoài (port 3000 có thể đóng firewall), là nơi tập trung gắn SSL, nén gzip, cache, load balancing, rate limit.

> Phân biệt: **Forward proxy** đứng phía client (đại diện cho client đi ra Internet), **Reverse proxy** đứng phía server (đại diện cho server đón request vào).

## 2. Cấu hình Nginx

```nginx
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name domain.com www.domain.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";
    }
}
```

| Chỉ thị | Ý nghĩa |
|---|---|
| `listen 80` | Nginx lắng nghe ở port 80 (HTTP mặc định) |
| `server_name` | Server block này xử lý request có header `Host` khớp tên miền |
| `location /` | Áp dụng cho mọi đường dẫn bắt đầu bằng `/` (tức là tất cả) |
| `proxy_set_header Host $host` | Giữ nguyên tên miền gốc, nếu không app sẽ nhận `Host: 127.0.0.1:3000` |
| `X-Real-IP` / `X-Forwarded-For` | Truyền IP thật của client — nếu thiếu, app chỉ thấy IP `127.0.0.1` của Nginx |
| `X-Forwarded-Proto` | Cho app biết client dùng `http` hay `https` |
| `Upgrade` / `Connection` + `proxy_http_version 1.1` | Cho phép WebSocket đi qua (React dev server dùng cho hot reload) |

## 3. Giải thích `proxy_pass`

`proxy_pass` là chỉ thị cốt lõi của reverse proxy: nó bảo Nginx **chuyển tiếp request khớp với `location` này tới địa chỉ upstream** (`http://127.0.0.1:3000`), chờ response, rồi trả response đó lại cho client. Với client, mọi thứ như thể Nginx tự trả lời.

Lưu ý về **dấu `/` cuối URL** — đây là chỗ hay sai:

```nginx
location /api/ {
    proxy_pass http://127.0.0.1:8080;    # /api/users  →  http://127.0.0.1:8080/api/users  (giữ nguyên URI)
}
location /api/ {
    proxy_pass http://127.0.0.1:8080/;   # /api/users  →  http://127.0.0.1:8080/users      (cắt prefix /api/)
}
```

- Không có URI sau host:port → Nginx gửi **nguyên** URI gốc.
- Có URI (dù chỉ là `/`) → Nginx **thay** phần khớp với `location` bằng URI đó.

Ở bài này `location /` + `proxy_pass http://127.0.0.1:3000;` nên URI được giữ nguyên.

Mẹo: dùng `127.0.0.1` thay vì `localhost` — `localhost` có thể phân giải ra `::1` (IPv6) trong khi app chỉ lắng nghe IPv4, gây lỗi kết nối khó hiểu.

## 4. Bẫy: React ở port 3000 bị sập thì Nginx trả về gì?

### ➜ **`502 Bad Gateway`**

Nginx vẫn sống và nhận request bình thường, nhưng khi nó mở kết nối tới `127.0.0.1:3000` thì không có process nào lắng nghe → hệ điều hành trả về `Connection refused`. Nginx (đóng vai trò *gateway*) nhận được phản hồi không hợp lệ/không có phản hồi từ upstream, nên trả `502`.

Trong `error_log` sẽ thấy:

```
connect() failed (111: Connection refused) while connecting to upstream,
upstream: "http://127.0.0.1:3000/"
```

Phân biệt các mã dễ nhầm:

| Mã | Khi nào |
|---|---|
| **502 Bad Gateway** | App **chết / không lắng nghe** port → connection refused, hoặc app trả response hỏng |
| **504 Gateway Timeout** | App **vẫn sống nhưng treo/chậm**, không trả lời trong `proxy_read_timeout` (mặc định 60s) |
| 503 Service Unavailable | Nginx **không tự trả** khi app sập; chỉ xuất hiện khi bạn cấu hình (vd. `limit_req`, trang bảo trì) hoặc app tự trả |
| 500 Internal Server Error | Lỗi do **chính app** trả về, Nginx chỉ chuyển tiếp |

### Tự kiểm chứng

```bash
# App đang chạy
curl -I http://localhost          # HTTP/1.1 200 OK

# Tắt app (Ctrl+C / pm2 stop ...), rồi:
curl -I http://localhost          # HTTP/1.1 502 Bad Gateway
sudo tail -n 5 /var/log/nginx/ecommerce_error.log
```

---

## 5. Triển khai trên VPS (Ubuntu)

```bash
sudo apt update && sudo apt install -y nginx

# Đặt file cấu hình
sudo cp nginx/bai1/default /etc/nginx/sites-available/default
# (nếu dùng file riêng thì cần link sang sites-enabled)
# sudo ln -s /etc/nginx/sites-available/ecommerce /etc/nginx/sites-enabled/

sudo nginx -t                     # kiểm tra cú pháp — LUÔN chạy trước khi reload
sudo systemctl reload nginx       # nạp lại config, không làm rớt kết nối đang có

sudo ufw allow 'Nginx Full'       # mở 80 + 443
sudo ufw deny 3000                # không cho truy cập thẳng port của app
```

Các lệnh hay dùng:

```bash
sudo systemctl status nginx
sudo systemctl restart nginx
sudo tail -f /var/log/nginx/error.log
ss -tlnp | grep -E ':80|:3000'    # xem port nào đang lắng nghe
```

## 6. HTTPS với Let's Encrypt (Certbot)

Điều kiện: tên miền đã có bản ghi **DNS A** trỏ về IP VPS, port **80** mở ra Internet (Let's Encrypt xác thực qua HTTP-01), và `server_name` trong Nginx đã đúng tên miền.

```bash
# Cài certbot + plugin nginx
sudo apt install -y certbot python3-certbot-nginx

# (Khuyên dùng khi luyện tập) chạy thử với server staging — không bị dính rate limit
sudo certbot --nginx --staging -d domain.com -d www.domain.com

# Cấp chứng chỉ thật; certbot tự sửa file nginx và hỏi có redirect HTTP→HTTPS không
sudo certbot --nginx -d domain.com -d www.domain.com

# Chỉ lấy cert, KHÔNG cho certbot sửa nginx (tự viết config như default-ssl)
sudo certbot certonly --nginx -d domain.com -d www.domain.com
```

Quản lý chứng chỉ:

```bash
sudo certbot certificates                  # liệt kê cert, ngày hết hạn
sudo certbot renew --dry-run               # thử gia hạn (cert sống 90 ngày)
systemctl list-timers | grep certbot       # timer tự gia hạn ~2 lần/ngày
sudo certbot delete --cert-name domain.com # xoá cert
```

File chứng chỉ nằm ở `/etc/letsencrypt/live/domain.com/`:
- `fullchain.pem` → dùng cho `ssl_certificate`
- `privkey.pem` → dùng cho `ssl_certificate_key` (bí mật, không được commit lên git)

Cấu hình sau khi có HTTPS: xem [`nginx/bai1/default-ssl`](nginx/bai1/default-ssl).

```bash
curl -I http://domain.com      # 301 Moved Permanently → https://domain.com/
curl -I https://domain.com     # 200 OK
```

## 7. Ghi chú production

`npm start` chạy React **dev server** — chỉ dùng để học. Trên production nên `npm run build` rồi cho Nginx phục vụ thẳng file tĩnh, không cần process ở port 3000 nữa (nên cũng không còn rủi ro 502 do app sập):

```nginx
location / {
    root /var/www/ecommerce/build;
    try_files $uri /index.html;   # để React Router hoạt động khi F5 ở route con
}
```
