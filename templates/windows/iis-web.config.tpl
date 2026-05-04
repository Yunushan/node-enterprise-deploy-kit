<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="HealthProxyToNode" stopProcessing="true">
          <match url="^{{HEALTH_PROXY_PATH}}$" />
          <action type="Rewrite" url="{{HEALTH_URL}}" />
        </rule>
        <rule name="ReverseProxyToNode" stopProcessing="true">
          <match url="(.*)" />
          <conditions logicalGrouping="MatchAll" />
{{FORWARDED_SERVER_VARIABLES}}
          <action type="Rewrite" url="http://127.0.0.1:{{APP_PORT}}/{R:1}" />
        </rule>
      </rules>
    </rewrite>
    <httpErrors errorMode="DetailedLocalOnly" />
  </system.webServer>
</configuration>
