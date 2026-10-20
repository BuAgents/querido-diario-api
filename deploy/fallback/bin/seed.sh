#!/usr/bin/env bash
# Seed history from OKFN's public "aggregates" export (state/year ZIPs of
# already-extracted text). No crawling, no Tika. The export stopped being
# refreshed in Dec 2025, so it covers up to 2025; daily.sh/backfill.sh cover
# 2026 onwards from our own spiders.
#
# Usage: bin/seed.sh "AL SP" "2023 2024 2025"
# Only gazettes of territories in territories.txt are indexed (all, if empty).
. "$(dirname "$0")/lib.sh"

ufs="${1:?usage: bin/seed.sh \"UF ...\" \"YEAR ...\"}"
years="${2:?usage: bin/seed.sh \"UF ...\" \"YEAR ...\"}"
import_dir="${QD_IMPORT_DIR:-/srv/qd-fallback/imports}"
mkdir -p "$import_dir"
ids=$(grep -Eo '^[0-9]{7}' territories.txt 2>/dev/null | paste -sd, - || true)

log "ensure the gazettes index exists (upstream mapping)"
dc run --rm -T processing python -c \
  "from index import create_index_interface; from tasks import run_task; run_task('create_gazettes_index', create_index_interface())"

files=()
for uf in $ufs; do
  for year in $years; do
    f="$import_dir/${uf}_${year}.zip"
    if [ ! -s "$f" ]; then
      log "download ${uf}_${year}.zip"
      if ! curl -fsSL -o "$f.part" "https://data.queridodiario.ok.org.br/aggregates/${uf}/${uf}_${year}.zip"; then
        log "WARN: ${uf}_${year}.zip not available, skipping"; rm -f "$f.part"; continue
      fi
      mv "$f.part" "$f"
    fi
    files+=("/imports/$(basename "$f")")
  done
done
[ ${#files[@]} -gt 0 ] || die "nothing to import"

log "import ${#files[@]} file(s)"
dc run --rm -T -v "$import_dir:/imports:ro" api \
  python deploy/fallback/bin/import_aggregates.py --territories "$ids" "${files[@]}"
log "seed done"
