# Querido Diário fallback (scoped self-hosted mirror)

A single-host deployment of the whole Querido Diário pipeline for a **chosen list of
municipalities**, used as a fallback for `api.queridodiario.ok.org.br`. The API it
serves has the same shape as the hosted one (`/gazettes`, `/cities`,
`/gazettes/by_theme/...`), so a client only swaps the base URL.

```
spiders (Scrapy, okfn-brasil/querido-diario @ pinned commit)
  ├─ PDFs ───────────────► storage   (SeaweedFS, S3 API, bucket queridodiariobucket)
  └─ gazette rows ───────► postgres  (queridodiariodb: gazettes, territories, spiders)
processing (okfn-brasil/querido-diario-data-processing @ pinned commit)
  ├─ text extraction ────► tika      (Apache Tika server 3.3.x)
  └─ text + excerpts ────► opensearch (2.19.x, single node)
api (this repo) ─ reads opensearch + postgres, links files on storage
```

| Service | Image / source | Published on |
|---|---|---|
| api | built from this repo | `QD_BIND_ADDR:8080` |
| storage | `chrislusf/seaweedfs:4.48` | `QD_BIND_ADDR:8333` (anonymous read of the bucket only) |
| opensearch | `opensearchproject/opensearch:2.19.6` | internal network only |
| postgres | `postgres:17` | internal network only |
| tika | `apache/tika:3.3.1.0` | internal network only |
| spiders (job) | `Dockerfile.spiders` | — |
| processing (job) | upstream `Dockerfile` at `QD_PROCESSING_REF` | — |

`QD_BIND_ADDR` must be a private-network or VPN address (Tailscale, WireGuard,
provider VPC). Nothing in this stack is meant to face the internet, and OpenSearch
runs with its security plugin disabled because it is never published.

## Setup (on the server, as root)

```bash
ssh root@<server> "QD_BIND_ADDR=<private/VPN IP> bash -s" < deploy/fallback/bin/setup.sh
```

The script is idempotent: it checks the host, installs Docker if needed, clones this
repo into `/opt/qd-fallback`, writes `.env` with generated secrets, starts the
services, creates the bucket and tables, and installs two systemd timers
(`qd-fallback-daily` 04:30, `qd-fallback-backup` 02:30). It does not start the
backfill.

Then put the IBGE codes to mirror in `/opt/qd-fallback/deploy/fallback/territories.txt`,
seed history from OKFN's public export and backfill 2026 with our own spiders, in tmux:

```bash
cd /opt/qd-fallback/deploy/fallback
tmux new -s qd 'bin/seed.sh "SP" "2023 2024 2025" && bin/backfill.sh 2026-01-01'
```

`bin/seed.sh` imports the public "aggregates" export (`aggregates/{UF}/{UF}_{year}.zip`,
already-extracted text, no PDFs). That export was last refreshed in Dec 2025, so it
only covers up to 2025. Seeded gazettes are searchable and return excerpts, but have
no `txt_url`.

## Day to day

| Command | What it does |
|---|---|
| `bin/status.sh` | Service health, index size, newest gazette date, unprocessed count |
| `bin/daily.sh` | Re-crawls the last `QD_DAILY_LOOKBACK_DAYS` days, then indexes (timer) |
| `bin/backfill.sh YYYY-MM-DD` | Crawls from a date, then indexes |
| `bin/seed.sh "UF ..." "YEAR ..."` | Imports OKFN aggregates (text only, up to 2025) for our territories |
| `bin/backup.sh` | `pg_dump` + incremental OpenSearch snapshot into `QD_BACKUP_DIR` (timer) |

Spiders are chosen from `territory_spider_map`: every spider that covers one of the
listed territories and is still active. Consortium spiders (e.g. a state association
gazette) crawl all their member municipalities, so storage can grow beyond the list.
27 upstream spiders need Zyte Smart Proxy (paid); without `ZYTE_SMARTPROXY_APIKEY`
those sites may block us and their crawls fail without stopping the others.

## Backups and restore

- **Postgres** (`queridodiariodb-*.dump`, 14 days kept): `docker compose exec -T postgres pg_restore -U queridodiario -d queridodiariodb --clean < <file>`.
- **OpenSearch** (repository `local`, 7 snapshots kept): `curl -X POST localhost:9200/_snapshot/local/<id>/_restore` from inside the container.
- **Files** in SeaweedFS are not backed up: they can be re-crawled, and the index
  already holds the extracted text. Set `QD_OFFSITE_CMD` in `.env` (e.g. a `restic` or
  `rclone` command) to copy `QD_BACKUP_DIR` off the host.

## Patch plan

- Image versions and upstream commits are pinned in `.env`. Upgrade by editing
  `.env`, then `docker compose pull && docker compose build && docker compose up -d`.
- OpenSearch: stay on 2.19.x patch releases (same index format as 2.9, so in-place).
  Moving to 3.x needs a reindex check and an `opensearch-py` 3.x client in this API.
- Postgres: minor versions in place. A major version bump means
  `pg_dump` → new volume → `pg_restore` (the catalogue is small, minutes).
- Tika: stay on 3.3.x until data-processing moves to 4.x.
- Upstream code: bump `QD_SPIDERS_REF` monthly (spiders break when municipal sites
  change) and `QD_PROCESSING_REF` when upstream releases fixes.
