<p align="center">
  <img src="docs/assets/logo.svg" alt="Node Enterprise Deploy Kit logosu" width="140" />
</p>

<h1 align="center">Node Enterprise Deploy Kit</h1>

<p align="center">
  <strong>Node.js ve Next.js uygulamalarını Windows, Linux, BSD ve macOS üzerinde servis olarak çalıştırmak için üretim odaklı dağıtım kiti.</strong>
</p>

<p align="center">
  <a href="README.md">English</a> | <strong>Türkçe</strong>
</p>

<p align="center">
  <a href="LICENSE"><img alt="lisans" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="windows" src="https://img.shields.io/badge/windows-10%20%7C%2011%20%7C%20Server%202012--2025-0078D4.svg">
  <img alt="linux" src="https://img.shields.io/badge/linux-Ubuntu%20%7C%20Debian%20%7C%20RHEL%20%7C%20Fedora%20%7C%20Alpine-success.svg">
  <img alt="unix" src="https://img.shields.io/badge/unix-BSD%20%7C%20macOS-lightgrey.svg">
  <img alt="servis yöneticileri" src="https://img.shields.io/badge/service-WinSW%20%7C%20systemd%20%7C%20System%20V%20%7C%20OpenRC%20%7C%20launchd%20%7C%20bsdrc-orange.svg">
  <img alt="reverse proxy" src="https://img.shields.io/badge/proxy-IIS%20%7C%20Nginx%20%7C%20Apache%20%7C%20HAProxy%20%7C%20Traefik-6f42c1.svg">
</p>

> Varsayılan proje giriş noktası İngilizce `README.md` dosyasıdır. Bu dosya Türkçe destek dokümanıdır. Çelişki olursa İngilizce README ve `docs/` altındaki teknik dokümanlar kaynak kabul edilmelidir.

Next.js için ayrıntılı artifact ve servis kurulumu rehberi:
[docs/NEXTJS_DEPLOYMENT.md](docs/NEXTJS_DEPLOYMENT.md).

---

## Bu Proje Ne Çözer

Bir Node.js uygulamasını üretim sunucusunda terminalden `node server.js` ile başlatmak genelde yeterli değildir. Oturum kapandığında process ölebilir, sunucu yeniden başladığında uygulama ayağa kalkmayabilir, loglar dağınık kalabilir, port çakışmaları geç fark edilebilir ve reverse proxy ayarları kişiye bağlı manuel notlara dönüşebilir.

Bu kit, bu işleri tek bir tekrarlanabilir yapıya toplar:

```text
Client
  |
  v
Reverse proxy
  |
  v
Node.js / Next.js service
  |
  v
Logs, health checks, diagnostics, rollback
```

Temel hedefler:

- Uygulamayı servis yöneticisiyle çalıştırmak.
- Sunucu reboot sonrası otomatik başlatmayı güvenilir hale getirmek.
- Windows ve Unix benzeri sistemlerde benzer operasyon düzeni sağlamak.
- Reverse proxy, healthcheck, log, rollback ve diagnose akışlarını dokümante etmek.
- Örnek konfigürasyonlarda gizli bilgi taşımadan kurulum rehberi sunmak.

## Hızlı Başlangıç

Önce repoyu doğrulayın:

```powershell
.\scripts\dev\Test-Repository.ps1
```

Bu komut örnek konfigürasyonları, Markdown bağlantılarını, Ansible template ayraçlarını, render edilen token dosyalarını, Ansible syntax kontrolünü ve gizli bilgi taramasını çalıştırır.

Markdown bağlantılarını tek başına kontrol etmek için:

```powershell
.\scripts\dev\Test-DocsConsistency.ps1
```

Gizli bilgi taraması için:

```powershell
python .\scripts\dev\check-no-secrets.py
```

Gerçek sunuculardan toplanan Windows, Linux, macOS veya BSD status evidence
dosyalarını doğrulamak için:

```powershell
.\scripts\dev\Test-HostEvidence.ps1 -EvidencePath .\evidence -RequiredTargets windows-server,linux,macos,freebsd,openbsd,netbsd -RequireNextJs -RequireReverseProxy -RequireDeploymentIdentity
```

Belirli bir işletim sistemi ailesi için destek iddiasında bulunmadan önce
[Host Verification Evidence](docs/HOST_VERIFICATION.md) rehberindeki akışı
uygulayın.

Release readiness çıktısındaki `Ready: True` tek başına "tüm matris kanıtlandı"
anlamına gelmez. `supportScope.kind`, `supportScope.proofLevel`, seçili hedef
sayısı ve local-command-only evidence sayıları hangi kapsamın kanıtlandığını
gösterir; filtrelenmiş veya yalnızca üretim-runtime kapsamındaki sonuçlar tam
matris iddiası değildir.

## Windows Server Kurulumu

Windows tarafında önerilen model, uygulamayı WinSW tabanlı Windows servisi olarak çalıştırmak ve dış trafiği IIS üzerinden yönlendirmektir. Apache, HAProxy ve Traefik installer scriptleri bu kitte Linux/Unix tarafı içindir; Windows'ta bu proxy'ler kullanılacaksa proxy kurulumu ayrıca yönetilmelidir.

WinSW binary dosyası repoya gömülü değildir. Varsayılan Windows konfigürasyonunda
`AutoDownloadWinSW` açıktır; `tools\winsw\winsw-x64.exe` yoksa installer resmi
WinSW GitHub release adresinden pinlenmiş kararlı sürümü indirir. Sunucu
internete kapalıysa veya kurum içi onaylı artifact kullanmanız gerekiyorsa
`AutoDownloadWinSW` değerini `false` yapıp dosyayı manuel olarak
`tools\winsw\winsw-x64.exe` konumuna koyun.

1. Örnek konfigürasyonu kopyalayın:

```powershell
Copy-Item .\config\windows\app.config.example.json .\config\windows\app.config.json
```

2. Uygulamanıza göre değerleri düzenleyin:

```json
{
  "AppName": "ExampleNodeApp",
  "DisplayName": "Example Node App",
  "AppFramework": "nextjs",
  "NextjsDeploymentMode": "standalone",
  "NextjsRequireStaticAssets": true,
  "NextjsRequirePublicDirectory": false,
  "NextjsRequireServerActionsEncryptionKey": false,
  "NextjsRequireDeploymentId": false,
  "NextjsMinimumNodeVersion": "20.9.0",
  "AppDirectory": "C:\\apps\\ExampleNodeApp",
  "NodeExe": "C:\\Program Files\\nodejs\\node.exe",
  "StartCommand": "server.js",
  "Port": 3000,
  "BindAddress": "127.0.0.1",
  "HealthUrl": "http://127.0.0.1:3000/health",
  "ServiceManager": "winsw",
  "ReverseProxy": "iis"
}
```

3. Kurulumu yönetici PowerShell ile çalıştırın:

```powershell
.\install.ps1 -ConfigPath .\config\windows\app.config.json
```

Next.js standalone artifact oluşturmak için:

```powershell
.\scripts\windows\New-NextJsStandalonePackage.ps1 `
  -ProjectPath C:\src\example-node-app `
  -OutputPath C:\deploy\example-node-app.zip
.\scripts\windows\Test-NextJsStandalonePackage.ps1 `
  -PackagePath C:\deploy\example-node-app.zip
```

Tam uygulama `next-start` paketleri için Windows'ta `-Mode next-start`, Unix
validator tarafında `--mode next-start` kullanın. Package import, canlı
uygulama klasörünü değiştirmeden önce uygun Next.js validator'ını otomatik
çalıştırır. Unix benzeri sistemlerde `next-start` paket yardımcısı
`node_modules/.bin` komut shim'lerini pakete dahil etmez; paket yöneticileri bu
shim'leri çoğunlukla sembolik link olarak oluşturur. Servis Next'i doğrudan
`node_modules/next/dist/bin/next` üzerinden başlatır ve deploy arşivleri
sembolik link veya hardlink girdilerini bilinçli olarak reddeder.

Import veya manuel kopyalama sonrası canlı runtime klasörünü servis durumuna
dokunmadan kontrol etmek için:

```powershell
.\scripts\windows\Test-NextJsRuntimeLayout.ps1 `
  -ConfigPath .\config\windows\app.config.json
```

4. Servisi kontrol edin:

```powershell
.\status.ps1 -ConfigPath .\config\windows\app.config.json
.\status.ps1 -ConfigPath .\config\windows\app.config.json -MinimumUptimeHours 72 -JsonPath .\evidence\windows-status.json -FailOnCritical
Get-Service ExampleNodeApp
Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'" |
  Select-Object Name, State, StartMode, ProcessId, PathName
```

5. Beklenen portun servis process'i tarafından dinlendiğini doğrulayın:

```powershell
$svc = Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'"
Get-NetTCPConnection -State Listen |
  Where-Object OwningProcess -eq $svc.ProcessId |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

6. Logları kontrol edin:

```powershell
Get-Content C:\logs\ExampleNodeApp\ExampleNodeApp.wrapper.log -Tail 100
Get-Content C:\logs\ExampleNodeApp\ExampleNodeApp.err.log -Tail 100
```

Servis `Running`, `StartMode` otomatik ve port beklenen process ID altında dinliyorsa Windows tarafındaki temel kurulum sağlıklıdır.
`-JsonPath` çıktısını release kaydı olarak saklayabilirsiniz; verdict ve bulguları
yazar, environment değerlerini veya ham log içeriğini yazmaz. Uygulama package
import ile kurulduysa evidence içinde paket dosya adı, paket SHA256 değeri,
import zamanı ve Next.js build ID de güvenli manifest özeti olarak yer alır.

## Windows'ta start.bat ve server.js

Üretim yaklaşımında günlük çalışma terminalden elle `start.bat` çalıştırmak değildir. Doğru model şudur:

```text
Windows Service Control Manager
  -> WinSW service executable
  -> node.exe server.js
```

`start.bat` sadece yardımcı giriş noktası olarak kullanılabilir. Sunucu reboot olduğunda önemli olan şey Windows servisinin otomatik başlangıç modunda kayıtlı olmasıdır. Bunu kontrol etmek için:

```powershell
Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'" |
  Select-Object Name, State, StartMode, ProcessId, PathName
```

`StartMode` otomatik, `State` running ve `ProcessId` doluysa servis çalışıyordur. `server.js`, WinSW veya servis wrapper tarafından tetiklenen gerçek Node.js giriş dosyasıdır.

## Linux Kurulumu

Linux tarafında önerilen model systemd servisidir. Reverse proxy olarak Nginx, Apache HTTP Server, HAProxy veya Traefik kullanılabilir.

1. Örnek environment dosyasını kopyalayın:

```bash
cp config/linux/app.env.example config/linux/app.env
```

2. Değerleri düzenleyin:

```bash
APP_NAME="example-node-app"
APP_DISPLAY_NAME="Example Node App"
APP_RUNTIME="node"
APP_FRAMEWORK="nextjs"
NEXTJS_DEPLOYMENT_MODE="standalone"
NEXTJS_REQUIRE_STATIC_ASSETS="true"
NEXTJS_REQUIRE_PUBLIC_DIR="false"
NEXTJS_REQUIRE_SERVER_ACTIONS_ENCRYPTION_KEY="false"
NEXTJS_REQUIRE_DEPLOYMENT_ID="false"
NEXTJS_MINIMUM_NODE_VERSION="20.9.0"
SERVICE_USER="nodeapp"
SERVICE_GROUP="nodeapp"
APP_DIR="/opt/example-node-app"
START_SCRIPT="server.js"
NODE_ENV="production"
APP_PORT="3000"
BIND_ADDRESS="127.0.0.1"
SERVICE_MANAGER="systemd"
REVERSE_PROXY="nginx"
HEALTH_URL="http://127.0.0.1:3000/health"
HEALTHCHECK_STATE_DIR="/var/lib/node-enterprise-deploy-kit/example-node-app"
PUBLIC_PORT="443"
TLS_ENABLED="true"
PROXY_LISTEN_PORT="80"
FORWARDED_PROTO="https"
FORWARDED_PORT="443"
```

Unix benzeri Next.js servislerinde installer, yönetilen runtime `PORT`,
`APP_PORT`, `HOST` ve `HOSTNAME` değerlerini `APP_PORT` ve `BIND_ADDRESS`
üzerinden üretir. Böylece generated standalone server, reverse proxy'nin
hedeflediği aynı lokal adrese bind eder.

Windows Next.js servislerinde WinSW, NSSM ve PM2 installer'ları aynı yönetilen
runtime varsayılanlarını `Port`, `AppName` ve `BindAddress` üzerinden üretir.
PM2 sadece fallback seçeneğidir; canlı Windows Server dağıtımlarında WinSW
önerilir.

3. Dağıtım öncesi kontrol çalıştırın:

```bash
bash scripts/linux/test-deployment-preflight.sh config/linux/app.env
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./evidence/unix-status.json --fail-on-critical
```

4. Dağıtımı çalıştırın:

```bash
bash deploy.sh config/linux/app.env
```

Hazır build artifact kullanıyorsanız önce paketi import edebilirsiniz:

```bash
bash scripts/linux/package-nextjs-standalone.sh \
  --project-path /srv/src/example-node-app \
  --output-path /opt/releases/example-node-app.tar.gz
bash scripts/linux/validate-nextjs-standalone-package.sh \
  --package-path /opt/releases/example-node-app.tar.gz

PACKAGE_PATH="/opt/releases/example-node-app.tar.gz"
PACKAGE_EXPECTED_FILES="server.js .next/BUILD_ID .next/static"
bash deploy.sh config/linux/app.env
```

Import veya manuel kopyalama sonrası canlı runtime klasörünü kontrol etmek için:

```bash
bash scripts/linux/test-nextjs-runtime-layout.sh config/linux/app.env
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --fail-on-critical
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --json-output ./evidence/unix-nextjs-status.json --fail-on-critical
```

Windows tarafında import `.zip` destekler. Linux/Unix tarafında `.zip`,
`.tar.gz`, `.tgz` ve `.tar` desteklenir. `.rar` ve `.7z` bu ilk güvenli import
akışında bilinçli olarak desteklenmez; ek araç ve ek güvenlik kontrolü ister.

Canlı sunucuda her release yeni bir timestamp'li klasöre açılıyorsa mevcut
yayın klasörünü taşımayın. En yeni klasörü otomatik seçmek için:

```powershell
.\scripts\windows\Deploy-LatestRelease.ps1 `
  -ConfigPath .\config\windows\app.config.json `
  -ReleaseRoot C:\inetpub\wwwroot `
  -ReleasePattern "example-node-app-IIS-deploy-*" `
  -HealthPath "/" `
  -TakeOverPublicPortBinding `
  -SkipWinSWDownload
```

5. Servisi ve logları kontrol edin:

```bash
systemctl status example-node-app
journalctl -u example-node-app -n 100 --no-pager
```

6. Healthcheck scheduler kurun:

```bash
sudo bash scripts/linux/install-healthcheck-scheduler.sh config/linux/app.env
```

## Desteklenen Platformlar

Guncel Next.js surumleri Node.js `20.9.0` veya uzerini gerektirir. Bu nedenle
uretim onerisi, hedef isletim sisteminin Node.js runtime destek katmanina da
baglidir; legacy, deneysel veya topluluk paketiyle calisan hedefler icin
gercek host kaniti zorunludur ama bu hedefler uretim icin varsayilan onerilen
satirlar degildir.

| Platform | Durum | Önerilen servis yöneticisi | Not |
| --- | --- | --- | --- |
| Windows 10 / 11 | Desteklenir | WinSW / Windows Service | Geliştirme veya küçük servis senaryoları. |
| Windows Server 2012 / 2012 R2 | Deneysel Node runtime hedefi | WinSW / Windows Service | Node.js 20.x icin uretim onerisi degildir; Windows Server 2016+ tercih edilmelidir. |
| Windows Server 2016-2025 | Birinci sınıf destek | WinSW / Windows Service | IIS ve diğer proxy seçenekleriyle üretim kullanımı. |
| Ubuntu / Debian | Birinci sınıf destek | systemd | En yaygın Linux hedefleri. |
| RHEL / Rocky / AlmaLinux | Birinci sınıf destek | systemd | Kurumsal Linux dağıtımları. |
| Oracle Linux | Desteklenir | systemd | RHEL ailesi davranışı temel alınır. |
| CentOS / CentOS Stream | Desteklenir | systemd | Paket isimleri sürüme göre değişebilir. |
| Fedora | Desteklenir | systemd | Daha yeni paket sürümleriyle gelir. |
| Linux Mint | Desteklenir | systemd | Ubuntu/Debian ailesi davranışı temel alınır. |
| Alpine Linux | Deneysel Node runtime hedefi | OpenRC | Musl tabanli runtime icin gercek host kaniti gerekir. |
| FreeBSD | Deneysel Node runtime hedefi | rc.d | Yollar, paketler ve Node runtime host uzerinde dogrulanmalidir. |
| OpenBSD | Topluluk Node paketi hedefi | rcctl | OS paketi veya yerel Node runtime ile gercek host kaniti gerekir. |
| NetBSD | Topluluk Node paketi hedefi | rc.d | OS paketi veya yerel Node runtime ile gercek host kaniti gerekir. |
| macOS | Örnek destek | launchd | Lokal servis veya küçük ölçekli daemon senaryoları. |

## Reverse Proxy Desteği

Uygulama process'i genellikle `127.0.0.1:3000` gibi yerel bir porta bind edilir. Dış dünyadan gelen trafik reverse proxy tarafından karşılanır.

| Proxy | Ne zaman tercih edilir |
| --- | --- |
| IIS | Windows Server ve mevcut IIS altyapısı varsa. |
| Nginx | Linux üzerinde hafif, yaygın ve sade reverse proxy gerekiyorsa. |
| Apache HTTP Server | Apache kullanan ekiplerde `mod_proxy` ile entegrasyon gerekiyorsa. |
| HAProxy | Çoklu backend, healthcheck, load balancing ve L4/L7 yönlendirme gerekiyorsa. |
| Traefik | Docker, service discovery ve otomatik TLS senaryoları varsa. |

Windows otomasyonu IIS veya `none` destekler. Nginx, Apache, HAProxy ve Traefik otomasyonları Linux/Unix scriptleridir.

Linux/Unix proxy template'leri varsayılan olarak yerel HTTP listener üretir ve
uygulamaya public edge bilgisini `X-Forwarded-*` header'larıyla taşır.
TLS upstream load balancer üzerinde bitiyorsa `PROXY_LISTEN_PORT="80"`,
`FORWARDED_PROTO="https"` ve `FORWARDED_PORT="443"` modeli önerilir.

Temel akış:

```text
example.com
  -> reverse proxy
  -> 127.0.0.1:3000
  -> Node.js service
```

## Tomcat Desteği

Tomcat bir Java servlet container'dır. Node.js uygulamasını doğrudan çalıştırmak için doğru servis yöneticisi değildir. Bu projedeki Tomcat desteği, Node.js uygulamasının Tomcat ile aynı sunucuda veya aynı domain altında birlikte sunulduğu karma ortamlara yöneliktir.

Önerilen model:

```text
Reverse proxy
  -> /api veya /node: Node.js servisi
  -> /legacy veya /java: Tomcat servisi
```

Node.js process'i yine WinSW, systemd, OpenRC, launchd veya BSD servis yöneticisiyle yönetilmelidir.

## Dağıtım Modları

| Mod | Kullanım alanı | Araç |
| --- | --- | --- |
| Windows script kurulumu | Tek Windows Server veya manuel operasyon | `scripts/windows/install.ps1` |
| Linux script kurulumu | Tek Linux sunucusu veya manuel operasyon | `deploy.sh` |
| Ansible | Çoklu sunucu ve tekrarlanabilir dağıtım | `ansible/playbooks/site.yml` |
| Healthcheck scheduler | Servisin uzun süre sağlıklı kaldığını izlemek | `scripts/linux/install-healthcheck-scheduler.sh` |
| Status script | Servis, port, health ve Next.js layout sonucunu exit code ile doğrulamak | `scripts/linux/status-node-app.sh` |
| Diagnose script | Sorun anında güvenli özet almak | `scripts/linux/diagnose-node-app.sh` |

## Repository Düzeni

```text
.
├── ansible/                 # Windows ve Linux rolleri, inventory örnekleri
├── config/                  # Örnek JSON/YAML/env konfigürasyonları
├── docs/                    # Runbook, değişkenler, güvenlik ve sorun giderme
├── scripts/
│   ├── dev/                 # Repo doğrulama ve CI yardımcıları
│   ├── linux/               # Linux dağıtım, preflight, healthcheck, diagnose
│   └── windows/             # Windows servis ve proxy scriptleri
├── templates/               # Servis ve reverse proxy template dosyaları
├── README.md                # Varsayılan İngilizce README
└── README.tr.md             # Türkçe destek README dosyası
```

## Önerilen Healthcheck Tasarımı

Uygulamanız hızlı ve sade bir health endpoint sağlamalıdır:

```text
GET /health
```

Bu endpoint:

- HTTP 200 dönmelidir.
- Ağır veritabanı sorguları veya yavaş dış servisler yüzünden gecikmemelidir.
- Hassas bilgi döndürmemelidir.
- Reverse proxy ve servis healthcheck araçları tarafından erişilebilir olmalıdır.

Linux healthcheck scripti başarısızlık durumunu state dizininde tutar. Önerilen değer uygulamaya özel root-owned bir dizindir:

```bash
HEALTHCHECK_STATE_DIR="/var/lib/node-enterprise-deploy-kit/example-node-app"
```

## Günlerce Çalıştığını Nasıl Kontrol Edersiniz

Windows:

```powershell
Get-Service ExampleNodeApp
Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'" |
  Select-Object Name, State, StartMode, ProcessId
Get-Process -Id (Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'").ProcessId |
  Select-Object Id, StartTime, CPU, PM, WS, Path
```

Linux:

```bash
systemctl status example-node-app
systemctl show example-node-app --property=ActiveEnterTimestamp,NRestarts
journalctl -u example-node-app --since "7 days ago" --no-pager
curl -fsS http://127.0.0.1:3000/health
```

Takip edilmesi önerilen sinyaller:

- Servis uptime süresi.
- Son restart zamanı.
- Healthcheck başarısızlık sayısı.
- CPU ve bellek kullanımı.
- Proxy tarafında 4xx/5xx oranı.
- Uygulama loglarında tekrarlayan hata mesajları.

## Enterprise Varsayılanları

Bu proje şu varsayımları teşvik eder:

- Uygulama manuel terminal oturumuna bağlı kalmaz.
- Servis reboot sonrası otomatik ayağa kalkar.
- Uygulama dış ağa doğrudan açılmaz; reverse proxy arkasında kalır.
- Port çakışmaları ve eksik bağımlılıklar dağıtım öncesi yakalanır.
- Loglar merkezi ve tahmin edilebilir dizinlerde tutulur.
- Rollback ve uninstall yolları önceden düşünülür.
- Diagnose çıktıları varsayılan olarak hassas detayları gizler.
- Örnek konfigürasyonlarda gerçek secret bulunmaz.

## Güvenlik Notları

- Gerçek parola, token, connection string veya private key dosyalarını repoya koymayın.
- Örnek dosyalarda sadece placeholder değerler kullanın.
- Windows servis kullanıcısını mümkün olduğunca sınırlı yetkiyle çalıştırın.
- Linux servis kullanıcısını ayrı kullanıcı olarak tanımlayın.
- Uygulamayı public IP yerine mümkünse `127.0.0.1` üzerinde dinletin ve dış trafiği proxy ile alın.
- TLS, HSTS, güvenlik header'ları ve firewall kuralları ortam politikasına göre ayarlanmalıdır.
- Diagnose çıktısını paylaşmadan önce raw detayların hassas bilgi içermediğini kontrol edin.

Daha ayrıntılı güvenlik rehberi için [docs/HARDENING.md](docs/HARDENING.md) dosyasına bakın.

## Sorun Giderme

İlk bakılacak dokümanlar:

- [docs/RUNBOOK.md](docs/RUNBOOK.md)
- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- [docs/VARIABLES.md](docs/VARIABLES.md)
- [docs/BACKUP_RESTORE.md](docs/BACKUP_RESTORE.md)
- [docs/ANSIBLE.md](docs/ANSIBLE.md)
- [docs/RELEASE.md](docs/RELEASE.md)

Windows hızlı kontrol:

```powershell
Get-Service ExampleNodeApp
Get-CimInstance Win32_Service -Filter "Name='ExampleNodeApp'"
Get-Content C:\logs\ExampleNodeApp\ExampleNodeApp.wrapper.log -Tail 100
Get-Content C:\logs\ExampleNodeApp\ExampleNodeApp.err.log -Tail 100
```

Linux hızlı kontrol:

```bash
systemctl status example-node-app
journalctl -u example-node-app -n 100 --no-pager
sudo bash scripts/linux/status-node-app.sh config/linux/app.env --minimum-uptime-hours 72 --fail-on-critical
sudo bash scripts/linux/diagnose-node-app.sh config/linux/app.env
```

## Bu Projeyi Ne Zaman Kullanmalı

Bu kit özellikle şu durumlar için uygundur:

- Node.js veya Next.js uygulamasını Windows Server üzerinde servis olarak çalıştırmak istiyorsanız.
- Linux üzerinde systemd, OpenRC veya benzeri servis yöneticileriyle standart dağıtım yapmak istiyorsanız.
- Reverse proxy, healthcheck, log ve rollback akışlarını tek bir repoda toplamak istiyorsanız.
- Birden fazla sunucuya benzer dağıtımı tekrarlanabilir hale getirmek istiyorsanız.
- Operasyon ekibine anlaşılır runbook ve diagnose akışı vermek istiyorsanız.

Bu kit şu durumlarda doğrudan ana dağıtım aracı olmayabilir:

- Kubernetes, Nomad veya benzeri orchestrator tüm servis yönetimini zaten yapıyorsa.
- Uygulama tamamen serverless çalışıyorsa.
- Kurumunuzun zorunlu bir deployment platformu varsa.

## Lisans

Bu proje MIT lisansı ile dağıtılır. Ayrıntılar için [LICENSE](LICENSE) dosyasına bakın.
