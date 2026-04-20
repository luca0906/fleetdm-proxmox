# FleetDM – Proxmox LXC Script

Automatisches Deployment von [FleetDM](https://fleetdm.com) als LXC-Container auf Proxmox VE.
Im Stil der [community-scripts/ProxmoxVE](https://github.com/community-scripts/ProxmoxVE) Collection.

---

## 🚀 Installation

Auf der **Proxmox Shell** ausführen:

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/DEIN-REPO/proxmox-fleetdm/main/ct/fleetdm.sh)"
```

> Oder lokal – Script herunterladen und direkt ausführen:
> ```bash
> chmod +x ct/fleetdm.sh && bash ct/fleetdm.sh
> ```

---

## 📦 Was wird installiert?

| Komponente | Version |
|---|---|
| **Debian** | 12 (Bookworm) |
| **Docker** | latest stable |
| **FleetDM** | latest |
| **MySQL** | 8.0 |
| **Redis** | 7 (Alpine) |

---

## ⚙️ Standard-Ressourcen

| | |
|---|---|
| CPU | 2 vCores |
| RAM | 2048 MiB |
| Disk | 10 GB |
| OS | Debian 12 |
| Privilegiert | Nein |

Im Advanced-Modus können alle Werte angepasst werden.

---

## 🌐 Zugriff

Nach der Installation ist FleetDM erreichbar unter:

```
https://<CONTAINER-IP>:1337
```

Beim ersten Aufruf wird ein Admin-Account erstellt.

---

## 🔐 Credentials & Sicherheit

- Alle Passwörter werden **zufällig generiert** und in `/opt/fleetdm/.env` gespeichert
- TLS-Zertifikat wird automatisch erstellt (selbst signiert, 10 Jahre)
- Für Produktion: echtes Zertifikat in `/opt/fleetdm/certs/` einlegen

---

## 🔄 Update

```bash
# Methode 1: Script erneut ausführen (erkennt bestehende Installation)
bash ct/fleetdm.sh

# Methode 2: Direkt im Container
update-fleetdm
```

---

## 📁 Dateistruktur im Container

```
/opt/fleetdm/
├── docker-compose.yml    # Compose-Konfiguration
├── .env                  # Zugangsdaten (chmod 600)
├── certs/
│   ├── fleet.crt         # TLS-Zertifikat
│   └── fleet.key         # TLS-Key
└── fleetdm_version.txt   # Installierte Version
```

---

## 🖥️ Unterstützte Geräte (nach FleetDM-Enrollment)

- ✅ macOS
- ✅ Windows
- ✅ Linux
- ✅ iOS / iPadOS
- ✅ ChromeOS (Monitoring)

---

## ⚠️ Hinweise

- **Apple-Geräte** (iOS/macOS): Benötigen zusätzlich ein Apple-APNS-Zertifikat
- **ChromeOS**: Vollständiges Enrollment erfordert weiterhin Google Admin Console
- Nicht für Produktionsumgebungen ohne echtes TLS-Zertifikat empfohlen
