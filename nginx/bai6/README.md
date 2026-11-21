# Bài 6 — Load Balancing và Subdomain Routing

**Tình huống:** Black Friday, một backend `8080` không chịu nổi tải → DevOps chạy thêm `8081`, `8082`. Ban giám đốc cần cổng quản trị riêng `admin.my-ecommerce.com`.

File cấu hình hoàn chỉnh: [`nginx.conf`](nginx.conf) (đặt tại `/etc/nginx/nginx.conf`)

```
                         ┌─ Host: admin.my-ecommerce.com ──▶ React Admin   127.0.0.1:4000
Client ──:80──▶ Nginx ───┤
                         └─ Host: my-ecommerce.com /api/ ──▶ upstream backend_api (Round Robin)
                                                              ├─ 127.0.0.1:8080
                                                              ├─ 127.0.0.1:8081
                                                              └─ 127.0.0.1:8082
```

---

## 1. Subdomain: `server_name`

Một Nginx, một IP, một port 80 vẫn phục vụ được nhiều website. Nginx so header **`Host`** của request với `server_name` của từng `server { }` để chọn block:

```nginx
server {
    listen 80;
    server_name admin.my-ecommerce.com;
    location / {
        proxy_pass http://react_admin;      # upstream -> 127.0.0.1:4000
        ...
    }
}

server {
    listen 80;
    server_name my-ecommerce.com www.my-ecommerce.com;
    location /api/ { proxy_pass http://backend_api; ... }
}
```

**DNS:** cần thêm bản ghi `A admin.my-ecommerce.com → IP VPS` (hoặc `CNAME admin → my-ecommerce.com`). Thiếu bản ghi này thì trình duyệt không tìm được tới Nginx.

**Host lạ thì sao?** Khi không có block nào khớp, Nginx dùng **block đầu tiên** của port đó. Ở đây block đầu tiên là trang admin, nghĩa là ai gõ thẳng IP cũng vào được trang quản trị. Vì vậy file có thêm một `default_server` trả `444` (đóng kết nối, không trả gì):

```nginx
server {
    listen 80 default_server;
    server_name _;
    return 444;
}
```

## 2. Load Balancing: `upstream`

```nginx
upstream backend_api {
    zone backend_api 64k;
    server 127.0.0.1:8080 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8081 max_fails=3 fail_timeout=30s;
    server 127.0.0.1:8082 max_fails=3 fail_timeout=30s;
    keepalive 64;
}
```

| Chỉ thị | Ý nghĩa |
|---|---|
| *(không ghi thuật toán)* | **Round Robin** là mặc định: 8080 → 8081 → 8082 → 8080… Các lựa chọn khác: `least_conn`, `ip_hash`, `hash $key`, hoặc `weight=` cho máy mạnh hơn |
| `max_fails=3 fail_timeout=30s` | Lỗi **3 lần trong 30 giây** thì server bị loại khỏi vòng **30 giây**. Hết 30 giây Nginx thử lại, thành công thì cho quay lại vòng |
| `zone backend_api 64k` | Cho **mọi worker dùng chung** bộ đếm Round Robin và bộ đếm lỗi (xem bẫy ở mục 5) |
| `keepalive 64` | Giữ sẵn kết nối tới backend. Cần thêm `proxy_http_version 1.1` và `proxy_set_header Connection ""` |

## 3. Failover: 8080 chết, khách không thấy lỗi

`max_fails` chỉ quyết định **các request sau** có còn gửi vào 8080 hay không. **Request đang xử lý** lúc 8080 chết được cứu bởi `proxy_next_upstream`:

```nginx
location /api/ {
    proxy_pass http://backend_api;

    proxy_next_upstream         error timeout http_502 http_503 http_504;
    proxy_next_upstream_tries   2;
    proxy_next_upstream_timeout 10s;
    proxy_connect_timeout       2s;
    ...
}
```

- `error timeout`: không kết nối được (port đóng, process crash) hoặc quá hạn thì Nginx **gửi lại ngay** request đó sang server kế tiếp.
- `http_502/503/504`: backend còn sống nhưng trả lỗi (ví dụ Spring đang tắt dở), Nginx cũng chuyển sang server khác.
- `proxy_connect_timeout 2s`: mặc định là **60 giây**. Khi server bị treo (không trả lời, cũng không từ chối kết nối), nếu không giảm số này thì mỗi khách phải chờ 60 giây mới được chuyển sang server khác.

> ⚠️ **POST/PATCH** (không idempotent) chỉ được gửi lại khi **chưa kịp gửi** tới backend, ví dụ lỗi kết nối. Nếu backend đã nhận đơn hàng rồi mới chết, Nginx **không** gửi lại để tránh tạo đơn hai lần. Có thể ép gửi lại bằng `non_idempotent`, nhưng **không nên** dùng cho API đặt hàng hay thanh toán.

## 4. Thực nghiệm

Chạy trên Docker `nginx:1.27-alpine` (12 worker). File [`test/mock-backends.conf`](test/mock-backends.conf) giả lập 3 backend và React Admin, mỗi backend trả về port của chính nó. Port 8080 được tách ra container riêng để tắt/bật mà không phải reload Nginx.

```bash
docker run -d --name bai6 -p 8086:80 \
  -v $PWD/nginx.conf:/etc/nginx/nginx.conf:ro \
  -v $PWD/test/mock-backends.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:1.27-alpine
docker exec bai6 nginx -t     # syntax is ok / test is successful
```

**Subdomain:**

```text
$ curl -i -H "Host: admin.my-ecommerce.com" localhost:8086/
HTTP/1.1 200 OK
<h1>React Admin (port 4000)</h1>

$ curl -H "Host: hacker.com" localhost:8086/
curl: (52) Empty reply from server        <- 444, host lạ bị đóng kết nối
```

**Round Robin + failover** (request liên tiếp vào `my-ecommerce.com/api/`):

```text
A) 3 server sống          200:8080 200:8081 200:8082 200:8080 200:8081 200:8082
B) tắt 8080 (12 request)  200:8081 200:8082 200:8081 200:8082 ... 200:8082   <- 12/12 đều 200
C) bật lại 8080 ngay      200:8081 200:8082 200:8081 200:8082 200:8081 200:8082   <- vẫn trong 30s bị loại
D) sau 30s                200:8081 200:8082 200:8080 200:8081 200:8082 200:8080   <- 8080 tự quay lại
```

Log (`$upstream_addr` / `$upstream_status`) cho thấy request rơi vào 8080 lúc nó chết được chuyển ngay sang 8082, và khách vẫn nhận `200`:

```text
"GET /api/orders" 200 upstream=127.0.0.1:8080, 127.0.0.1:8082 upstream_status=502, 200
```

Sau 3 lần lỗi, error log ghi:

```text
[error] connect() failed (111: Connection refused) while connecting to upstream, upstream: "http://127.0.0.1:8080/api/orders"
[warn]  upstream server temporarily disabled while connecting to upstream
```

## 5. ⚠️ Bẫy: Round Robin "không chia" vì nhiều worker

Lần chạy đầu (chưa có `zone`), **9/9 request đều vào 8080**:

```text
{"instance":"backend-8080"}  x9
```

**Nguyên nhân:** `worker_processes auto` tạo 12 worker. Mỗi worker có **bộ đếm Round Robin riêng**, và lượt đầu tiên của worker nào cũng là 8080. Mỗi lần `curl` mở kết nối mới lại rơi vào một worker khác, nên lần nào cũng là "lượt đầu", tức là 8080.

Khi có hàng nghìn request, tải vẫn chia gần đều. Nhưng thiếu `zone` vẫn gây hai hệ quả thật:
- **Bộ đếm lỗi cũng riêng từng worker**: worker nào cũng phải tự gặp đủ 3 lần lỗi mới bỏ 8080, nên số request bị chậm hoặc phải chuyển server tăng lên gấp nhiều lần.
- Khi lưu lượng thấp (giờ vắng, môi trường test), tải dồn hẳn về server đầu tiên.

**Cách sửa:** `zone backend_api 64k;` đưa trạng thái upstream vào shared memory dùng chung. Sau khi thêm, thứ tự là `8080 → 8081 → 8082 → 8080 …` đúng như mong đợi.

> Lưu ý: `nginx -s reload` tạo lại upstream nên **xoá trạng thái lỗi**. Server đang bị loại sẽ được thử lại ngay sau khi reload.

## 6. Mở rộng cho production

- **HTTPS**: thêm `listen 443 ssl` cho cả hai block và xin chứng chỉ cho cả ba tên: `certbot --nginx -d my-ecommerce.com -d www.my-ecommerce.com -d admin.my-ecommerce.com` (bài 3).
- **Bảo vệ trang admin**: `allow <IP công ty/VPN>; deny all;` (đã để sẵn dạng comment trong file), hoặc `auth_basic`.
- **Session**: Round Robin gửi các request của cùng một user tới các server khác nhau, nên backend phải **stateless** (JWT, hoặc session lưu trong Redis). Nếu không, user sẽ bị đăng xuất liên tục. `ip_hash` chỉ là cách chữa cháy.
- **Health check chủ động** (định kỳ gọi `/actuator/health`) chỉ có trên Nginx Plus. Bản miễn phí chỉ có kiểm tra thụ động (`max_fails`) như trên.
