# CLAUDE.md

## Project Overview

HoneyStack is a lightweight, modular honeypot platform with built-in Grafana dashboards. It deploys honeypots (starting with Cowrie) and a Grafana+Loki observability stack via Docker Compose, all through a single `install.sh` script. Target: 1-2GB RAM (vs T-Pot's 8GB+).

## Architecture

```
Internet → :22 (iptables) → Cowrie (:2222) → JSON logs → Promtail → Loki → Grafana (:3000)
Real SSH moved to :22222
```

Stack: Cowrie (honeypot) + Promtail (log shipper) + Loki (log store) + Grafana (dashboards)

## Project Structure

- `install.sh` — Single-command installer (root required). Handles Docker, SSH, iptables, containers, dashboards.
- `uninstall.sh` — Clean teardown. Restores SSH, removes iptables rules, optionally removes data.
- `honeystack.conf` — Top-level config: which honeypots are enabled, SSH port, Grafana port.
- `.env.example` — Docker env template (copied to `.env` at install time). Never commit `.env`.
- `core/` — Always-deployed infrastructure (Grafana, Loki, Promtail).
  - `core/docker-compose.core.yml` — Core service definitions.
  - `core/grafana/` — Grafana config, provisioning (datasources, dashboard provider), dashboard JSON files.
  - `core/loki/loki-config.yml` — Loki config tuned for low memory (1MB chunks, 7-day retention).
  - `core/promtail/promtail-config.yml` — Log scraping pipeline with JSON parsing stages.
- `honeypots/` — Modular honeypot directory. Each honeypot is a subdirectory.
  - `honeypots/cowrie/` — Cowrie module: compose file, config, Grafana dashboard.

## Key Conventions

- **Bash scripts** use `set -euo pipefail`, colored log helpers (`log_info`, `log_warn`, `log_error`, `log_step`), and `###` section dividers.
- **Docker Compose** files use the `honeystack` network. All compose files (core and honeypot modules) define it with `driver: bridge`. They are merged into a single `docker-compose.yml` at install time, so do NOT use `external: true`.
- **Memory limits** are set on every container via `deploy.resources.limits.memory`.
- **Grafana dashboards** are JSON files provisioned via file-based provider. Dashboard UIDs follow `honeystack-<name>` pattern.
- **Loki datasource** UID is `loki` — all dashboard panels reference `{"type": "loki", "uid": "loki"}`.

## Adding a New Honeypot Module

Create `honeypots/<name>/` with:
1. `docker-compose.<name>.yml` — service on `honeystack` network (`driver: bridge`, NOT `external: true`), logs to `${LOG_DIR}/<name>/`, memory-limited
2. `<name>.cfg` or config — honeypot configuration
3. `dashboard-<name>.json` — optional Grafana dashboard (UID: `honeystack-<name>`)
4. Add a scrape job to `core/promtail/promtail-config.yml` for the new log path

Enable by adding the name to `ENABLED_HONEYPOTS` in `honeystack.conf`.

## Testing

No automated test suite. Validation is manual:
- Run `sudo ./install.sh` on Ubuntu/Debian with 1-2GB RAM
- SSH to port 22 should hit Cowrie; real SSH on port 22222
- Grafana at `:3000` with dashboards populated after a few login attempts
- `docker stats --no-stream` to verify RAM stays under budget
- `sudo ./uninstall.sh` to verify clean teardown

## Linting

Shell scripts should pass `shellcheck`. Run: `shellcheck install.sh uninstall.sh`
