# AGENTS.md — wp-hosting-scripts

Ausführungsschicht für das WordPress-Hosting auf PVE4: Proxmox-Template und VMs bauen,
DB- und Web-Stack einrichten, Sites installieren, klonen, migrieren, sichern.
Gemeinsame Instruktionsdatei für alle Agenten (Claude, Codex, Gemini);
`CLAUDE.md` ist ein Symlink hierauf. Öffentlich (MIT) — **nichts Internes hier hinein.**

- Scripts und Schritt-für-Schritt: [README.md](README.md), Details in `docs/`
- VM-Namen, IPs, VLAN, Gast-IDs: `~/Developer/KI/projects/privat/proxmox-cluster/inventory.md`
- Historie, Migrationsstand, erlebte Fallen: Wiki-Seite `project-wp-hosting`
- Management-seitige Orchestrierung darüber: Repo `homelab-provisioning`

## Projektregeln

1. **Öffentliches Repo.** Keine Domains von Kunden, keine IPs, keine Hostnamen, keine
   Lizenzschlüssel. Alles Umgebungsspezifische gehört in die `*.conf` (per `.gitignore`
   ausgenommen) — im Repo liegen nur die `*.conf.example`.
2. **`setup-db.conf` / `setup-web.conf` sind lokal und tragen Secrets.** Nie committen, nie
   ausgeben, auch nicht auszugsweise.
3. **Jedes Script bleibt idempotent und einzeln aufrufbar.** Der Ablauf ist eine Kette von
   Einzelschritten, kein Monolith — neue Funktionalität kommt als eigenes Script oder als
   Schritt in ein bestehendes, nicht als globaler Wrapper (der lebt in `homelab-provisioning`).
4. **Vor Änderungen an einem Script den Ist-Stand auf der Ziel-VM prüfen**, nicht aus dem
   README ableiten — die VMs sind über Wochen gewachsen.
5. **Kein `delete-wp.sh` / `db-cleanup.sh` gegen eine Produktivseite ohne Danys Ansage**,
   auch nicht „zum Aufräumen".

## Test

E2E gegen Wegwerf-VMs, nie gegen eine Live-Site. Nach jedem erfolgreichen Site-Deploy
gehört ein `spawn_task`-Chip mit der Domain als Titel angelegt.
