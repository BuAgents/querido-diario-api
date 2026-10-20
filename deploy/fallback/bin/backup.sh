#!/usr/bin/env bash
# Nightly backup: pg_dump of the gazettes catalogue + OpenSearch snapshot.
# PDFs/TXT in object storage are NOT copied here (they are the bulk and can be
# re-crawled); set QD_OFFSITE_CMD in .env to ship $QD_BACKUP_DIR elsewhere.
. "$(dirname "$0")/lib.sh"

backup_dir="${QD_BACKUP_DIR:-/srv/qd-fallback/backups}"
mkdir -p "$backup_dir/postgres"
stamp=$(date -u +%Y%m%dT%H%M%SZ)

log "pg_dump queridodiariodb"
dc exec -T postgres pg_dump -U queridodiario -Fc queridodiariodb > "$backup_dir/postgres/queridodiariodb-$stamp.dump"
find "$backup_dir/postgres" -name '*.dump' -mtime +14 -delete

log "OpenSearch snapshot"
dc exec -T opensearch curl -fsS -X PUT localhost:9200/_snapshot/local \
  -H 'Content-Type: application/json' \
  -d '{"type":"fs","settings":{"location":"/usr/share/opensearch/snapshots"}}' >/dev/null
dc exec -T opensearch curl -fsS -X PUT "localhost:9200/_snapshot/local/qd-$(echo "$stamp" | tr 'A-Z' 'a-z')?wait_for_completion=true" >/dev/null
# Keep the 7 newest snapshots (snapshots are incremental, so this is cheap).
for old in $(dc exec -T opensearch curl -fsS 'localhost:9200/_cat/snapshots/local?h=id&s=end_epoch:desc' | tail -n +8); do
  dc exec -T opensearch curl -fsS -X DELETE "localhost:9200/_snapshot/local/$old" >/dev/null
done

if [ -n "${QD_OFFSITE_CMD:-}" ]; then
  log "offsite copy"; eval "$QD_OFFSITE_CMD"
fi
log "backup done in $backup_dir"
