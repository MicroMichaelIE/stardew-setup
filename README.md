# stardew-setup

Automate DuckDNS DDNS setup on a Raspberry Pi and then configure port forwarding on your Fritz!Box manually.

Quick start (fish-friendly):

```bash
# Clone/cd into this repo, then run one of:
env DUCKDNS_DOMAIN=myfarm DUCKDNS_TOKEN=xxxxxxxx bash ./scripts.sh
bash ./scripts.sh --domain myfarm --token xxxxxxxx
```

What it does:
- Installs curl (if apt is available)
- Copies `duck.sh` to `~/duckdns/` and makes it executable
- Adds an idempotent crontab entry to run every 5 minutes with your domain/token

Where to check logs:
- `~/duckdns/duck.log`

Fritz!Box port forwarding (manual):
- Open Fritz!Box UI > Internet > Permit Access > Port Sharing
- Add the required port(s) to your Raspberry Pi IP
- Use your DuckDNS domain (e.g., `myfarm.duckdns.org`) to connect from outside

## Deploy Stardew Valley Dedicated Server (JunimoServer)

On your Raspberry Pi:

```bash
# Minimal (fish-friendly):
env STEAM_USER=you STEAM_PASS=secret VNC_PASSWORD=changeme bash ./deploy_stardew.sh

# Or with flags:
bash ./deploy_stardew.sh \
  --steam-user you --steam-pass secret --vnc-password changeme \
  --steam-guard-code 12345 --game-port 24643 --vnc-port 8090 --dir ~/junimoserver
```

Notes:
- Installs Docker and compose if missing; enables amd64 emulation on ARM.
- Creates `docker-compose.override.yml` to force linux/amd64 and restart unless-stopped.
- Generates `.env` with your Steam/VNC credentials and ports.
- After start, open logs with `docker compose logs -f` inside the install dir.

Router port forwarding:
- Forward UDP GAME_PORT (default 24643) and TCP VNC_PORT (default 8090) to the Pi.
- Connect externally using your DuckDNS domain.
