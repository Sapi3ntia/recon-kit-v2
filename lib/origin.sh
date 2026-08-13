#!/usr/bin/env bash
# lib/origin.sh — origin-IP discovery behind a WAF/CDN (opt-in, DO_ORIGIN=1).
# Hitting the origin directly bypasses Cloudflare/Akamai WAF rules entirely — a recurring
# high-value pivot in every 2026 methodology (Cyber-note Phase 4). Free part: compute the
# favicon mmh3 hash. Pivot part (needs a key): Shodan/FOFA search for other hosts serving the
# same favicon = likely origin. Also flags whether the target is even behind a CDN.

_favicon_hash(){ # URL -> mmh3 favicon hash (Shodan-compatible), or empty
  local base; base=$(printf '%s' "$1" | grep -oE '^https?://[^/]+')
  python3 - "$base/favicon.ico" <<'PY' 2>/dev/null
import sys,urllib.request,base64,ssl
try:
    import mmh3
except Exception:
    sys.exit(0)
ctx=ssl.create_default_context(); ctx.check_hostname=False; ctx.verify_mode=ssl.CERT_NONE
req=urllib.request.Request(sys.argv[1],headers={"User-Agent":"Mozilla/5.0"})
try:
    data=urllib.request.urlopen(req,timeout=10,context=ctx).read()
except Exception:
    sys.exit(0)
if not data: sys.exit(0)
print(mmh3.hash(base64.encodebytes(data)))
PY
}

mod_origin(){
  log "origin-IP discovery (favicon pivot, opt-in)"
  mkdir -p "$OUT/origin"
  # is it behind a CDN? (httpx already told us; surface it)
  local cdn; cdn=$(jq -r 'select(.cdn==true)|.cdn_name // "cdn"' "$OUT/live/httpx.jsonl" 2>/dev/null | head -1)
  [ -n "${cdn:-}" ] && ok "target appears behind CDN/WAF: $cdn — origin pivot is worthwhile"

  local h; h=$(_favicon_hash "$URL")
  if [ -z "$h" ]; then
    warn "favicon hash unavailable (need python3 + 'pip install mmh3', or no favicon) — skipping pivot"
    return 0
  fi
  printf 'favicon mmh3 hash: %s\n' "$h" > "$OUT/origin/favicon_hash.txt"
  ok "favicon mmh3 hash: $h"

  local found=0
  if [ -n "${SHODAN_API_KEY:-}" ]; then
    log "Shodan favicon pivot (http.favicon.hash:$h)"
    curl -s -m 20 "https://api.shodan.io/shodan/host/search?key=$SHODAN_API_KEY&query=http.favicon.hash:$h" 2>/dev/null \
      | jq -r '.matches[]?|.ip_str' 2>/dev/null | sort -u > "$OUT/origin/shodan_ips.txt" || true
    found=$(grep -c . "$OUT/origin/shodan_ips.txt" 2>/dev/null); found=${found:-0}
  elif [ -n "${FOFA_KEY:-}" ] && [ -n "${FOFA_EMAIL:-}" ]; then
    log "FOFA favicon pivot"
    local qb; qb=$(printf 'icon_hash="%s"' "$h" | base64 -w0)
    curl -s -m 20 "https://fofa.info/api/v1/search/all?email=$FOFA_EMAIL&key=$FOFA_KEY&qbase64=$qb&fields=ip" 2>/dev/null \
      | jq -r '.results[]?[0]' 2>/dev/null | sort -u > "$OUT/origin/fofa_ips.txt" || true
    found=$(grep -c . "$OUT/origin/fofa_ips.txt" 2>/dev/null); found=${found:-0}
  else
    warn "no SHODAN_API_KEY / FOFA_KEY set — hash computed but no pivot. Search manually: shodan search http.favicon.hash:$h"
    lead LOW "Favicon hash for origin pivot" "origin/favicon_hash.txt ($h) — run: shodan search http.favicon.hash:$h to find origin behind the WAF"
    return 0
  fi

  if [ "$found" -gt 0 ]; then
    lead MED "Origin-IP candidates via favicon ($found)" "origin/*_ips.txt — hosts serving the same favicon; curl each with Host: $HOST to bypass the WAF, diff response"
    ok "origin candidates: $found"
  else
    ok "favicon pivot returned no hosts"
  fi
}
