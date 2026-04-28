<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <system.webServer>
    <rewrite>
      <rules>
        <rule name="ReverseProxyToNode" stopProcessing="true">
          <match url="(.*)" />
          <conditions logicalGrouping="MatchAll" />
          <action type="Rewrite" url="http://127.0.0.1:{{APP_PORT}}/{R:1}" />
        </rule>
      </rules>
    </rewrite>
    <httpErrors errorMode="DetailedLocalOnly" />
  </system.webServer>
</configuration>
