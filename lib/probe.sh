#!/usr/bin/env bash
# lib/probe.sh — live-host fingerprint + rank + screenshots + takeover CONFIRMATION.
# mod_probe        : wildcard/full (many hosts -> rank -> deep list)
# mod_probe_single : host mode (one URL fingerprint)

_rank_hosts(){
  jq -r '[.url,(.title//""),((.tech//[])|join(",")),(.webserver//""),(.status_code|tostring)]|@tsv' \
     "$OUT/live/httpx.jsonl" 2>/dev/null > "$OUT/live/flat.tsv"
  grep -iE "$RE_HOST_INTEREST" "$OUT/live/flat.tsv" 2>/dev/null | cut -f1 > "$OUT/live/_a"
  awk -F'\t' '$5==401||$5==403{print $1}' "$OUT/live/flat.tsv" 2>/dev/null > "$OUT/live/_b"
  cat "$OUT/live/_a" "$OUT/live/_b" 2>/dev/null | sort -u > "$OUT/live/ranked.txt"; rm -f "$OUT/live/_a" "$OUT/live/_b"
  RANKN=$(wc -l < "$OUT/live/ranked.txt" 2>/dev/null || echo 0)
  [ "$RANKN" -gt 0 ] && lead MED "Interesting hosts ($RANKN)" "keyword/auth-wall hits in live/ranked.txt — staging/admin/api/internal first"
  while IFS= read -r tline; do
    s=$(skill_for "$tline"); [ -n "$s" ] && lead MED "Stack fingerprint" "$(printf '%s' "$tline" | cut -f1) -> load $s"
  done < <(sort -u "$OUT/live/flat.tsv" 2>/dev/null | grep -iE 'next|laravel|spring|asp\.net|graphql|wordpress|viewstate|actuator' | head -10)
}

_confirm_takeover(){
  local cand="$OUT/subs/cname_takeover_candidates.txt"
  [ "$CONFIRM_TAKEOVER" = 1 ] || return 0
  [ -s "$cand" ] || return 0
  cut -d' ' -f1 "$cand" 2>/dev/null | sort -u > "$OUT/subs/_takeover_hosts.txt"
  if have subzy; then
    log "confirming takeover (subzy)"
    subzy run --targets "$OUT/subs/_takeover_hosts.txt" --hide_fails 2>/dev/null > "$OUT/subs/takeover_confirmed.txt" || true
    grep -iE 'VULNERABLE|takeover' "$OUT/subs/takeover_confirmed.txt" 2>/dev/null | head -1 >/dev/null \
      && lead HIGH "Subdomain takeover CONFIRMED (subzy)" "subs/takeover_confirmed.txt — claim-check the service, then report"
  elif have nuclei; then
    log "confirming takeover (nuclei -tags takeover)"
    nuclei -silent -l "$OUT/subs/_takeover_hosts.txt" -tags takeover -no-color "${HDR_ARGS[@]}" 2>/dev/null \
      > "$OUT/subs/takeover_confirmed.txt" || true
    [ -s "$OUT/subs/takeover_confirmed.txt" ] && lead HIGH "Subdomain takeover CONFIRMED (nuclei)" "subs/takeover_confirmed.txt — claim-check, then report"
  fi
  rm -f "$OUT/subs/_takeover_hosts.txt"
}

mod_probe(){
  local hosts_in="$OUT/subs/all.txt"
  [ -s "$hosts_in" ] || printf '%s\n' "$TARGET" > "$hosts_in"
  if have httpx; then
    log "probing live hosts (httpx, $RATE rps)"
    httpx -silent -l "$hosts_in" -json -rl "$RATE" -t "$THREADS" \
          -title -tech-detect -status-code -web-server -cdn -ip -follow-redirects \
          "${HDR_ARGS[@]}" 2>/dev/null > "$OUT/live/httpx.jsonl"
    jq -r '.url' "$OUT/live/httpx.jsonl" 2>/dev/null | sort -u > "$OUT/live/urls.txt"
    ok "live hosts: $(wc -l < "$OUT/live/urls.txt" 2>/dev/null || echo 0)"
  else
    warn "httpx missing — cannot fingerprint"; cp "$hosts_in" "$OUT/live/urls.txt"
  fi
  log "ranking interesting hosts"
  if [ -s "$OUT/live/httpx.jsonl" ]; then _rank_hosts; else cp "$OUT/live/urls.txt" "$OUT/live/ranked.txt"; fi
  head -n "$TOP_HOSTS" "$OUT/live/ranked.txt" 2>/dev/null > "$OUT/live/deep.txt"
  [ -s "$OUT/live/deep.txt" ] || head -n "$TOP_HOSTS" "$OUT/live/urls.txt" > "$OUT/live/deep.txt"

  if [ "$DO_PORTS" = 1 ] && have naabu; then
    log "port scan (naabu top-100, connect) on deep hosts"
    sed -E 's#https?://##; s#/.*##' "$OUT/live/deep.txt" 2>/dev/null | sort -u > "$OUT/live/_hosts.txt"
    naabu -silent -l "$OUT/live/_hosts.txt" -top-ports 100 -c 50 -rate "$NAABU_RATE" 2>/dev/null > "$OUT/live/ports.txt" || true
    rm -f "$OUT/live/_hosts.txt"
    PN=$(awk -F: '$2!=80 && $2!=443' "$OUT/live/ports.txt" 2>/dev/null | grep -c . || echo 0)
    [ "$PN" -gt 0 ] && lead LOW "Non-standard open ports ($PN)" "live/ports.txt — exposed mgmt/app ports = often a forgotten service"
  fi

  _confirm_takeover
  shoot "$OUT/live/deep.txt" "$OUT/screenshots"
}

mod_probe_single(){
  printf '%s\n' "$URL" > "$OUT/live/urls.txt"
  printf '%s\n' "$URL" > "$OUT/live/deep.txt"
  if have httpx; then
    log "fingerprint (httpx)"
    printf '%s\n' "$URL" | httpx -silent -json -title -tech-detect -status-code \
          -web-server -cdn -ip -follow-redirects "${HDR_ARGS[@]}" -rl "$RATE" 2>/dev/null > "$OUT/live/httpx.jsonl"
    FP=$(jq -r '[(.title//""),((.tech//[])|join(",")),(.webserver//"")]|join(" | ")' "$OUT/live/httpx.jsonl" 2>/dev/null | head -1)
    ok "fingerprint: ${FP:-<none>}"
    s=$(skill_for "$FP"); [ -n "$s" ] && lead MED "Stack fingerprint" "$FP -> load $s"
  fi
  shoot "$OUT/live/deep.txt" "$OUT/screenshots"
}
