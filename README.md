# WP Hosting Scripts

![Shell](https://img.shields.io/badge/shell-bash-121011?logo=gnu-bash&logoColor=white)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2024.04%20%2F%20Proxmox-E95420?logo=ubuntu&logoColor=white)
![WordPress](https://img.shields.io/badge/WordPress-WooCommerce-21759B?logo=wordpress&logoColor=white)
![License](https://img.shields.io/badge/license-MIT-blue)

Vollautomatisiertes **WordPress-** und **WooCommerce-Hosting** auf Ubuntu 24.04 LTS mit Proxmox.
Ein Satz Bash-Scripts richtet die komplette Infrastruktur ein und legt produktionsfertige Sites
in Minuten an. Jede Site bekommt einen **eigenen PHP-FPM-Pool, Systemuser, Datenbank, SFTP-Zugang
und Filebrowser-User** — sauber voneinander isoliert.

**Was es kann (Kurzfassung):**

- 🚀 **Eine VM-Vorlage, beliebig viele VMs** — Cloud-init-Template + Klon-Script für Proxmox
- 🌐 **Multi-Tenant-Web-Stack** — Nginx + FastCGI-Cache, PHP 8.3-FPM (pro Site eigener Pool), Redis Object Cache
- 🛍️ **WooCommerce-DE-ready** — rechtliche Seiten, Widerrufsrecht-Checkbox (§356/§312j BGB), 4 Payment-Gateways, PDF-Rechnungen
- 📊 **Tracking lean & DSGVO-konform** — Matomo (cookieless) + GA4 (Blogs via SEOPress, Shops via Pixel Manager; Measurement-ID setzt das Provisioning) + Pixel Manager (alle Ad-Plattformen + CAPI) + FAZ Consent. Kein GTM.
- 🔒 **Härtung out-of-the-box** — fail2ban, Rate-Limits, 2FA, Chroot-SFTP, Vhost-Hardening
- 💾 **Backups + Monitoring** — täglich Files & DB, 7-Tage-Mirror nach R2/S3/SFTP (optional age-verschlüsselt), Backup-Verify, Disk-/SSL-Alerts
- 🔁 **Reproduzierbar** — config-getriebener, non-interaktiver Modus für Ansible/Automation

## Inhaltsverzeichnis

- [Architektur](#architektur)
- [Scripts](#scripts)
- [Komplette Einrichtung — Schritt für Schritt](#komplette-einrichtung--schritt-für-schritt)
- [Was wird pro Site installiert](#was-wird-pro-site-installiert)
- [Monitoring & Alerts](#monitoring--alerts)
- [Backup](#backup)
- [Zugangsdaten](#zugangsdaten)
- [SFTP-Zugang pro Site](#sftp-zugang-pro-site)
- [Maintenance Mode](#maintenance-mode)
- [Voraussetzungen](#voraussetzungen)
- [Lizenz & Haftungsausschluss](#lizenz--haftungsausschluss)

## Architektur

```
Internet → Cloudflare → Caddy (SSL)
                                ↓ HTTP intern
        ┌──────────────────┬──────────────────┐
   Web-VM 1            Web-VM 2
 (WordPress)        (WooCommerce)
 Nginx + FastCGI    Nginx + FastCGI
 PHP 8.3-FPM 256M   PHP 8.3-FPM 512M
 Redis 256mb        Redis 512mb
 phpMyAdmin :8080   phpMyAdmin :8080
 Filebrowser :8090  Filebrowser :8090
 Netdata :19999     Netdata :19999
        └──────────────────┴──────────────────┘
                                ↓
                           Datenbank-VM (gemeinsam)
                              MariaDB
                           Netdata :19999
```

---

## Scripts

| Script | Ausführen auf | Zweck | Wann |
|---|---|---|---|
| `proxmox-create-template.sh` | Proxmox Host | Ubuntu 24.04 Cloud-init Template erstellen | Einmalig |
| `proxmox-create-vm.sh` | Proxmox Host | VM aus Template klonen & konfigurieren | Pro neue VM |
| `setup-db.sh` | Datenbank-VM | MariaDB, Backups, Monitoring, SSH-Hardening | Einmalig pro VM |
| `setup-web.sh` | Web-VM | Nginx, PHP, Redis, Tools, Monitoring, Backups | Einmalig pro VM |
| `install-wp.sh` | Web-VM | Neue WordPress- oder WooCommerce-Site anlegen | Pro neue Site |
| `delete-wp.sh` | Web-VM | Site vollständig entfernen | Bei Bedarf |
| `maintenance.sh` | Web-VM | Maintenance Mode ein-/ausschalten | Bei Bedarf |
| `update-wp.sh` | Web-VM | Manuelles CLI-Update einzelner Sites (mit Pre-Update-Snapshots) — Updates laufen manuell über dieses Script | Bei Bedarf |
| `list-sites.sh` | Web-VM | Alle Sites mit Status anzeigen | Bei Bedarf |
| `clone-site.sh` | Web-VM | Bestehende Site auf neue Domain klonen | Bei Bedarf |
| `migrate-wp.sh` | Web-VM | Externe WordPress-Site importieren | Bei Bedarf |
| `health-check.sh` | Web-VM | HTTP, PHP-FPM, DB aller Sites prüfen | Bei Bedarf |
| `reset-wp-admin.sh` | Web-VM | WordPress-Admin-Passwort zurücksetzen | Bei Bedarf |
| `rotate-keys.sh` | Web-VM | WordPress Security Keys rotieren | Alle 3–6 Monate |
| `restore-wp.sh` | Web-VM | WordPress-Site aus Backup wiederherstellen (mit HTTP-Test + Auto-Rollback) | Bei Bedarf |
| `backup-verify.sh` | Web-VM | Backup-Integrität prüfen (tar + age-Decrypt) | Wöchentlich (Cron) |
| `status.sh` | Web-VM | Dashboard: Sites, Disk, Load, SSL, Updates, Backups | Bei Bedarf |
| `tail-logs.sh` | Web-VM | Live-Logs einer Site (Nginx + PHP, farblich getrennt) | Bei Bedarf |
| `audit-plugins.sh` | Web-VM | Plugin-/Site-Audit: veraltete/inaktive Plugins, Admin-User, DB-Bloat | Monatlich |
| `sync-plugins.sh` | Web-VM | Private Plugin-ZIPs (SEOpress Pro etc.) aus Plugin-Bucket nachladen | Bei Plugin-Update |
| `db-backup.sh` | Datenbank-VM | Manueller MariaDB-Dump (Encryption + Remote-Mirror wie Auto-Cron, flock-protected) | Bei Bedarf |
| `db-cleanup.sh` | Web-VM | DB-Cleanup aller Sites: Transients, Papierkorb, Spam, Action Scheduler, OPTIMIZE TABLE | Wöchentlich (Cron So 05:00) |
| `setup-dashy-access.sh` | Web-VM | Zugang für ein Management-Dashboard: User `dashy`, restriktiver Key, ForceCommand-Gate (`dashy-gate`), Read-only-wp-cli-Wrapper (`dashy-wp`), Read-only-WooCommerce-Reports mit fester SQL (`dashy-wc`: Tagesumsatz, Status, Top-Produkte) und Site-Registry als JSON (`dashy-sites`) und Einzel-Update eines Plugins/Themes/des Cores mit Snapshot und Rollback, wahlweise mit DB-Import (`dashy-wp-update`, Snapshots unter `/var/backups/wp-hosting/<domain>/`); wird von `setup-web.sh` aufgerufen, wenn `DASHY_PUB_KEY`/`DASHY_FROM` gesetzt sind | Einmalig pro VM |
| `check-dns.sh` | beliebig | DNS-/Mail-Readiness prüfen (A, www, SPF, DMARC, SES-DKIM) — eine oder mehrere Domains | Vor Anlage |

---

## Komplette Einrichtung — Schritt für Schritt

> **📥 Scripts laden — zwei Wege.** Das Repo ist öffentlich, also ist kein Token/Login nötig.
>
> **Variante A — ganzes Repo klonen (empfohlen).** Auf jeder Maschine (Proxmox-Host, DB-VM, Web-VMs)
> einmal klonen, dann das jeweils benötigte Script ausführen:
> ```bash
> git clone https://github.com/greecro/wp-hosting-scripts.git
> cd wp-hosting-scripts
> ```
>
> **Variante B — einzelnes Script per `curl`.** Wenn `git` nicht installiert ist, lädst du nur das
> Script, das du gerade brauchst (die Befehle in jedem Schritt unten sind genau dafür da):
> ```bash
> curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/<script>.sh
> ```
> `-fsSL` bricht bei HTTP-Fehler **laut** ab (statt eine Fehlerseite zu speichern) und folgt Redirects.
> **Tipp:** nach dem Download `head -3 <script>` prüfen — muss mit `#!/bin/bash` beginnen.

### Schritt 1 — Template erstellen (Proxmox Host, einmalig)

```bash
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/proxmox-create-template.sh
bash proxmox-create-template.sh
```

Erstellt ein Ubuntu 24.04 Cloud-init Template (Standard-ID: 9000).

---

### Schritt 2 — VMs anlegen (Proxmox Host)

```bash
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/proxmox-create-vm.sh
bash proxmox-create-vm.sh   # Datenbank-VM
bash proxmox-create-vm.sh   # WordPress-VM
bash proxmox-create-vm.sh   # WooCommerce-VM
```

**Empfohlene Ressourcen:**

| VM | vCPU | RAM | Disk |
|---|---|---|---|
| Datenbank | 4 | 8 GB | 50 GB |
| WordPress | 2 | 4 GB | 30 GB |
| WooCommerce | 4 | 8 GB | 40 GB |

---

### Schritt 3 — Datenbank-VM einrichten

```bash
ssh ubuntu@<DB-VM-IP>
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/setup-db.sh
sudo bash setup-db.sh
```

Gibt DB-Admin-Zugangsdaten aus → für Schritt 4 notieren.

---

### Schritt 4 — Web-VMs einrichten (je VM wiederholen)

```bash
ssh ubuntu@<WEB-VM-IP>
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/setup-web.sh
sudo bash setup-web.sh
```

Fragt nach: VM-Typ, DB-VM-IP, DB-Zugangsdaten, Admin-E-Mail, Reverse-Proxy-IP (Caddy, Config-Key `NPM_IP`), Webhook-URL, SEOpress-Key, Remote-Backup-Ziel.

> **Reproduzierbar/non-interaktiv:** `setup-web.conf.example` kopieren, ausfüllen, dann
> `sudo bash setup-web.sh --config setup-web.conf`. Alle gesetzten Werte werden nicht
> mehr abgefragt — ideal für mehrere identische Web-VMs.

---

### Schritt 5 — Neue Site anlegen

> **Tipp:** DNS/Mail vorab prüfen mit `bash check-dns.sh <domain> --ip <ip> --dkim <ses-token>`
> (siehe [`docs/dns-mail-setup.md`](docs/dns-mail-setup.md)) — dann läuft der Pre-Flight-Check glatt durch.

```bash
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/install-wp.sh
sudo bash install-wp.sh
```

Fragt nach Domain und Typ (WordPress oder WooCommerce).
Danach Endpunkt provisionieren (`provision-endpoint.sh` im privaten `homelab-provisioning`): legt den Caddy-Block `https://domain.de → http://<WEB-VM-IP>:80` an, Cloudflare-DNS, cron-job.org-WP-Cron und Matomo.

> **SEOpress Pro:** Lade die ZIP einmal nach `r2:wp-plugins/seopress-pro.zip` hoch (oder welcher Plugin-Bucket bei Setup angegeben wurde). Beim ersten `setup-web.sh`-Lauf wird sie automatisch nach `/etc/wp-hosting/plugins/` synchronisiert. Spätere Updates: ZIP in R2 ersetzen, dann `sudo bash sync-plugins.sh`.

> **Tipp:** Bei abgebrochener Installation (z.B. Netzwerkfehler beim Plugin-Download) kann mit `sudo bash install-wp.sh --resume` ein sauberer Neustart erzwungen werden — Reste der vorherigen Installation werden vor dem Neuversuch automatisch entfernt.

> **Non-Interactive (für Automation/Ansible):**
> ```bash
> sudo bash install-wp.sh --domain example.com --type wordpress --yes
> sudo bash install-wp.sh --domain shop.de --type woocommerce --shop-name "Mein Shop" --admin-ip 1.2.3.4 --locale de_DE --yes
> ```
>
> `--locale` setzt die WordPress-Sprache (Standard `en_US`). Bei einer anderen Locale werden Core-Paket, WPLANG und die Sprachpakete aller wordpress.org-Plugins und -Themes installiert; WooCommerce wird erst nach dem Sprachpaket aktiviert, damit Warenkorb/Kasse/Mein Konto gleich in der Zielsprache angelegt werden.

---

### Schritt 6 — Site freischalten

Jede neue Site startet im **Maintenance Mode**:

```bash
curl -fsSLO https://raw.githubusercontent.com/greecro/wp-hosting-scripts/main/maintenance.sh
sudo bash maintenance.sh
```

→ Domain auswählen → freischalten → Site ist live.

---

## Was wird pro Site installiert

### Infrastruktur
- Eigener **Systemuser** (`wp_domain_com`) — PHP-FPM läuft unter diesem User
- Eigener **PHP-FPM-Pool** (dynamic für WP, static für WooCommerce, Slow Log ab 5s)
- Eigener **Nginx-Vhost** mit FastCGI-Cache und WebP-Serving
- Eigene **MariaDB-Datenbank** + User mit 32-stelligem Passwort
- **WP-Cron** extern via cron-job.org (GET `wp-cron.php` alle 5 Min, angelegt durch `provision-endpoint.sh` im privaten `homelab-provisioning`) — lokal `DISABLE_WP_CRON=true`, kein System-Cron, kein Frontend-Overhead
- **SFTP-Zugang** (Chroot-Jail, Passwort-Auth, landet direkt im Site-Verzeichnis)
- **Filebrowser-User** mit Scope auf das Site-Verzeichnis

### WordPress-Konfiguration
- Sprache: `en_US` (oder per `--locale`, z.B. `de_DE`), Zeitzone: `Europe/Berlin`, Datum: `Y-m-d H:i`
- Permalinks: `/%category%/%postname%/`
- Admin-Profil: Danijel Janzin, Spitzname Dany
- **Vhost-Härtung:** `xmlrpc.php`, `wp-config.php`, `readme.html`, PHP in `/uploads/` blockiert
- **Rate-Limit:** `wp-login.php` 1 r/s, Burst 3 (verhindert Brute-Force)
- **fail2ban-Jails:** wp-login Brute-Force (5 Versuche → 2h Ban), xmlrpc (2 Hits → 24h Ban)
- **OPcache-Status:** `https://<domain>/opcache-status` (Basic-Auth, gleiches Passwort wie phpMyAdmin)
- **PHP-FPM Pool-Status:** `https://<domain>/fpm-status` (Basic-Auth) zeigt aktive/idle Worker, Queue-Tiefe, peak children
- `DISALLOW_FILE_EDIT`, `FORCE_SSL_ADMIN`, `WP_DEBUG false`
- `WP_MEMORY_LIMIT 256M` / `WP_MAX_MEMORY_LIMIT 512M`
- `WP_POST_REVISIONS 5`, `EMPTY_TRASH_DAYS 7`, `AUTOSAVE_INTERVAL 120`
- `WP_CACHE true` (FastCGI + Redis Object Cache)
- X-Forwarded-Proto-Fix für HTTPS hinter Caddy

### Plugins (automatisch installiert & konfiguriert)
| Plugin | Zweck |
|---|---|
| Redis Object Cache | Object-Caching via Redis |
| Nginx Helper | FastCGI-Cache automatisch leeren |
| FluentSMTP | SMTP-E-Mail-Versand |
| Antispam Bee | Kommentar-Spam filtern |
| Simple Cloudflare Turnstile | Bot-Schutz für Formulare |
| WebP Converter for Media | Bilder bei Upload in WebP konvertieren |
| Two Factor | 2FA für WP-Admin |
| SEOpress + SEOpress Pro | SEO (Pro-ZIP + Lizenz-Key aus Config) |
| FAZ Cookie Manager | DSGVO-konformes Cookie Consent (GitHub) |
| Fluent Forms + Pro | Formulare (Free-Basis aus Repo + Pro-ZIP `fluentformpro.zip` aus Bucket) |

> **DB-Cleanup statt WP-Optimize:** Statt eines Plugins läuft `db-cleanup.sh` wöchentlich (So 05:00) per Cron über alle Sites — expired Transients, Papierkorb, Spam-Kommentare, Action-Scheduler-Cleanup (nur Woo-Shops), `wp db optimize`. Kein Frontend-Risiko, kein Cache-Konflikt.

### Bloat-Entfernung
- Plugins: `hello`, `akismet` gelöscht
- Themes: `twentytwentyone` bis `twentytwentyfour` gelöscht
- Inhalte: Hello-World-Post, Sample-Page, Standard-Kommentar gelöscht
- Dateien: `readme.html`, `license.txt`, `wp-config-sample.php` gelöscht
- Pingbacks + Trackbacks deaktiviert

### Must-Use Plugins (automatisch, nicht deaktivierbar)
| Datei | Funktion |
|---|---|
| `server-cache.php` | Site-Health-Cache-Warnung unterdrücken |
| `performance.php` | Heartbeat drosseln, Admin-Bar ausblenden, Author-Enumeration blockieren |
| `maintenance-mode.php` | Maintenance Mode (Flag-Datei `/wp-content/.maintenance-active`) |
| `eazyanalytics-pixel.php` | eazyanalytics-Tracking, sobald das Provisioning Pixel-Host + Key als Optionen gesetzt hat; vom Cookie-Consent (Kategorie `analytics`) bis zum Opt-in blockiert |
| `wph-tracking-ids.php` | AdSense Auto-Ads (Option `wph_adsense_pub_id`, Blogs) und Microsoft Clarity (Option `wph_clarity_project_id`); IDs setzt das Provisioning, FAZ blockt bis zum Opt-in (marketing/analytics). Shops bekommen Clarity über den Pixel Manager |
| `digital-checkout.php` | Widerrufsrecht-Checkbox bei WooCommerce (nur wenn downloadbare Produkte im Warenkorb) |

### WooCommerce (zusätzlich)
- Land: Deutschland, Währung: EUR
- Gastbestellung aktiviert, Checkout-Login-Erinnerung aktiviert
- Tracking, Marketplace-Vorschläge, Remote-Logging deaktiviert
- **Rechtliche Seiten** automatisch angelegt: Impressum, Datenschutzerklärung, AGB, Widerrufsbelehrung, Lieferung & Download
- AGB als Terms-Page, Datenschutz als Privacy-Page zugewiesen
- **E-Mail-Absender**: Shop-Name + `noreply@domain.de` + Footer mit Impressum-Link
- **Widerrufsrecht-Checkbox** beim Checkout (§ 356 Abs. 5 BGB) — nur bei digitalen Produkten, server-seitig validiert, Zustimmung mit Zeitstempel in Bestellung gespeichert
- **Button-Lösung** (§ 312j Abs. 3 BGB): Bestell-Button = „Zahlungspflichtig bestellen" (via `digital-checkout.php`, anpassbar)
- **AGB-Checkbox** am Checkout automatisch (WooCommerce zeigt sie, da AGB als Terms-Page gesetzt)
- **Kein WooCommerce Germanized** — Rechtskonformität wird nativ + per mu-Plugin gelöst. (Grundpreise/PAngV bei Digital-Produkten nicht pflichtig.)
- **Rechnungen via PDF Invoices & Packing Slips** (WP Overnight, wp.org-Free) — fortlaufende Nummern, PDF an den WooCommerce-Mails, Lieferscheine. Steuernummer/USt-ID je Shop in den Plugin-Einstellungen.
- **Payment Gateways** automatisch installiert + aktiviert (API-Keys je Shop manuell): Mollie, PayPal Payments, Stripe, Amazon Pay
- **FunnelKit Automations** (Free-Basis + Pro- und Connectors-ZIP `wp-marketing-automations-{pro,connectors}-v*.zip`, jeweils höchste Version; Pro wird nur bei gleicher Major-Version wie Free aktiviert) für E-Mail-Marketing (Warenkorbabbruch, Broadcasts)
- **Produktfeeds + Tracking (Lean-Architektur)** — ein Feed-Tool, ein Pixel-Tool:
  - **Product Feed Manager** (`best-woocommerce-feed`, Free) — erzeugt **alle** Kataloge/Feeds: Google (Content-API-Auto-Sync), Meta, TikTok, Pinterest, Bing Shopping, Idealo/Preisvergleiche. 24h-Schedule, Custom Fields, Varianten als Zeilen (Limit 200 Produkte/Feed → Pro-Lizenz manuell auf großen Shops)
  - **Pixel Manager** (`woocommerce-google-adwords-conversion-tracking-tag`, Free + `pixel-manager-pro.zip`) — **ein** Pixel-Tool für alle Ad-Plattformen (Google Ads, Meta, TikTok, Pinterest, Bing) + Server-Side CAPI. Ersetzt Google Tag Manager. Consent-gated über FAZ.
  - **Analytics = Matomo** via SEOpress-Modul (cookieless, consent-frei) **plus GA4** (seit 2026-10-15: Shops über den Pixel Manager, Blogs über SEOpress; die Measurement-ID trägt `provision-endpoint.sh` ein, FAZ blockt bis zum Opt-in). **Kein GTM.**
  - Keine offiziellen Channel-Plugins (redundant durch PMW+PFM), kein buggy Pinterest-Plugin.

> 📡 **Tracking/Consent-Details + Pro-Shop-Checkliste:** siehe [`docs/tracking-consent.md`](docs/tracking-consent.md)

> ⚠️ Rechtliche Texte müssen manuell befüllt werden. Empfehlung: [IT-Recht Kanzlei](https://www.it-recht-kanzlei.de) (Digital-Paket).
> 💳 Payment Gateways werden nur installiert — API-Keys/Modus konfigurierst du pro Shop in WooCommerce → Zahlungen.
> 📡 **Feed-/Pixel-/Consent-Setup je Shop:** im PFM-GUI je Plattform einen Feed anlegen (Template, Schedule „daily"); im Pixel Manager die Pixel-IDs + CAPI eintragen; in SEOpress Matomo aktivieren (cookieless); FAZ als einzige CMP (Consent Mode v2). Vollständige Schritt-für-Schritt-Checkliste: [`docs/tracking-consent.md`](docs/tracking-consent.md).

---

## Monitoring & Alerts

| Alert | Trigger | Kanal |
|---|---|---|
| 🟡 Disk Warnung | Partition > 80% belegt | Webhook (stündlich) |
| 🔴 Disk Kritisch | Partition > 90% belegt | Webhook (stündlich) |
| 🟢 Disk OK | Partition wieder < 80% | Webhook (Recovery) |
| 🔴 SSL Fehler | Zertifikat läuft in < 2 Tagen ab (Erneuerung fehlgeschlagen) | Webhook (alle 6h) |
| 🟢 SSL OK | Zertifikat nach Fehler erfolgreich erneuert | Webhook (Recovery) |
| 🔴 Backup defekt | tar-Integrität oder age-Decrypt fehlgeschlagen | Webhook (sonntags 04:00) |
| fail2ban | wp-login Brute-Force, xmlrpc, PHP in Uploads | IP-Ban (1h–24h) |

Alle Alerts nutzen state-tracking — kein Spam, nur bei Zustandsänderung.
Webhook-Format: **Uptime Kuma Push Monitor** (`GET ?status=up|down&msg=…`).

---

## Backup

### WordPress-Dateien (Web-VM)
- Täglich 02:00: `wp-content/` als `.tar.gz` nach `/var/backups/wp-files/`
- **7 Tage Aufbewahrung — lokal UND remote** (rclone sync = Mirror, Remote spiegelt Lokal)
- Remote-Backup ist **Pflicht** (Cloudflare R2, S3 oder SFTP — Setup fragt ab)
- Bandbreiten-Limit: 8 MB/s tagsüber (08–22), unbegrenzt nachts
- Optional: **age-Verschlüsselung** vor Upload (`.tar.gz.age`)

### Datenbank (DB-VM)
- Täglich 02:00: **Pro Datenbank** ein eigener komprimierter SQL-Dump nach `/var/backups/mysql/<dbname>_<datum>.sql.gz`
- **7 Tage Aufbewahrung — lokal UND remote** (rclone sync = Mirror)
- Remote-Backup ist **Pflicht** (R2/S3/SFTP)
- Bandbreiten-Limit wie bei Files-Backup
- Optional: **age-Verschlüsselung** vor Upload (`.sql.gz.age`)
- **Manuelle Backups (`db-backup.sh`)** verwenden denselben Code-Pfad: Encryption + Remote-Mirror identisch zum Auto-Cron, `flock`-Lock auf `/var/lock/mysql-backup.lock` verhindert parallele Läufe

### Bucket-Layout
Empfohlen: **4 Buckets** in derselben R2/S3-Storage:

```
r2:wp-backups/                          ← Web-Datei-Backups (7-Tage-Mirror)
├── <web-vm-1-hostname>/
└── <web-vm-2-hostname>/

r2:db-backups/                          ← Datenbank-Backups (7-Tage-Mirror)
└── <db-vm-hostname>/

r2:wp-plugins/                          ← private/Pro-Plugin-ZIPs
├── blocksy-companion-pro.zip
├── fluentformpro.zip                   ← Fluent Forms Pro (alle Sites)
├── wp-marketing-automations-pro-v*.zip         ← FunnelKit Pro, E-Mail-Marketing (Woo)
├── wp-marketing-automations-connectors-v*.zip  ← FunnelKit Connectors (Woo)
├── pixel-manager-pro.zip               ← alle Ad-Pixel + Server-Side CAPI (Woo)
└── seopress-pro.zip

r2:wp-themes/                           ← private/Pro-Theme-ZIPs
├── blocksy.zip                         ← Parent-Theme
└── blocksy-child.zip                   ← Child-Theme (für Anpassungen)
```

**Warum 4 Buckets:** Backups haben kurze Retention (7-Tage-Mirror), Plugin/Theme-ZIPs
haben dauerhafte Aufbewahrung. Trennung erleichtert Lifecycle-Rules und
verhindert versehentliches Löschen durch Backup-Sync.

Bei der Setup-Abfrage gibst du alle drei Bucket-Namen einmal ein. ZIPs werden
beim Setup automatisch heruntergeladen:
- Plugins → `/etc/wp-hosting/plugins/`
- Themes → `/etc/wp-hosting/themes/`

**Welche Plugins/Themes werden pro Site-Typ aktiviert:**

| Plugin/Theme | Blog (wordpress) | Shop (woocommerce) |
|---|:---:|:---:|
| Blocksy + Child Theme | ✓ | ✓ |
| Blocksy Companion Pro | ✓ | ✓ |
| SEOpress Pro | ✓ | ✓ |
| Redis Object Cache, FluentSMTP, Two Factor, Nginx Helper | ✓ | ✓ |
| WebP Converter, Antispam Bee, Turnstile, FAZ Cookie Manager | ✓ | ✓ |
| Fluent Forms + Pro (Formulare) | ✓ | ✓ |
| **PDF Invoices & Packing Slips** (Rechnungen, Free) | — | ✓ |
| **FunnelKit Automations** (E-Mail-Marketing) | — | ✓ |
| **Payment Gateways** (Mollie, PayPal, Stripe, Amazon Pay) | — | ✓ |
| **Product Feed Manager** (Free, alle Feeds: Google/Meta/TikTok/Pinterest/Bing/Idealo) | — | ✓ |
| **Pixel Manager** (Free + Pro-ZIP, alle Ad-Pixel + CAPI, ersetzt GTM) | — | ✓ |
| WooCommerce | — | ✓ |

**Plugin-/Theme-Updates:** Nach Upload einer neuen ZIP-Version in den jeweiligen Bucket:
```bash
sudo bash sync-plugins.sh             # Plugins UND Themes synchronisieren
sudo bash sync-plugins.sh --plugins   # nur Plugins
sudo bash sync-plugins.sh --themes    # nur Themes
sudo bash sync-plugins.sh --list      # Inventar (lokal + remote)
```
Bestehende Sites müssen danach manuell mit `wp plugin install ... --force` aktualisiert werden.

### Backup-Verifikation
- Wöchentlich (Sonntag 04:00): `backup-verify.sh` prüft tar-Integrität, age-Entschlüsselbarkeit und SQL-Inhalt
- Webhook-Alert bei beschädigten Backups
- Alle Backup-Crons mit `flock` geschützt (kein paralleler Lauf bei langlaufenden Backups)

### Pre-Update-Snapshots
- Vor jedem WordPress-Update wird automatisch ein Schnell-Snapshot (Files + DB) angelegt
- Speicherort: `/var/backups/wp-pre-update/<domain>_<timestamp>.{tar.gz,sql.gz}`
- Retention: 5 letzte Snapshots pro Site
- Manueller Restore: `sudo bash restore-wp.sh` → SQL-/Tar-Datei aus diesem Verzeichnis wählen

---

## Zugangsdaten

| Datei | Inhalt |
|---|---|
| `/etc/wp-hosting/config` | VM-Typ, DB-Zugangsdaten, Webhook-URL, SEOpress-Key (Web-VM) |
| `/etc/wp-hosting/db-credentials.txt` | DB-Admin-Zugangsdaten (DB-VM) |
| `/etc/wp-hosting/db-backup.conf` | rclone-Remote-Ziel — geteilt von Auto-Cron + `db-backup.sh` (DB-VM) |
| `/etc/wp-hosting/sites/<domain>.txt` | WP-Admin, DB, Filebrowser, SFTP pro Site |
| `/etc/wp-hosting/deleted/<domain>.<datum>.txt` | Archivierte Zugangsdaten gelöschter Sites |

---

## SFTP-Zugang pro Site

```
Host:     <Web-VM-IP>
Port:     22
User:     wp_domain_com
Passwort: <aus /etc/wp-hosting/sites/domain.txt>
Pfad:     /site  (entspricht /var/www/domain.com)
```

Chroot-Jail — kein Zugriff auf andere Sites möglich.

---

## Maintenance Mode

```bash
sudo bash maintenance.sh
```

- Zeigt alle Sites mit Status `[LIVE]` oder `[MAINTENANCE]`
- Besucher sehen eine "Coming Soon"-Platzhalterseite (HTTP 200, dunkles Design,
  kein WordPress-Branding) statt der unfertigen Installation — inkl. Matomo-Tracking,
  sobald die Site-ID gesetzt ist
- wp-login.php bleibt immer erreichbar; der Uptime-Monitor sieht HTTP 200 schon
  vor dem echten Go-Live
- Admins können sich einloggen und normal arbeiten
- Neue Sites starten automatisch im Maintenance Mode

---

## Voraussetzungen

- Proxmox VE 8.x
- Caddy (SSL-Terminierung)
- Cloudflare (empfohlen, für Real-IP-Header)
- VMs können sich gegenseitig per IP erreichen
- Für Webhooks: Uptime Kuma Push Monitor URL (`https://…/api/push/<key>`)

---

## Lizenz & Haftungsausschluss

Veröffentlicht unter der **MIT-Lizenz** — siehe [`LICENSE`](LICENSE). Nutzung auf eigene Verantwortung.

> ⚠️ **Hinweis:** Diese Scripts richten Server produktiv ein, ändern Firewall-/Nginx-/DB-Konfiguration
> und legen Cronjobs an. Vor dem Einsatz auf Produktivsystemen **auf einer Wegwerf-VM testen**.
> Die im Repo enthaltenen IPs (`192.168.1.x`) sind Platzhalter-Defaults und werden bei der Einrichtung
> abgefragt — keine echten Hosts. Pro/Premium-Plugin-ZIPs (SEOpress Pro, Blocksy Pro, Wow-Suite,
> Pixel Manager Pro etc.) sind **nicht** Teil des Repos; sie werden zur Laufzeit aus einem privaten
> Object-Storage-Bucket nachgeladen und erfordern eigene Lizenzen.
