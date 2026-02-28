# HoneyStack

Lightweight, modular honeypot platform with built-in dashboards. Deploy honeypots and monitor attacker activity in under 5 minutes — on as little as 1GB of RAM.

Think of it as a mini [T-Pot](https://github.com/telekom-security/tpotce) that doesn't need 8GB+ of RAM.

## Architecture

```
                    ┌─────────────────────────────────────────┐
                    │              HoneyStack                  │
                    │                                         │
Internet ──► :22 ──┤──► iptables REDIRECT ──► Cowrie (:2222) │
             :23 ──┤──► iptables REDIRECT ──► Cowrie (:2223) │
                    │           │                              │
                    │           ▼ JSON logs                    │
                    │       Promtail ──► Loki ──► Grafana     │
                    │                              (:3000)    │
                    └─────────────────────────────────────────┘
                    Real SSH moved to :22222
```

**RAM usage: ~800MB** (Cowrie 150MB + Loki 300MB + Promtail 50MB + Grafana 200MB)

## Quick Start

```bash
git clone <this-repo> honeystack
cd honeystack
sudo ./install.sh
```

That's it. The installer handles everything:

1. Installs Docker (if needed)
2. Moves SSH to port 22222
3. Sets up iptables to redirect port 22/23 to Cowrie
4. Deploys Cowrie + Grafana + Loki + Promtail via Docker Compose
5. Provisions Grafana with pre-built dashboards

After install, open **http://your-ip:3000** (admin / honeystack).

## What You Get

### Dashboards

**HoneyStack Overview** — high-level view across all honeypots:
- Total events, login attempts, commands, sessions (stat panels)
- Events over time (stacked bar chart by honeypot)
- Top source IPs (table with gradient gauge)
- Live event stream

**Cowrie Honeypot** — deep dive into SSH/Telnet activity:
- Connection, login, command, download counts
- Login attempts timeline (success vs failed)
- Top usernames, passwords, source IPs (tables)
- Top commands executed by attackers
- Full event log stream

## Configuration

### `honeystack.conf`

```bash
ENABLED_HONEYPOTS="cowrie"   # Space-separated list of honeypot modules
SSH_PORT=22222               # Port for real SSH management access
GRAFANA_PORT=3000            # Grafana web UI port
```

### `.env`

Copied from `.env.example` on first install. Controls Docker service settings:

| Variable | Default | Description |
|---|---|---|
| `GRAFANA_ADMIN_PASSWORD` | `honeystack` | Grafana admin password |
| `GRAFANA_PORT` | `3000` | Grafana web UI port |
| `SSH_PORT` | `22222` | Real SSH port |
| `COWRIE_SSH_PORT` | `2222` | Cowrie SSH listen port |
| `COWRIE_TELNET_PORT` | `2223` | Cowrie Telnet listen port |
| `COWRIE_HOSTNAME` | `svr04` | Hostname shown to attackers |
| `LOKI_RETENTION` | `168h` | Log retention period (7 days) |
| `LOG_DIR` | `/var/log/honeypots` | Host log directory |

## Adding a New Honeypot Module

HoneyStack is designed to be modular. Each honeypot is a self-contained module under `honeypots/`.

To add a new honeypot (e.g., dionaea):

```
honeypots/dionaea/
├── docker-compose.dionaea.yml   # Docker service definition
├── dionaea.conf                 # Honeypot configuration
└── dashboard-dionaea.json       # Grafana dashboard (optional)
```

Then enable it:

```bash
# In honeystack.conf:
ENABLED_HONEYPOTS="cowrie dionaea"
```

And re-run the installer (or restart manually):

```bash
sudo ./install.sh
```

### Module Requirements

The `docker-compose.<name>.yml` file must:
- Use the `honeystack` network (define with `driver: bridge`, not `external: true`)
- Write logs to `${LOG_DIR}/<name>/` in JSON format
- Set memory limits under `deploy.resources.limits`

Promtail scrape configs can be added to `core/promtail/promtail-config.yml`.

## Management

```bash
# View all container status
cd /opt/honeystack && docker compose ps

# View live logs
cd /opt/honeystack && docker compose logs -f

# View specific service logs
cd /opt/honeystack && docker compose logs -f cowrie

# Stop everything
cd /opt/honeystack && docker compose down

# Start everything
cd /opt/honeystack && docker compose up -d

# Check RAM usage
docker stats --no-stream

# Uninstall completely
sudo ./uninstall.sh
```

## File Structure

```
honeystack/
├── install.sh                          # Single-command installer
├── uninstall.sh                        # Clean removal script
├── honeystack.conf                     # Module configuration
├── .env.example                        # Environment variable template
├── core/                               # Core infrastructure (always deployed)
│   ├── docker-compose.core.yml         # Grafana + Loki + Promtail
│   ├── grafana/
│   │   ├── grafana.ini                 # Grafana settings (low-memory tuned)
│   │   ├── provisioning/
│   │   │   ├── datasources/loki.yml    # Auto-provisioned Loki datasource
│   │   │   └── dashboards/dashboards.yml
│   │   └── dashboards/
│   │       └── honeypot-overview.json  # Overview dashboard
│   ├── loki/
│   │   └── loki-config.yml            # Loki config (low-memory tuned)
│   └── promtail/
│       └── promtail-config.yml        # Log scraping pipeline
└── honeypots/                          # Modular honeypot directory
    └── cowrie/
        ├── docker-compose.cowrie.yml   # Cowrie service definition
        ├── cowrie.cfg                  # Cowrie config overrides
        └── dashboard-cowrie.json       # Cowrie Grafana dashboard
```

## Requirements

- **OS**: Ubuntu 20.04+ or Debian 11+ (other distros may work)
- **RAM**: 1GB minimum, 2GB recommended
- **Disk**: 5GB+ (Docker images + log storage)
- **Network**: Root access, ability to modify iptables and SSH config

## Uninstalling

```bash
sudo ./uninstall.sh
```

The uninstaller will:
1. Stop and remove all containers
2. Remove iptables redirect rules
3. Restore SSH to port 22
4. Optionally remove data, logs, and Docker images

## License

MIT
