#!/usr/bin/env bash
# lib/enum.sh — passive subdomain enumeration (wildcard/full modes).
# Passive by default (PASSIVE_ONLY=1). crt.sh always on. github-subdomains when a token is set.

mod_enum(){
  log "subdomain enum (passive=$PASSIVE_ONLY)"
  : > "$OUT/subs/all.txt"
  if [ -n "${CHAOS_API_KEY:-}" ]; then
    curl -s "https://dns.projectdiscovery.io/dns/$TARGET/subdomains" \
      -H "Authorization: $CHAOS_API_KEY" | jq -r '.subdomains[]? + ".'"$TARGET"'"' 2>/dev/null \
      | anew "$OUT/subs/all.txt" >/dev/null || true
  fi
  have subfinder   && to subfinder -silent -d "$TARGET" 2>/dev/null | anew "$OUT/subs/all.txt" >/dev/null
  have assetfinder && to assetfinder --subs-only "$TARGET" 2>/dev/null | grep -i "\.$TARGET\$" | anew "$OUT/subs/all.txt" >/dev/null
  if [ "$PASSIVE_ONLY" = 1 ]; then
    have amass && to amass enum -passive -d "$TARGET" -timeout 3 2>/dev/null | anew "$OUT/subs/all.txt" >/dev/null
  else
    have amass && to amass enum -d "$TARGET" -timeout 5 2>/dev/null | anew "$OUT/subs/all.txt" >/dev/null
  fi
  # github-subdomains: mines developer code for subs the CT logs miss (needs GITHUB_TOKEN).
  if [ -n "${GITHUB_TOKEN:-}" ] && have github-subdomains; then
    to github-subdomains -d "$TARGET" -t "$GITHUB_TOKEN" -o "$OUT/subs/_gh.txt" >/dev/null 2>&1 || true
    [ -s "$OUT/subs/_gh.txt" ] && anew "$OUT/subs/all.txt" < "$OUT/subs/_gh.txt" >/dev/null; rm -f "$OUT/subs/_gh.txt"
  fi
  # crt.sh — free CT-log pull, always on.
  curl -s -m 25 "https://crt.sh/?q=%25.$TARGET&output=json" 2>/dev/null \
    | jq -r '.[].name_value' 2>/dev/null | sed 's/\*\.//g' | tr 'A-Z' 'a-z' \
    | grep -E "\.$TARGET\$" | anew "$OUT/subs/all.txt" >/dev/null || true

  SUBN=$(wc -l < "$OUT/subs/all.txt" 2>/dev/null || echo 0)
  ok "subdomains: $SUBN"
  [ "$SUBN" -eq 0 ] && warn "no subdomains found — wrong scope or no passive data"

  # resolve + CNAME capture (takeover signal)
  if have dnsx; then
    log "resolving (dnsx) + CNAME capture"
    to dnsx -silent -a -cname -resp -l "$OUT/subs/all.txt" 2>/dev/null > "$OUT/subs/resolved.txt"
    grep -iE 'CNAME' "$OUT/subs/resolved.txt" 2>/dev/null \
      | grep -iE 'github\.io|s3[.-]|amazonaws|heroku|azurewebsites|cloudfront|fastly|netlify|ghost\.io|wpengine|pantheon|surge\.sh|bitbucket|zendesk|readme\.io|statuspage|unbounce|cargo|shopify|helpscout|readthedocs|firebaseapp|desk\.com' \
      > "$OUT/subs/cname_takeover_candidates.txt" || true
    TKN=$(wc -l < "$OUT/subs/cname_takeover_candidates.txt" 2>/dev/null || echo 0)
    [ "$TKN" -gt 0 ] && lead HIGH "Subdomain-takeover candidates ($TKN)" "dangling CNAMEs in subs/cname_takeover_candidates.txt — confirmed below if CONFIRM_TAKEOVER=1"
  fi
}
