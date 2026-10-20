#!/usr/bin/env bash
# Daily upkeep: re-crawl the last QD_DAILY_LOOKBACK_DAYS days for our territories,
# then extract and index whatever is new. Run by qd-fallback-daily.timer.
. "$(dirname "$0")/lib.sh"

since=$(date -u -d "-${QD_DAILY_LOOKBACK_DAYS:-7} days" +%F)
crawl_since "$since"
process_unprocessed
log "daily run done"
