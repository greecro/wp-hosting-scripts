# DNS- & Mail-Setup pro Domain (Vorab-Checkliste)

Diese Records **vor** der Site-Installation setzen — DNS braucht Propagation-Vorlauf
und der Pre-Flight-Check von `install-wp.sh` prüft die DNS-Auflösung. Wenn DNS +
SES-DKIM bereits stehen, läuft der Install glatt durch und Mail funktioniert sofort.

Readiness prüfen: `bash check-dns.sh <domain> --ip <server-ip> --dkim <ses-token>`
(mehrere Domains: einfach hintereinander angeben).

## 1. DNS-Records (Cloudflare)

| Typ | Name | Wert | Proxy |
|---|---|---|---|
| A | `@` | Server-IP (Web-VM bzw. NPM-Eingang) | 🟠 orange (proxied) |
| A/CNAME | `www` | `@` bzw. Server-IP | 🟠 orange |
| TXT | `@` | `v=spf1 include:amazonses.com -all` | — |
| TXT | `_dmarc` | `v=DMARC1; p=quarantine; rua=mailto:dmarc@deine-domain.de` | — |
| CNAME ×3 | `<token>-1/-2/-3._domainkey` | aus AWS SES (DKIM) | ⚪ DNS-only (grau!) |

> ⚠️ **DKIM-CNAMEs müssen „DNS only" (graue Wolke)** sein — sonst bricht Cloudflare
> die CNAME-Auflösung und SES verifiziert nicht.

## 2. AWS SES pro Domain

1. SES-Konsole → **Verified identities → Create identity → Domain**
2. **Easy DKIM** wählen → SES zeigt **3 CNAME-Records** (Token-basiert)
3. Die 3 CNAMEs in Cloudflare eintragen (DNS-only)
4. **Custom MAIL FROM** optional (`mail.deine-domain.de`) → besseres DMARC-Alignment
5. Warten bis SES-Status **„Verified"** (Minuten bis Stunden)
6. **Sandbox verlassen** (Production Access beantragen) — sonst nur an verifizierte
   Empfänger zustellbar. Einmalig fürs ganze Konto, nicht pro Domain.

## 3. FluentSMTP je Site (nach Install)

`install-wp.sh` installiert FluentSMTP, aber die SES-Verbindung ist manuell:
- WP-Admin → FluentSMTP → **Amazon SES** Connection
- Region + SES Access Key/Secret (IAM-User mit `ses:SendRawEmail`)
- From-Email: `noreply@deine-domain.de` (Domain muss in SES verified sein)
- Test-Mail senden → muss ankommen (nicht im Spam)

## 4. Reihenfolge für viele Domains

1. **Jetzt zuerst:** alle A/www/SPF/DMARC + SES-Domains + DKIM-CNAMEs anlegen
   (reine Wartezeit, blockiert nichts).
2. SES Production Access beantragen (einmalig).
3. `bash check-dns.sh <domain> --ip <ip> --dkim <token>` → bis alles „bereit".
4. Erst dann `install-wp.sh` je Site — Pre-Flight-Check ist dann grün.
5. FluentSMTP-Connection je Shop nachziehen.

## Schnell-Check eines fertigen Setups
```bash
bash check-dns.sh best4software.de --ip 203.0.113.5 --dkim abc123token
```
Erwartung: A ✓, SPF ✓ (mit amazonses.com), DMARC ✓, DKIM 3/3 ✓.
