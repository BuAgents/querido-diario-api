#!/usr/bin/env bash
# Initial backfill: crawl our territories from a start date, then index.
# Usage: bin/backfill.sh 2023-01-01
# Long-running (hours to days); run it inside tmux/screen or with nohup.
. "$(dirname "$0")/lib.sh"

since="${1:?usage: bin/backfill.sh YYYY-MM-DD}"
date -d "$since" >/dev/null 2>&1 || die "not a date: $since"
crawl_since "$since"
process_unprocessed
log "backfill from $since done"
