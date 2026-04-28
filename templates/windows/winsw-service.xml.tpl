<service>
  <id>{{APP_NAME}}</id>
  <name>{{DISPLAY_NAME}}</name>
  <description>{{DESCRIPTION}}</description>
  <executable>{{NODE_EXE}}</executable>
  <arguments>{{START_COMMAND}} {{NODE_ARGUMENTS}}</arguments>
  <workingdirectory>{{APP_DIRECTORY}}</workingdirectory>
  {{ENVIRONMENT_BLOCK}}
  <logpath>{{LOG_DIRECTORY}}</logpath>
  <log mode="roll-by-size">
    <sizeThreshold>10485760</sizeThreshold>
    <keepFiles>10</keepFiles>
  </log>
  <onfailure action="restart" delay="10 sec"/>
  <onfailure action="restart" delay="30 sec"/>
  <onfailure action="restart" delay="60 sec"/>
  <stoptimeout>30 sec</stoptimeout>
</service>
