<VirtualHost *:80>
    ServerName {{PUBLIC_HOSTNAME}}

    ProxyPreserveHost On
    ProxyRequests Off
    ProxyTimeout 300

    RequestHeader set X-Forwarded-Proto "http"
    RequestHeader set X-Forwarded-Port "80"

    ErrorLog {{LOG_DIR}}/apache-error.log
    CustomLog {{LOG_DIR}}/apache-access.log combined

    RewriteEngine On
    RewriteCond %{HTTP:Upgrade} =websocket [NC]
    RewriteCond %{HTTP:Connection} upgrade [NC]
    RewriteRule /(.*) ws://127.0.0.1:{{APP_PORT}}/$1 [P,L]

    ProxyPass /health-proxy {{HEALTH_URL}}
    ProxyPassReverse /health-proxy {{HEALTH_URL}}

    ProxyPass / http://127.0.0.1:{{APP_PORT}}/
    ProxyPassReverse / http://127.0.0.1:{{APP_PORT}}/
</VirtualHost>
