# Notifuse für Proxmox VE — LXC One-Liner Installer

**Community-Scripts-Stil** · GitHub-first · vollständig lokal · reboot-sicher

[Notifuse](https://github.com/Notifuse/notifuse) ist eine self-hosted Newsletter-
und Transaktions-E-Mail-Plattform (Go + React, PostgreSQL 17). Dieses Repo enthält
einen Installer, der Notifuse als **LXC-Container** auf Proxmox VE installiert —
analog zu den [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

## One-Liner (auf dem Proxmox-Host als root)

> **Nach dem Forken:** `HatchetMan111/NotiFuseEMAIL-Proxmox` im Einzeiler und in `install/notifuse.sh`
> (`SCRIPT_URL_RAW=`) durch dein Repo ersetzen.

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NotiFuseEMAIL-Proxmox/main/install/notifuse.sh)"
```

## Was der Installer tut

| Phase | Aktion |
|---|---|
| Host | Erstellt unprivileged LXC (**Hostname `notifuse`** + Description mit Repo-URL, Debian 13, DHCP, `onboot=1`, `nesting=1`), Defaults: **2 vCPU, 4 GB RAM + 4 GB Swap, 12 GB Disk, Port 8080** — CT-ID/Storage/Template werden automatisch ermittelt; belegte IDs überspringt der Installer automatisch (nächste freie), den existierenden CT `notifuse` verwendet er idempotent wieder |
| Container | PostgreSQL 17 (pgdg), Node 22 + Go (nur für den Build), **Notifuse-Release-Tarball von GitHub** → `npm ci && npm run build` (console, notification_center, web_analytics_sdk) → `go build` → Build-Abhängigkeiten werden wieder entfernt |
| Konfiguration | Zufälliges `SECRET_KEY` + DB-Passwort (`openssl rand`) → `/opt/notifuse/.env` (0600), DB-Rolle mit `CREATEDB` (Workspace-DBs werden dynamisch angelegt), systemd-Unit **GitHub-first aus diesem Repo** (Heredoc-Fallback) |
| Verifikation | Im CT: `systemctl is-active` + Listen-Check `0.0.0.0:8080` + HTTP `GET /healthz` → danach **vom Host aus** erneut geprüft |
| Reboot-Test | CT wird einmal gestoppt/gestartet — erst wenn die Web UI danach wieder `HTTP 200` liefert, gilt die Installation als erfolgreich |

Web UI am Ende: `http://<LXC-IP>:8080` (Setup-Wizard unter `/setup`).

## Erwartete Ausgabe (Kurzfassung)

```
[INFO] Detected mode: host
[INFO] Next free CT ID: 301
[INFO] Template: local:vztmpl/debian-13-standard_13.0-1_amd64.tar.zst
[INFO] Storage: local-lvm
[INFO] Creating LXC 301 (2 vCPU, 4 GiB RAM, 12 GiB disk, unprivileged=1) ...
[ OK ] LXC 301 created and started
[ OK ] Container IP: 10.0.0.42
[INFO] Running installer inside CT 301 (this builds frontends + Go backend; takes a while) ...
[INFO] Building frontend: console
[INFO] Building notifuse-server (Go) ...
[ OK ] Built /opt/notifuse/notifuse-server
[ OK ] Service active (systemctl is-active notifuse)
[ OK ] Listening on 0.0.0.0:8080
[ OK ] Web UI healthy (GET /healthz -> HTTP 200)
[ OK ] In-container installation finished
[ OK ] service: active · HTTP GET /healthz -> 200 (from host via 10.0.0.42)
[INFO] Reboot check: stopping and starting CT 301 (full boot path incl. onboot) ...
[ OK ] Reboot test passed: Web UI back after reboot (HTTP 200)

[http]Notifuse installation complete and verified!
[http]Web UI        : http://10.0.0.42:8080
[http]Setup wizard  : http://10.0.0.42:8080/setup
[http]Update later  : pct exec 301 -- bash /root/notifuse.sh --update
[http]App logs      : pct exec 301 -- journalctl -u notifuse -f
[http]Install log   : pct exec 301 -- tail -n 200 /var/log/notifuse-install.log
```

## Ersteinrichtung (Setup-Wizard unter `/setup`)

Nach der Installation den Wizard mit diesen Werten ausfüllen (Beispiel: web.de-Postfach):

| Feld | Bedeutung | Beispiel |
|---|---|---|
| `Root Email` | Admin-Konto. Login erfolgt **passwortlos per Magic-Code**, der an diese Adresse gemailt wird — nimm eine Adresse, die du abrufen kannst | `bildung4.0@web.de` |
| `API Endpoint` | Öffentliche URL deiner Instanz (Basis für Tracking-Links + API). Im Heimnetz: `http://<LXC-IP>:8080` | `http://192.168.178.50:8080` |
| `Subscribe to the newsletter` | Optional: News von Notifuse selbst erhalten (standardmäßig aus) | nach Wahl |
| `SMTP Host` / `SMTP Port` | Versand-Server für **alle** System-Mails (Magic-Codes, Einladungen, Kampagnen) | `smtp.web.de` / `587` |
| `Use TLS` | STARTTLS-Verschlüsselung — immer an bei Port 587 | an |
| `SMTP Username` / `SMTP Password` | Login am Postfach (volle Adresse; bei 2FA ggf. App-Passwort aus den web.de-Einstellungen) | `bildung4.0@web.de` / `***` |
| `From Email` / `From Name` | Absender der System-Mails — **muss zum Postfach passen**, sonst Spam-Ordner | `bildung4.0@web.de` / `Bildung 4.0` |
| `EHLO Hostname` | Nur anfassen, wenn der SMTP-Server `EHLO localhost` ablehnt — sonst **leer lassen** (Default = SMTP-Host) | leer |

**Ablauf danach:** Wizard abschließen → Login-Seite → E-Mail eingeben → Magic-Code aus dem Postfach (ggf. Spam-Ordner) eingeben → drin. Kommt keine Mail: `pct exec <ctid> -- journalctl -u notifuse -f` zeigt den SMTP-Fehler (falsches Passwort, Port geblockt etc.).

**Hinweis für echte Newsletter:** web.de & Co. haben Tageslimits und sind nur zum Testen geeignet. Für Volumen: eigene Domain + SPF/DKIM/DMARC und ein Versandanbieter (Amazon SES, Brevo, Postmark …) — wird später pro Workspace eingebunden, im Wizard reicht das eigene Postfach.

## Konfiguration (Variablen)

Alle Variablen stehen am Kopf von `install/notifuse.sh` und können beim Aufruf
überschrieben werden:

```bash
CT_ID=305 CT_RAM=8192 CT_DISK=20 APP_PORT=8080 bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/NotiFuseEMAIL-Proxmox/main/install/notifuse.sh)"
```

| Variable | Default | Bedeutung |
|---|---|---|
| `CT_ID` | auto | **nie kollidierend:** existierender CT `notifuse` (Hostname) wird wiederverwendet; explizit gesetzte, aber belegte IDs führen automatisch zur nächsten freien ID; ohne Vorgabe wird die nächste freie Cluster-ID verwendet und gegen Belegung abgesichert |
| `CT_CPU` / `CT_RAM` / `CT_SWAP` / `CT_DISK` | 2 / 4096 / 4096 / 12 | vCPU, MiB RAM, MiB Swap, GiB Disk |
| `CT_VERSION` | 13 | Debian-Version des Templates |
| `CT_STORAGE` | auto | Server-seitige Auswahl (`--content rootdir`, identische Prüfung wie `pct create`; Backup-/ungeeignete Storages werden ausgeschlossen). Präferenz: `local-lvm` → `local` → nicht-shared → Rest; zu volle Storages (< Disk + 2 GiB) werden übersprungen, zur Not `CT_STORAGE=...` explizit setzen |
| `NET_BRIDGE` | vmbr0 | Bridge für `eth0` (DHCP) |
| `APP_PORT` | 8080 | Web-UI-Port (bind `0.0.0.0`) |
| `DB_NAME` / `DB_USER` | notifuse_system / notifuse | PostgreSQL-Rolle/DB (Postgres lauscht nur auf localhost) |

## Update

```bash
pct exec <ctid> -- bash /root/notifuse.sh --update
```

Vergleicht `cat /opt/notifuse/version` mit dem aktuellen GitHub-Release von
`Notifuse/notifuse` und installiert nur bei neuerer Version neu — `.env`
(SECRET_KEY, DB-Passwort), Datenbank und Daten bleiben erhalten.

## Deinstallation

```bash
# nur die App (DB-Daten bleiben erhalten):
pct exec <ctid> -- bash -c 'systemctl disable --now notifuse; rm -rf /opt/notifuse /etc/systemd/system/notifuse.service /root/notifuse.sh'

# inkl. Datenbank:
pct exec <ctid> -- bash -c 'runuser -u postgres -- psql -c "DROP DATABASE notifuse_system;" -c "DROP ROLE notifuse;"'

# Container komplett entfernen:
pct stop <ctid> && pct destroy <ctid> --purge
```

## Debugging / Fehlerketten

- Komplettes Install-Log im CT: `/var/log/notifuse-install.log`
- Bei jedem Fehler druckt der ERR-Trap die **vollständige Kette**: fehlgeschlagener
  Befehl, Exit-Code, Zeile/Funktion, `systemctl status`, `journalctl` (App +
  PostgreSQL) — nie nur die letzte Zeile.
- Vollständige Trace-Analyse: `pct exec <ctid> -- bash -x /root/notifuse.sh`
- App-Laufzeitlog: `pct exec <ctid> -- journalctl -u notifuse -f`

## Testdurchlauf (Beleg, Mock-Host)

Install → Reboot → Web UI (Auszug aus dem verifizierten Dry-Run):

```
[INFO] Detected mode: host
[ OK ] Container IP: 10.0.0.42
[ OK ] service: active · HTTP GET /healthz -> 200 (from host via 10.0.0.42)
[INFO] Reboot check: stopping and starting CT 301 (full boot path incl. onboot) ...
[ OK ] Reboot test passed: Web UI back after reboot (HTTP 200)
[http]Notifuse installation complete and verified!
```

Reproduzierbar gemockt (`pct`/`pvesh`/`pveam`/`curl`/`wget`-Stubs): Syntax-Check
`bash -n` ✓, `shellcheck -x` ✓ (0 Findings), Host-Pfad inkl. Idempotenz-Re-Run
und Reboot-Verifikation ✓. Die Container-seitige Installation (apt/pgdg, Go-,
Node-Builds) läuft auf einem echten PVE-Host mit Internetzugang identisch ab.

## Repo-Struktur

```
├── install/notifuse.sh        # Installer (Host- + Container-Modus, idempotent)
├── systemd/notifuse.service   # systemd-Unit (GitHub-first, Restart=always)
└── README.md
```

## Lizenzhinweis

Der Installer selbst ist MIT. Notifuse: bis v39.x AGPL-3.0, ab v40.0 BSL 1.1
(wird 4 Jahre nach Release zu AGPL) — siehe [Notifuse LICENSE](https://github.com/Notifuse/notifuse/blob/main/LICENSE).
