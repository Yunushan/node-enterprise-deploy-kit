<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{APP_NAME}}-healthcheck</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{HEALTHCHECK_SCRIPT}}</string>
    <string>{{HEALTHCHECK_CONFIG}}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>{{HEALTHCHECK_INTERVAL}}</integer>
  <key>UserName</key>
  <string>root</string>
  <key>GroupName</key>
  <string>wheel</string>
  <key>StandardOutPath</key>
  <string>{{LOG_DIR}}/healthcheck-launchd.out</string>
  <key>StandardErrorPath</key>
  <string>{{LOG_DIR}}/healthcheck-launchd.err</string>
</dict>
</plist>
