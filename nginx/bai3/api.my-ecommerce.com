# /etc/nginx/sites-available/api.my-ecommerce.com
# Bài 3 - HTTPS viết TAY (không dùng certbot sửa file), tương thích Nginx >= 1.18
#
# Lấy chứng chỉ nhưng KHÔNG cho certbot đụng vào file này:
#   sudo certbot certonly --nginx -d api.my-ecommerce.com
# Kích hoạt:
#   sudo ln -s /etc/nginx/sites-available/api.my-ecommerce.com /etc/nginx/sites-enabled/
#   sudo nginx -t && sudo systemctl reload nginx

# ---------------------------------------------------------------
# 1) Port 80: chỉ để redirect sang HTTPS (+ cho Let's Encrypt xác thực)
# ---------------------------------------------------------------
server {
    listen 80;
    listen [::]:80;
    server_name api.my-ecommerce.com;

    # HTTP-01 challenge phải truy cập được qua HTTP thuần, KHÔNG redirect.
    # (Plugin --nginx tự chèn tạm khi renew; block này cần nếu dùng --webroot -w /var/www/certbot)
    location ^~ /.well-known/acme-challenge/ {
        root /var/www/certbot;
        default_type "text/plain";
    }

    # Mọi request khác -> 301 sang HTTPS, giữ nguyên path + query string
    location / {
        return 301 https://$host$request_uri;
    }
}

# ---------------------------------------------------------------
# 2) Port 443: HTTPS -> reverse proxy tới API Gateway
# ---------------------------------------------------------------
server {
    listen 443 ssl http2;          # Nginx >= 1.25.1 có thể viết: listen 443 ssl; + http2 on;
    listen [::]:443 ssl http2;
    server_name api.my-ecommerce.com;

    # ==== Chứng chỉ Let's Encrypt (certbot lưu ở /etc/letsencrypt/live/<domain>/) ====
    # fullchain.pem = chứng chỉ của domain + chứng chỉ trung gian (intermediate) của Let's Encrypt.
    #                 Dùng cert.pem (thiếu intermediate) sẽ khiến một số client báo "untrusted".
    # privkey.pem   = khoá bí mật, chỉ root đọc được. TUYỆT ĐỐI không commit / chia sẻ.
    ssl_certificate     /etc/letsencrypt/live/api.my-ecommerce.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/api.my-ecommerce.com/privkey.pem;

    # ==== Tham số TLS ====
    # (Tương đương "include /etc/letsencrypt/options-ssl-nginx.conf;" mà certbot hay dùng.
    #  Chọn MỘT trong hai cách, nếu dùng cả hai Nginx sẽ báo lỗi "directive is duplicate".)
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # HSTS: bảo trình duyệt "từ nay chỉ dùng HTTPS với domain này" (1 năm).
    # Chỉ bật khi HTTPS đã chạy ổn định, vì trình duyệt sẽ nhớ và không cho quay lại HTTP.
    add_header Strict-Transport-Security "max-age=31536000" always;

    access_log /var/log/nginx/api_access.log;
    error_log  /var/log/nginx/api_error.log;

    location / {
        proxy_pass http://127.0.0.1:8080;     # API Gateway (bài 2)
        proxy_http_version 1.1;

        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;   # = "https" -> backend biết client dùng HTTPS
    }
}
