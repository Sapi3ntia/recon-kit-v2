#!/usr/bin/env bash
# rkv2.sh — recon-kit-v2 orchestrator. Fast, ranked, browsable STAY/LEAVE triage
# tuned for what pays in 2026 (access-control/IDOR, API, AI/LLM surface, secrets).
#
#   ./rkv2.sh wildcard  target.com          # *.target.com : enum -> rank -> deep JS/AI/IDOR map
#   ./rkv2.sh host      https://app.target.com   # one app : deep JS + sourcemaps + API + AI + IDOR
#   ./rkv2.sh js        https://app.target.com/route  # single page : BFS JS source->sink + AI/IDOR
#   ./rkv2.sh full      target.com           # wildcard, then auto host-depth on the hottest host
#
# Every LOUD action is opt-in (see _common.sh knobs). Passive + quiet by default.
# Output: recon/<name>/{subs,live,urls,js,ai,idor,github,cloud}/ + LEADS.md + report.html
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/_common.sh"
for m in enum probe origin urls js secrets aisurface idor api github cloud report; do
  . "$HERE/lib/$m.sh"
done

usage(){ sed -n '2,13p' "$0"; exit "${1:-0}"; }
MODE="${1:-}"; [ -z "$MODE" ] && usage 1
case "$MODE" in wildcard|host|js|full) shift;; -h|--help) usage 0;; *) err "unknown mode: $MODE"; usage 1;; esac
ARG="${1:-}"; [ -z "$ARG" ] && { err "mode '$MODE' needs a target"; usage 1; }

# ---- context (globals the modules read) --------------------------------------
case "$MODE" in
  wildcard|full) TARGET="$ARG"; HOST="$ARG"; URL="https://$ARG"; OUT="${2:-recon/$ARG}";;
  host|js)
    case "$ARG" in http*://*) URL="$ARG";; *) URL="https://$ARG";; esac
    HOST="$(printf '%s' "$URL" | sed -E 's#https?://##; s#/.*##')"
    TARGET="$HOST"; OUT="${2:-recon/$HOST}";;
esac
export MODE TARGET HOST URL OUT
mkdir -p "$OUT"/{subs,live,urls,js,ai,idor,github,cloud,screenshots}
LEADS="$OUT/LEADS.md"; : > "$LEADS"
{ echo "# LEADS ($MODE) — $ARG   ($(date -u +%FT%TZ))"; echo; } >> "$LEADS"
export LEADS
VERDICT_LINE=""; VERDICT_HI=0; VERDICT_ME=0; VERDICT_LO=0

log "recon-kit-v2 [$MODE] $ARG -> $OUT"
log "knobs: rate=${RATE} jsluice=${USE_JSLUICE} sourcemaps=${PULL_SOURCEMAPS} ai=${DO_AISURFACE} idor=${DO_IDOR} origin=${DO_ORIGIN} github=${DO_GITHUB} cloud=${DO_CLOUD} nuclei=${RUN_NUCLEI}"

# ---- run the module chain for the chosen mode --------------------------------
case "$MODE" in
  wildcard)
    mod_enum
    mod_probe
    [ "$DO_ORIGIN" = 1 ] && mod_origin
    mod_urls
    mod_js
    mod_secrets
    [ "$DO_AISURFACE" = 1 ] && mod_aisurface
    [ "$DO_IDOR" = 1 ] && mod_idor
    mod_api_light
    [ "$DO_GITHUB" = 1 ] && mod_github
    [ "$DO_CLOUD" = 1 ] && mod_cloud
    ;;
  host)
    mod_probe_single
    [ "$DO_ORIGIN" = 1 ] && mod_origin
    mod_urls
    mod_js
    mod_secrets
    [ "$DO_AISURFACE" = 1 ] && mod_aisurface
    [ "$DO_IDOR" = 1 ] && mod_idor
    mod_api_full
    [ "$DO_GITHUB" = 1 ] && mod_github
    [ "$DO_CLOUD" = 1 ] && mod_cloud
    ;;
  js)
    mod_js_singlepage
    mod_secrets
    [ "$DO_AISURFACE" = 1 ] && mod_aisurface
    [ "$DO_IDOR" = 1 ] && mod_idor
    ;;
  full)
    mod_enum
    mod_probe
    [ "$DO_ORIGIN" = 1 ] && mod_origin
    mod_urls
    mod_js
    mod_secrets
    [ "$DO_AISURFACE" = 1 ] && mod_aisurface
    [ "$DO_IDOR" = 1 ] && mod_idor
    mod_api_light
    [ "$DO_GITHUB" = 1 ] && mod_github
    [ "$DO_CLOUD" = 1 ] && mod_cloud
    # auto-descend into the hottest host at full depth
    HOT=$(head -1 "$OUT/live/deep.txt" 2>/dev/null)
    if [ -n "${HOT:-}" ]; then
      log "full: descending into hottest host $HOT (host-depth API pass)"
      URL="$HOT"; HOST="$(printf '%s' "$URL" | sed -E 's#https?://##; s#/.*##')"
      mod_api_full
    fi
    ;;
esac

verdict
mod_report
echo; ok "DONE"
echo "  leads : $LEADS"
echo "  report: $OUT/report.html"
echo "----- LEADS.md -----"; cat "$LEADS"
