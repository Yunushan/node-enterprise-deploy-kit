server {
    listen 80;
    server_name {{PUBLIC_HOSTNAME}};
    access_log {{LOG_DIR}}/nginx-access.log;
    error_log  {{LOG_DIR}}/nginx-error.log;
    location / {
        proxy_pass http://127.0.0.1:{{APP_PORT}};
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_read_timeout 300;
        proxy_connect_timeout 30;
        proxy_send_timeout 300;
    }
    location /health-proxy {
        proxy_pass {{HEALTH_URL}};
        access_log off;
    }
}
