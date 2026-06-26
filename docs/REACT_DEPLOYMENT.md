# React Deployment

This kit supports React single-page applications as static build artifacts
served by the configured Node.js service behind IIS, Nginx, Apache, HAProxy, or
Traefik.

```text
Client
  -> reverse proxy
  -> Node.js service on 127.0.0.1:<APP_PORT>
  -> React static build root, usually build/ or dist/
```

React itself is not a long-running server process. The deployment must still
include the configured Node entrypoint, usually `server.js`, that serves the
static build and exposes the configured health endpoint.

## Artifact Layout

Create React App commonly outputs `build/index.html`; Vite commonly outputs
`dist/index.html`. Configure the matching document root:

```json
{
  "AppFramework": "reactjs",
  "ReactDocumentRoot": "build",
  "StartCommand": "server.js",
  "PackageExpectedFiles": [
    "server.js",
    "build/index.html"
  ]
}
```

```bash
APP_FRAMEWORK="reactjs"
REACT_DOCUMENT_ROOT="build"
START_SCRIPT="server.js"
PACKAGE_EXPECTED_FILES="server.js build/index.html"
```

For Vite, use `ReactDocumentRoot: "dist"` or
`REACT_DOCUMENT_ROOT="dist"` and set expected files to `dist/index.html`.

## Validate Packages

Windows package import supports `.zip`:

```powershell
.\scripts\windows\Test-ReactStaticPackage.ps1 `
  -PackagePath C:\deploy\example-react-app.zip `
  -ReactDocumentRoot build `
  -StripSingleTopLevelDirectory
```

Linux, macOS, and BSD package import supports `.zip`, `.tar.gz`, `.tgz`, and
`.tar`:

```bash
bash scripts/linux/validate-react-static-package.sh \
  --package-path /opt/releases/example-react-app.tar.gz \
  --react-document-root build \
  --strip-single-top-level
```

The import flow runs the matching React validator automatically when
`AppFramework` / `APP_FRAMEWORK` is `react`, `reactjs`, or `react-js`.
Validators reject unsafe archive paths, private files such as `.env` and key
material, symlinks or special file entries, and packages missing `index.html`
under the configured React document root.

## Preflight

Preflight validates React deployments before service or proxy changes are made:

- `AppFramework` / `APP_FRAMEWORK` is a React alias.
- `ReactDocumentRoot` / `REACT_DOCUMENT_ROOT` is a safe relative path.
- The live app directory contains the configured Node entrypoint.
- The React document root contains `index.html` when the app directory already
  exists.

Run:

```powershell
.\scripts\windows\Test-DeploymentPreflight.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
```

## Notes

Keep React runtime secrets out of the static build. Any value compiled into a
browser bundle is public. Use server-side APIs or target-local private config
for secrets, tokens, database URLs, and credentials.
