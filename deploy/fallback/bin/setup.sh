#!/usr/bin/env bash
# One-shot, re-runnable setup of the Querido Diário fallback on a Debian/Ubuntu host.
#
# Run as root on the server:
#   QD_BIND_ADDR=<private/VPN IP> bash setup.sh
# or straight from a workstation:
#   ssh root@<server> "QD_BIND_ADDR=<private/VPN IP> bash -s" < deploy/fallback/bin/setup.sh
#
# What it does (each step is skipped when already done):
#   1. checks the host (OS, RAM, disk, CPU) against the minimum for the scoped option
#   2. installs Docker Engine + compose plugin from the distro if missing
#   3. clones/updates the fork into /opt/qd-fallback
#   4. sets vm.max_map_count for OpenSearch, creates the backup dir
#   5. writes .env with generated secrets (mode 600) and the S3 identity file
#   6. builds images, starts the services, creates the bucket and the DB tables
#   7. installs systemd timers: daily crawl+index (04:30) and backup (02:30)
# It does NOT start the backfill (see the last lines it prints).
set -euo pipefail

QD_REPO_URL="${QD_REPO_URL:-https://github.com/splitpierre/querido-diario-api.git}"
QD_REPO_REF="${QD_REPO_REF:-main}"
QD_ROOT="${QD_ROOT:-/opt/qd-fallback}"
QD_BACKUP_DIR="${QD_BACKUP_DIR:-/srv/qd-fallback/backups}"
MIN_RAM_GB=8
MIN_DISK_GB=150
MIN_CPUS=4

log() { printf '\n[setup %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '\n[setup] ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root (sudo -i, or ssh root@...)"
[ -n "${QD_BIND_ADDR:-}" ] || die "set QD_BIND_ADDR to the server's private/VPN IP, e.g. QD_BIND_ADDR=100.64.0.12"
case "$QD_BIND_ADDR" in 0.0.0.0|::|"*") die "QD_BIND_ADDR must be a private/VPN address, not $QD_BIND_ADDR";; esac
ip -o addr show | grep -qw "$QD_BIND_ADDR" || die "no local interface has address $QD_BIND_ADDR (is the VPN up?)"

log "1/7 host check"
. /etc/os-release
ram_gb=$(awk '/MemTotal/ {printf "%d", $2/1024/1024 + 0.5}' /proc/meminfo)
cpus=$(nproc)
mkdir -p "$QD_BACKUP_DIR"
disk_gb=$(df -BG --output=avail /var/lib "$QD_BACKUP_DIR" | awk 'NR>1 {gsub("G",""); print $1}' | sort -n | head -1)
echo "OS: $PRETTY_NAME | vCPU: $cpus | RAM: ${ram_gb} GB | free disk (min of /var/lib, backups): ${disk_gb} GB"
[ "$ram_gb" -ge "$MIN_RAM_GB" ] || die "need >= ${MIN_RAM_GB} GB RAM, found ${ram_gb} GB"
[ "$cpus" -ge "$MIN_CPUS" ] || die "need >= ${MIN_CPUS} vCPU, found $cpus"
[ "$disk_gb" -ge "$MIN_DISK_GB" ] || die "need >= ${MIN_DISK_GB} GB free disk, found ${disk_gb} GB"
case "$ID" in debian|ubuntu) ;; *) die "tested on Debian/Ubuntu only (found $ID)";; esac

log "2/7 docker"
if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y docker.io docker-compose-v2 git openssl curl \
    || apt-get install -y docker.io docker-compose-plugin git openssl curl
  systemctl enable --now docker
fi
command -v git >/dev/null || apt-get install -y git
docker compose version

log "3/7 code in $QD_ROOT ($QD_REPO_REF)"
if [ -d "$QD_ROOT/.git" ]; then
  git -C "$QD_ROOT" fetch --quiet origin
  git -C "$QD_ROOT" checkout --quiet "$QD_REPO_REF"
  git -C "$QD_ROOT" pull --quiet --ff-only origin "$QD_REPO_REF" || true
else
  git clone --quiet --branch "$QD_REPO_REF" "$QD_REPO_URL" "$QD_ROOT"
fi
cd "$QD_ROOT/deploy/fallback"
git -C "$QD_ROOT" log -1 --format='at commit %h %s'

log "4/7 kernel setting and backup dir"
echo 'vm.max_map_count=262144' > /etc/sysctl.d/90-qd-fallback.conf
sysctl --quiet --load /etc/sysctl.d/90-qd-fallback.conf
mkdir -p "$QD_BACKUP_DIR/opensearch" "$QD_BACKUP_DIR/postgres"
chown 1000:1000 "$QD_BACKUP_DIR/opensearch"   # uid of the opensearch container user
chmod 700 "$QD_BACKUP_DIR"

log "5/7 .env and S3 identities"
if [ ! -f .env ]; then
  rand() { openssl rand -hex "$1"; }
  sed -e "s|^QD_BIND_ADDR=.*|QD_BIND_ADDR=$QD_BIND_ADDR|" \
      -e "s|^QD_PUBLIC_FILES_ENDPOINT=.*|QD_PUBLIC_FILES_ENDPOINT=http://$QD_BIND_ADDR:8333/queridodiariobucket/|" \
      -e "s|^QD_BACKUP_DIR=.*|QD_BACKUP_DIR=$QD_BACKUP_DIR|" \
      -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=$(rand 24)|" \
      -e "s|^STORAGE_ACCESS_KEY=.*|STORAGE_ACCESS_KEY=qd$(rand 8)|" \
      -e "s|^STORAGE_ACCESS_SECRET=.*|STORAGE_ACCESS_SECRET=$(rand 24)|" \
      -e "s|^SCRAPER_API_KEY=.*|SCRAPER_API_KEY=$(rand 24)|" \
      .env.example > .env
  echo "wrote .env with generated secrets"
else
  echo ".env exists, keeping it"
fi
chmod 600 .env
set -a; . ./.env; set +a
mkdir -p config
umask 077
cat > config/s3.json <<JSON
{
  "identities": [
    { "name": "pipeline",
      "credentials": [{ "accessKey": "$STORAGE_ACCESS_KEY", "secretKey": "$STORAGE_ACCESS_SECRET" }],
      "actions": ["Admin", "Read", "List", "Write", "Tagging"] },
    { "name": "anonymous", "actions": ["Read:queridodiariobucket"] }
  ]
}
JSON
chmod 644 config/s3.json   # read by the container user; holds no more than .env
umask 022
[ -f territories.txt ] || { cp territories.txt.example territories.txt; echo "NOTE: edit $PWD/territories.txt (IBGE codes) before the backfill"; }

log "6/7 build and start (first build takes 10-20 min)"
docker compose build
docker compose --profile jobs build spiders processing
docker compose up -d --wait
docker compose exec -T storage sh -c 'echo "s3.bucket.create -name queridodiariobucket" | weed shell -master=localhost:9333' || true
docker compose run --rm -T spiders scrapy qd-sync-spiders

log "7/7 systemd timers"
cat > /etc/systemd/system/qd-fallback-daily.service <<UNIT
[Unit]
Description=Querido Diário fallback: daily crawl and index
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=$PWD/bin/daily.sh
TimeoutStartSec=6h
UNIT
cat > /etc/systemd/system/qd-fallback-daily.timer <<UNIT
[Unit]
Description=Run qd-fallback-daily every day
[Timer]
OnCalendar=*-*-* 04:30:00
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/qd-fallback-backup.service <<UNIT
[Unit]
Description=Querido Diário fallback: backup
After=docker.service
Requires=docker.service
[Service]
Type=oneshot
ExecStart=$PWD/bin/backup.sh
UNIT
cat > /etc/systemd/system/qd-fallback-backup.timer <<UNIT
[Unit]
Description=Run qd-fallback-backup every night
[Timer]
OnCalendar=*-*-* 02:30:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now qd-fallback-daily.timer qd-fallback-backup.timer

log "done"
cat <<MSG
Services:     $(docker compose ps --format '{{.Service}}={{.Health}}' | paste -sd' ' -)
API check:    curl -s http://$QD_BIND_ADDR:8080/health      -> {"status":"healthy",...}
Status:       $PWD/bin/status.sh
Timers:       systemctl list-timers 'qd-fallback-*'

Next (long-running, start it in tmux):
  1. edit $PWD/territories.txt if you have not yet
  2. cd $PWD && tmux new -s qd 'bin/seed.sh "SP" "2023 2024 2025" && bin/backfill.sh 2026-01-01'
MSG
