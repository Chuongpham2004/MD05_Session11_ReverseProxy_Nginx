# Bài 3 — Bảo mật bằng HTTPS với Let's Encrypt

**Tình huống:** cài SSL miễn phí cho domain `api.my-ecommerce.com` để trình duyệt hiện ổ khoá, không bị đánh dấu "Not Secure", và được ưu tiên SEO.

> Domain trong đề là ví dụ. Để chứng minh bài làm chạy thật, mình triển khai trên VPS (Ubuntu, Nginx 1.18) với domain **`chuong.omniev.tech`**. Mọi lệnh bên dưới chỉ cần thay tên domain.

| File | Nội dung |
|---|---|
| [`api.my-ecommerce.com`](api.my-ecommerce.com) | Cấu hình HTTPS **viết tay** (port 80 redirect + port 443 SSL) |
| [`certbot-generated.conf`](certbot-generated.conf) | File **thực tế** do `certbot --nginx` sinh ra trên VPS, để đối chiếu |
| [`renew/certbot.timer`](renew/certbot.timer), [`renew/certbot.service`](renew/certbot.service) | Tự gia hạn bằng **systemd timer** |
| [`renew/certbot-renew.cron`](renew/certbot-renew.cron) | Tự gia hạn bằng **cronjob** |

---

## 0. Điều kiện trước khi chạy Certbot

Let's Encrypt cấp chứng chỉ qua cách xác thực **HTTP-01**: nó gọi vào `http://<domain>/.well-known/acme-challenge/<token>` để kiểm tra bạn thật sự kiểm soát domain. Vì vậy cần:

1. **DNS:** bản ghi `A` của domain trỏ về **IP public của VPS**.
   - Trên Cloudflare phải để **DNS only (mây xám)**. Nếu bật Proxied (mây cam), trình duyệt sẽ thấy chứng chỉ của Cloudflare chứ không phải của bạn, và dễ gặp lỗi redirect liên tục khi SSL mode là Flexible.
   - Cloudflare Tunnel cũng không dùng được cho mục đích này.
2. **Port 80 và 443** mở trên cả `ufw` lẫn firewall của nhà cung cấp VPS.
3. **Nginx** có `server` block với `server_name` khớp domain, để plugin `--nginx` biết sửa block nào.

```bash
dig +short api.my-ecommerce.com          # phải ra IP của VPS
sudo ufw allow 'Nginx Full'              # mở 80 + 443
sudo nginx -t
```

## 1. Cài đặt Certbot trên Ubuntu

```bash
sudo apt update
sudo apt install -y certbot python3-certbot-nginx
certbot --version
```

- `certbot`: công cụ chính, giao tiếp với Let's Encrypt qua giao thức ACME.
- `python3-certbot-nginx`: plugin cho phép certbot **đọc và tự sửa** cấu hình Nginx, đồng thời dùng chính Nginx để trả lời challenge (không cần tắt Nginx).

> Cách khác được Certbot khuyến nghị: `sudo snap install --classic certbot && sudo ln -s /snap/bin/certbot /usr/bin/certbot` (luôn có bản mới nhất). Với cách này timer có tên `snap.certbot.renew.timer`.

## 2. Cấp SSL và tự cấu hình Nginx

```bash
# (1) Chạy thử trên server staging: không lưu cert, không sửa file, không tính vào giới hạn số lần cấp
sudo certbot certonly --nginx --dry-run -d api.my-ecommerce.com

# (2) Cấp thật + tự sửa Nginx + tự thêm redirect HTTP -> HTTPS
sudo certbot --nginx --redirect -d api.my-ecommerce.com
#   thêm domain:          -d api.my-ecommerce.com -d www.my-ecommerce.com
#   chạy không hỏi đáp:   --non-interactive --agree-tos -m admin@my-ecommerce.com

# (3) Kiểm tra
sudo certbot certificates
```

Certbot làm 4 việc:
1. Tạm chèn `location /.well-known/acme-challenge/` vào Nginx.
2. Để Let's Encrypt gọi vào kiểm tra.
3. Lưu chứng chỉ vào `/etc/letsencrypt/live/<domain>/`.
4. Sửa file site (thêm `listen 443 ssl`, `ssl_certificate`...), thêm block redirect, rồi `reload` Nginx.

### Kết quả thực tế trên VPS

```text
$ sudo certbot certificates
  Certificate Name: chuong.omniev.tech
    Key Type: RSA
    Domains: chuong.omniev.tech
    Expiry Date: 2027-02-18 07:05:19+00:00 (VALID: 89 days)
    Certificate Path: /etc/letsencrypt/live/chuong.omniev.tech/fullchain.pem
    Private Key Path: /etc/letsencrypt/live/chuong.omniev.tech/privkey.pem
```

Kiểm tra từ máy bên ngoài:

```text
$ curl -I http://chuong.omniev.tech/abc?x=1
HTTP/1.1 301 Moved Permanently
Location: https://chuong.omniev.tech/abc?x=1       ← giữ nguyên path + query

$ curl -I https://chuong.omniev.tech               ← không cần -k: cert hợp lệ
HTTP/1.1 200 OK

$ openssl s_client -connect chuong.omniev.tech:443 | openssl x509 -noout -subject -issuer -dates
subject=CN=chuong.omniev.tech
issuer=C=US, O=Let's Encrypt, CN=YR1
notBefore=Nov 20 07:05:20 2026 GMT
notAfter=Feb 18 07:05:19 2027 GMT                  ← đúng 90 ngày

TLSv1.2  ECDHE-RSA-AES256-GCM-SHA384    ✅
TLSv1.3  TLS_AES_256_GCM_SHA384         ✅
```

File Nginx do certbot sửa: xem [`certbot-generated.conf`](certbot-generated.conf). Các dòng có `# managed by Certbot` là do certbot tự thêm.

## 3. Cấu hình HTTPS viết tay (port 443)

Khi muốn tự kiểm soát file cấu hình, chỉ dùng certbot để **lấy chứng chỉ**:

```bash
sudo certbot certonly --nginx -d api.my-ecommerce.com
```

Sau đó tự viết cấu hình ([file đầy đủ](api.my-ecommerce.com)):

```nginx
# Port 80: chỉ redirect sang HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name api.my-ecommerce.com;

    location ^~ /.well-known/acme-challenge/ {   # cho Let's Encrypt xác thực, KHÔNG redirect
        root /var/www/certbot;
    }
    location / {
        return 301 https://$host$request_uri;
    }
}

# Port 443: HTTPS
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name api.my-ecommerce.com;

    ssl_certificate     /etc/letsencrypt/live/api.my-ecommerce.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.my-ecommerce.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

### Trỏ tới `ssl_certificate` và `ssl_certificate_key`

Certbot lưu mọi thứ trong `/etc/letsencrypt/live/<domain>/`:

| File | Dùng cho | Ghi chú |
|---|---|---|
| `fullchain.pem` | **`ssl_certificate`** | Chứng chỉ domain **cộng** chứng chỉ trung gian (intermediate) của Let's Encrypt. Phải dùng file này |
| `privkey.pem` | **`ssl_certificate_key`** | Khoá bí mật, chỉ root đọc được. **Không bao giờ commit hay chia sẻ** |
| `cert.pem` | ✗ | Chỉ có chứng chỉ domain, thiếu intermediate nên một số client (Android, curl, Java) sẽ báo không tin cậy |
| `chain.pem` | `ssl_trusted_certificate` | Chỉ có intermediate, dùng cho OCSP stapling |

Các file trong `live/` thực chất là **symlink** trỏ sang `archive/<domain>/cert1.pem`, `cert2.pem`... Khi gia hạn, certbot chỉ đổi đích của symlink. Vì vậy **cấu hình Nginx không bao giờ phải sửa**, chỉ cần `reload`.

### Giải thích các phần quan trọng

| Chỉ thị | Ý nghĩa |
|---|---|
| `listen 443 ssl http2` | Lắng nghe HTTPS. Viết `http2` trong `listen` để tương thích Nginx 1.18; từ Nginx ≥ 1.25.1 dùng `http2 on;` |
| `return 301 https://$host$request_uri` | Redirect **vĩnh viễn**, giữ nguyên path và query. Dùng 301 (không phải 302) để Google chuyển điểm SEO sang bản HTTPS |
| `location /.well-known/acme-challenge/` | Đường cho Let's Encrypt xác thực. Phải truy cập được bằng **HTTP thuần**, không bị redirect |
| `ssl_protocols TLSv1.2 TLSv1.3` | Tắt TLS 1.0/1.1 đã lỗi thời |
| `Strict-Transport-Security` (HSTS) | Trình duyệt nhớ "luôn dùng HTTPS" trong 1 năm, chặn tấn công hạ cấp xuống HTTP (SSL stripping) |
| `X-Forwarded-Proto $scheme` | Báo backend biết client đang dùng `https`, tránh backend tự redirect sang HTTP gây vòng lặp |

> Certbot dùng `include /etc/letsencrypt/options-ssl-nginx.conf;` thay cho khối `ssl_protocols / ssl_ciphers / ssl_session_*`. **Chọn một trong hai cách**: dùng cả hai thì Nginx báo lỗi `directive is duplicate`.

Cấu hình này đã được kiểm tra bằng **Nginx 1.18.0**, cùng phiên bản với VPS (trên Docker, dùng chứng chỉ tự ký đặt đúng đường dẫn):

```text
nginx: configuration file /etc/nginx/nginx.conf test is successful
http://.../api/products?x=1                 → 301  Location: https://api.my-ecommerce.com/api/products?x=1
http://.../.well-known/acme-challenge/abc   → token-ok   (không bị redirect)
https://.../api/products                    → HTTP/2 200, strict-transport-security: max-age=31536000
backend nhận:  uri=/api/products  proto=https  host=api.my-ecommerce.com
```

## 4. Bẫy: Chứng chỉ chỉ có hạn 90 ngày, tự gia hạn thế nào?

**Vì sao chỉ 90 ngày?** Nếu khoá bị lộ thì thiệt hại bị giới hạn trong thời gian ngắn, đồng thời Let's Encrypt **buộc** mọi người phải tự động hoá thay vì gia hạn bằng tay.

**Nguyên tắc:** chạy `certbot renew` **2 lần mỗi ngày**. Lệnh này đọc mọi chứng chỉ trong `/etc/letsencrypt/renewal/*.conf` và **chỉ gia hạn khi còn dưới 30 ngày**. Các lần chạy khác không làm gì, nên chạy thường xuyên cũng an toàn.

### Cách 1: systemd timer (khuyên dùng, gói apt đã cài sẵn)

Trên VPS, `apt install certbot` đã tự tạo và bật timer:

```text
$ systemctl cat certbot.timer
# /lib/systemd/system/certbot.timer
[Unit]
Description=Run certbot twice daily

[Timer]
OnCalendar=*-*-* 00,12:00:00      ← 00:00 và 12:00 mỗi ngày
RandomizedDelaySec=43200          ← cộng ngẫu nhiên 0–12h, tránh hàng triệu server gọi Let's Encrypt cùng lúc
Persistent=true                   ← máy tắt đúng giờ chạy thì bật lên sẽ chạy bù

[Install]
WantedBy=timers.target
```

Nếu chưa có (ví dụ cài certbot bằng pip), tự tạo bằng [`renew/certbot.service`](renew/certbot.service) và [`renew/certbot.timer`](renew/certbot.timer):

```bash
sudo cp renew/certbot.service renew/certbot.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now certbot.timer

systemctl list-timers | grep certbot      # xem lần chạy tiếp theo
systemctl status certbot.timer
journalctl -u certbot.service             # log các lần chạy
```

### Cách 2: cronjob

```bash
sudo crontab -e
```

```cron
# phút giờ ngày tháng thứ   lệnh
17 3,15 * * * certbot renew --quiet --deploy-hook "systemctl reload nginx"
```

Hoặc đặt file vào `/etc/cron.d/` (định dạng có thêm cột `root`): xem [`renew/certbot-renew.cron`](renew/certbot-renew.cron).

| Thành phần | Ý nghĩa |
|---|---|
| `17 3,15 * * *` | 03:17 và 15:17 mỗi ngày. Tránh phút `0` để không chạy cùng lúc với số đông server |
| `--quiet` | Không in gì trừ khi lỗi (cron gửi mail khi có output) |
| `--deploy-hook "systemctl reload nginx"` | **Chỉ chạy khi gia hạn thành công**, để Nginx nạp chứng chỉ mới. Thiếu bước này thì Nginx vẫn dùng chứng chỉ cũ trong RAM cho tới khi hết hạn |

> Gói apt cũng cài `/etc/cron.d/certbot`, nhưng nó có điều kiện `test ... \! -d /run/systemd/system`, tức là **tự bỏ qua khi máy chạy systemd** để không chạy trùng với timer. Trên VPS đang dùng timer.

### Reload Nginx sau khi gia hạn

Với chứng chỉ cấp bằng `--nginx`, certbot ghi `installer = nginx` vào `/etc/letsencrypt/renewal/<domain>.conf` và **tự reload Nginx** sau khi gia hạn. Để chắc chắn với mọi cách cấp (`--webroot`, `--standalone`...), có thể đặt hook dùng chung:

```bash
sudo tee /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh > /dev/null <<'EOF'
#!/bin/sh
systemctl reload nginx
EOF
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

### Kiểm chứng gia hạn hoạt động: thực tế trên VPS

```text
$ sudo certbot renew --dry-run
Processing /etc/letsencrypt/renewal/chuong.omniev.tech.conf
Simulating renewal of an existing certificate for chuong.omniev.tech

Congratulations, all simulated renewals succeeded:
  /etc/letsencrypt/live/chuong.omniev.tech/fullchain.pem (success)
```

`--dry-run` mô phỏng toàn bộ quá trình gia hạn trên server staging mà không đổi chứng chỉ thật. Nên chạy lệnh này mỗi khi sửa Nginx hoặc firewall, vì gia hạn sẽ hỏng nếu port 80 bị chặn hoặc block `/.well-known/` bị redirect.

## 5. Tóm tắt lệnh

```bash
# Cài đặt
sudo apt update && sudo apt install -y certbot python3-certbot-nginx

# Cấp SSL + tự cấu hình Nginx + redirect HTTP→HTTPS
sudo certbot --nginx --redirect -d api.my-ecommerce.com

# Chỉ lấy cert (tự viết cấu hình)
sudo certbot certonly --nginx -d api.my-ecommerce.com
sudo nginx -t && sudo systemctl reload nginx

# Quản lý
sudo certbot certificates
sudo certbot renew --dry-run
systemctl list-timers | grep certbot

# Cron thay thế (sudo crontab -e)
17 3,15 * * * certbot renew --quiet --deploy-hook "systemctl reload nginx"
```
