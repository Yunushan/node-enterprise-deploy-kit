global
    log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http
    option httplog
    option dontlognull
    timeout connect 30s
    timeout client 300s
    timeout server 300s

frontend {{HAPROXY_FRONTEND_NAME}}
    bind {{HAPROXY_BIND}}
    http-request set-header X-Forwarded-Proto http
    http-request set-header X-Forwarded-Port %[dst_port]
    default_backend {{HAPROXY_BACKEND_NAME}}

backend {{HAPROXY_BACKEND_NAME}}
    option httpchk GET {{HEALTHCHECK_PATH}}
    http-check expect status 200
    http-request set-header X-Forwarded-Host %[req.hdr(Host)]
    server {{APP_NAME}} 127.0.0.1:{{APP_PORT}} check
