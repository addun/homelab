# Homelab

Infrastructure-as-code for my home server: a collection of Docker Compose stacks, one per service, all fronted by a single reverse proxy.

## Architecture

- A single mini-PC runs everything as Docker Compose stacks (one folder per service/group).
- **Caddy** is the internal reverse proxy, routing each service under its own subdomain.
- **Authelia** provides shared authentication/SSO in front of sensitive services, with **CrowdSec** for intrusion detection/blocking at the proxy.
- **AdGuard Home** handles DNS/ad-blocking for the local network.
- Remote access to a couple of services from outside the home network is tunneled through a small VPS (SSH/WireGuard), which reverse-proxies back into the home network — the home server keeps no public inbound ports open directly.
- **Portainer** manages the Docker containers, and **WUD** (What's Up Docker) tracks available image updates.
- **Prometheus + Grafana + Loki + Alloy** cover metrics/logs, with **Uptime Kuma** and **Beszel** for uptime/system monitoring.

## Hardware

- **Host:** mini-PC, Intel N100 (4 cores)
- **GPU:** Intel UHD Graphics (integrated, used for hardware transcoding/ML where supported)
- **RAM:** 16 GB
- **Storage:** ~1 TB NVMe (system + services) + ~1 TB HDD/SSD (media/backups)
- **OS:** Ubuntu 24.04 LTS

## Services

| Category            | Services                                                                                        |
| ------------------- | ----------------------------------------------------------------------------------------------- |
| Media               | Jellyfin, Radarr, Sonarr, Prowlarr, FlareSolverr, Seerr, Huntarr, Transmission (over WireGuard) |
| Photos              | Immich                                                                                          |
| Smart Home          | Home Assistant, Zigbee2MQTT, ESPHome, ebusd (boiler/heating bus)                                |
| Networking/Security | Caddy, Authelia, CrowdSec, AdGuard Home                                                         |
| Monitoring          | Prometheus, Grafana, Loki, Alloy, Uptime Kuma, Beszel                                           |
| Ops                 | Portainer, WUD                                                                                  |
| Dashboard           | Homepage                                                                                        |
| Misc                | Postfix relay (email), Netflix household auto-validator                                         |

`.tools/` contains helper scripts for managing the VPS tunnel and bumping compose image tags.
