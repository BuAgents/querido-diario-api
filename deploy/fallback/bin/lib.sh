# Shared helpers for the qd-fallback scripts. Sourced, not executed.
set -euo pipefail

QD_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$QD_DIR"

log() { printf '[qd-fallback %s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
die() { log "ERROR: $*"; exit 1; }

[ -f .env ] || die "missing $QD_DIR/.env (run bin/setup.sh first)"
set -a; . ./.env; set +a

dc() { docker compose --project-directory "$QD_DIR" -f "$QD_DIR/docker-compose.yml" "$@"; }

psql_qd() { dc exec -T postgres psql -U queridodiario -d queridodiariodb -v ON_ERROR_STOP=1 -At "$@"; }

# Spiders that cover at least one territory in territories.txt and are still
# active (date_to empty or within the look-back window). One name per line.
spiders_for_territories() {
  local since="$1" ids
  [ -f territories.txt ] || die "missing $QD_DIR/territories.txt"
  ids=$(grep -Eo '^[0-9]{7}' territories.txt | sed "s/.*/'&'/" | paste -sd, -)
  [ -n "$ids" ] || die "territories.txt has no 7-digit IBGE codes"
  psql_qd -c "SELECT DISTINCT m.spider_name
              FROM territory_spider_map m
              JOIN querido_diario_spiders s USING (spider_name)
              WHERE m.territory_id IN ($ids)
                AND (s.date_to IS NULL OR s.date_to >= DATE '$since')
              ORDER BY 1"
}

# Crawl each spider from $1 (YYYY-MM-DD). A failing spider is logged and skipped
# so one broken municipal site does not stop the rest.
crawl_since() {
  local since="$1" failed=0 total=0 spider
  while read -r spider; do
    [ -n "$spider" ] || continue
    total=$((total + 1))
    log "crawl $spider since $since"
    if ! dc run --rm -T spiders scrapy crawl "$spider" -a start="$since" -s LOG_LEVEL=INFO; then
      failed=$((failed + 1)); log "WARN: spider $spider failed"
    fi
  done < <(spiders_for_territories "$since")
  log "crawl finished: $total spiders, $failed failed"
}

process_unprocessed() {
  log "processing unprocessed gazettes (Tika -> OpenSearch)"
  dc run --rm -T -e EXECUTION_MODE=UNPROCESSED processing
}
