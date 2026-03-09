# Managed by openclaw-dashboard-time-windowed-public-access
# Purpose: expose only /openclaw/ with BasicAuth + time-window gate

server {
  listen 80;
  listen [::]:80;
  server_name __DOMAIN__;

  location = /openclaw {
    return 301 https://$host/openclaw/;
  }

  location ^~ /openclaw/ {
    return 301 https://$host$request_uri;
  }

  location / {
    return 404;
  }
}

server {
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;
  server_name __DOMAIN__;

  ssl_certificate __SSL_CERT_PATH__;
  ssl_certificate_key __SSL_KEY_PATH__;

  location = /openclaw {
    return 301 /openclaw/;
  }

  location ^~ /openclaw/ {
    include __WINDOW_CONF_PATH__;

    auth_basic "Restricted OpenClaw Dashboard";
    auth_basic_user_file __BASIC_AUTH_FILE__;

    proxy_pass http://127.0.0.1:18789;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 120s;
    proxy_send_timeout 120s;
  }

  location / {
    return 404;
  }
}
