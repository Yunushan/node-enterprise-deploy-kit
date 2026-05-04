http:
  routers:
    {{TRAEFIK_ROUTER_NAME}}:
      rule: "Host(`{{PUBLIC_HOSTNAME}}`)"
      entryPoints:
        - "{{TRAEFIK_ENTRYPOINT}}"
      service: "{{TRAEFIK_SERVICE_NAME}}"
  services:
    {{TRAEFIK_SERVICE_NAME}}:
      loadBalancer:
        passHostHeader: true
        healthCheck:
          path: "{{HEALTHCHECK_PATH}}"
          interval: "30s"
          timeout: "10s"
        servers:
          - url: "http://127.0.0.1:{{APP_PORT}}"
