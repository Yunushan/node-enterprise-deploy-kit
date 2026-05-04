<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{APP_NAME}}</string>
  <key>ProgramArguments</key>
  <array>
    <string>{{RUNNER_SCRIPT}}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>{{APP_DIR}}</string>
  <key>UserName</key>
  <string>{{SERVICE_USER}}</string>
  <key>GroupName</key>
  <string>{{SERVICE_GROUP}}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>{{LOG_DIR}}/stdout.log</string>
  <key>StandardErrorPath</key>
  <string>{{LOG_DIR}}/stderr.log</string>
</dict>
</plist>
