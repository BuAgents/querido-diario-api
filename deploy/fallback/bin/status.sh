#!/usr/bin/env bash
# Prints service health, index size and data freshness. Safe to run any time.
. "$(dirname "$0")/lib.sh"

dc ps
echo
dc exec -T opensearch curl -fsS 'localhost:9200/_cat/indices?v&h=index,docs.count,store.size'
echo
psql_qd -c "SELECT 'gazettes', count(*), max(date), max(scraped_at), sum((NOT processed)::int) AS unprocessed FROM gazettes"
echo
curl -fsS "http://${QD_BIND_ADDR}:8080/gazettes?size=1&sort_by=descending_date" | head -c 600; echo
