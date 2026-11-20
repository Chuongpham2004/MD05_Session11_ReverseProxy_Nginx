# Bài 2 — Định tuyến Request đến API Gateway (Path-based routing)

**Tình huống:** Frontend React chạy ở `localhost:3000`, Backend API Gateway chạy ở `localhost:8080`. Cần phục vụ cả hai trên **cùng 1 domain, port 80**.

```
                          ┌── /api/*  ──▶ 127.0.0.1:8080  (API Gateway)
Client ──▶ Nginx :80 ─────┤
                          └── còn lại ──▶ 127.0.0.1:3000  (React)
```

File cấu hình đầy đủ: [`default`](default)

---

## 1. Cấu hình Nginx (2 block `location`)

```nginx
server {
    listen 80 default_server;
    server_name domain.com www.domain.com;

    # Backend API Gateway
    location /api/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # React Frontend (mọi request còn lại)
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

### Nginx chọn `location` thế nào?

Với các **prefix location** (`/api/`, `/`), Nginx chọn cái **khớp dài nhất**, không phụ thuộc thứ tự viết trong file:

- `/api/products` khớp cả `/` và `/api/`, nhưng `/api/` dài hơn nên request đi tới **8080**.
- `/about` chỉ khớp `/`, nên request đi tới **3000**.

`location /` đóng vai trò "bắt tất cả" (catch-all) cho phần còn lại.

### Vì sao `proxy_pass http://127.0.0.1:8080;` không có `/` ở cuối?

Để **giữ nguyên** prefix `/api` khi gửi sang Gateway, vì Gateway thường định nghĩa route dạng `/api/...`:

| Cấu hình | `/api/products` được gửi tới |
|---|---|
| `proxy_pass http://127.0.0.1:8080;` | `http://127.0.0.1:8080/api/products` ✅ |
| `proxy_pass http://127.0.0.1:8080/;` | `http://127.0.0.1:8080/products` (bị cắt `/api/`) |

Chỉ dùng dạng có `/` khi backend **không** có prefix `/api` trong route.

## 2. Các Header quan trọng

| Header | Giá trị | Backend dùng để làm gì |
|---|---|---|
| `Host` | `$host`, tức `domain.com` | Biết client gõ tên miền nào: dùng để sinh URL tuyệt đối, redirect, CORS, multi-tenant. **Nếu thiếu**, Nginx mặc định gửi `Host: 127.0.0.1:8080` |
| `X-Real-IP` | `$remote_addr` | **Một** IP: địa chỉ client kết nối trực tiếp tới Nginx |
| `X-Forwarded-For` | `$proxy_add_x_forwarded_for` | **Chuỗi** IP qua từng proxy: `client, proxy1, proxy2...` |
| `X-Forwarded-Proto` | `$scheme` | Client dùng `http` hay `https`, tránh vòng lặp redirect khi có SSL |

`$proxy_add_x_forwarded_for` = giá trị `X-Forwarded-For` client gửi tới (nếu có) + `, $remote_addr`. Nhờ vậy, khi request đi qua nhiều tầng proxy (CDN → Load Balancer → Nginx), IP được **nối thêm** chứ không bị ghi đè.

## 3. Bẫy: Tại sao phải truyền `X-Forwarded-For`? Nếu không truyền, Backend thấy IP của ai?

### ➜ Backend chỉ thấy IP của **Nginx**, tức `127.0.0.1`

Reverse proxy tạo ra **hai kết nối TCP riêng biệt**:

```
Client (113.161.x.x) ──TCP #1──▶ Nginx ──TCP #2──▶ Backend :8080
                                  (127.0.0.1)
```

Backend chỉ thấy đầu bên kia của **kết nối #2**, và người mở kết nối đó là Nginx từ `127.0.0.1`. IP thật của client chỉ nằm ở kết nối #1 và **mất hẳn** khi sang kết nối #2, trừ khi Nginx chủ động ghi nó vào header.

Hậu quả nếu thiếu header:

- **Log / audit:** mọi request đều ghi `127.0.0.1`, không truy vết được ai đã đặt hàng hay ai tấn công.
- **Rate limit / chống brute-force:** toàn bộ người dùng chung một IP. Chặn một người là chặn **tất cả**, còn không chặn thì không chặn được ai.
- **Bảo mật:** whitelist / blacklist IP, phát hiện đăng nhập bất thường, khoá tài khoản theo IP đều vô dụng.
- **Nghiệp vụ:** không xác định được vị trí địa lý (GeoIP) để chọn ngôn ngữ, tiền tệ hay phí ship; không chống được gian lận khuyến mãi theo IP.

### Kết quả chạy thử thực tế (Docker, client có IP `172.23.0.4`)

```text
# CÓ truyền header
/api/products -> BACKEND :8080 | remote_addr=127.0.0.1 | Host=domain.com
                 | X-Real-IP=172.23.0.4 | X-Forwarded-For=172.23.0.4

# KHÔNG truyền header
/api/products -> BACKEND :8080 | remote_addr=127.0.0.1 | Host=127.0.0.1:8080
                 | X-Real-IP=      | X-Forwarded-For=

# Client đã đi qua 1 proxy khác trước đó (gửi sẵn X-Forwarded-For: 203.0.113.7)
/api/products -> ... | X-Forwarded-For=203.0.113.7, 172.23.0.4   ← được nối thêm, không ghi đè
```

`remote_addr` ở backend **luôn** là `127.0.0.1`, có header hay không cũng vậy. Header chính là cách duy nhất để IP thật đến được backend.

### Lưu ý bảo mật

Client có thể **tự giả mạo** `X-Forwarded-For`. Vì vậy backend:

1. Chỉ tin header này khi request đến từ proxy tin cậy (`127.0.0.1`), đồng thời chặn truy cập thẳng port 8080 từ bên ngoài (`ufw deny 8080`).
2. Lấy IP **gần nhất do proxy tin cậy thêm vào** (phần tử cuối chuỗi), hoặc dùng `X-Real-IP`, không lấy phần tử đầu tiên một cách mù quáng.

Với Spring Boot, cấu hình để `request.getRemoteAddr()` tự trả về IP thật của client:

```yaml
server:
  forward-headers-strategy: native   # Tomcat đọc X-Forwarded-For / X-Forwarded-Proto
```

## 4. Kết quả định tuyến

| Request | Đi tới | URI backend nhận |
|---|---|---|
| `/` | Frontend :3000 | `/` |
| `/about` | Frontend :3000 | `/about` |
| `/products` | Frontend :3000 | `/products` |
| `/api/products` | **Gateway :8080** | `/api/products` |
| `/api/orders/1?x=2` | **Gateway :8080** | `/api/orders/1?x=2` |
| `/apix` | Frontend :3000 | `/apix` (không khớp `/api/`) |
| `/api` (thiếu `/` cuối) | Nginx tự trả **301 → `/api/`** | — |

Hai dòng cuối là chỗ dễ sai: prefix `/api/` có dấu `/` nên `/apix` **không** bị đưa vào backend. Còn `/api` thì Nginx tự redirect 301, vì location kết thúc bằng `/` và có `proxy_pass`.

> Lưu ý: `/products` (trang của React) và `/api/products` (API trả JSON) là hai thứ khác nhau. Đây chính là lý do cần prefix `/api/` để tách bạch.

## 5. Triển khai và kiểm tra

```bash
sudo cp nginx/bai2/default /etc/nginx/sites-available/default
sudo nginx -t && sudo systemctl reload nginx

curl -i http://domain.com/              # → React
curl -i http://domain.com/api/products  # → API Gateway
```

Lợi ích phụ: Frontend gọi API bằng đường dẫn tương đối `fetch("/api/products")`, nên request **cùng origin** với trang web và **không cần cấu hình CORS**.
