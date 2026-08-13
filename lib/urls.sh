#!/usr/bin/env bash
# lib/urls.sh — URL + JS harvest on the deep hosts (gau + waybackurls + katana).
# Produces urls/all.txt (the endpoint surface fed to idor/api) and urls/js.txt (fed to js/secrets/ai).

mod_urls(){
  local seed="$OUT/live/deep.txt"
  [ -s "$seed" ] || printf '%s\n' "$URL" > "$seed"
  log "URL/JS harvest on $(wc -l < "$seed" 2>/dev/null || echo 1) host(s)"
  : > "$OUT/urls/all.txt"
  have gau         && to gau --threads "$THREADS" < "$seed" 2>/dev/null | anew "$OUT/urls/all.txt" >/dev/null
  have waybackurls && to waybackurls < "$seed" 2>/dev/null | anew "$OUT/urls/all.txt" >/dev/null
  have katana      && to katana -silent -list "$seed" -d "$KATANA_DEPTH" -jc -kf all -rl "$RATE" \
                        "${HDR_ARGS[@]}" 2>/dev/null | anew "$OUT/urls/all.txt" >/dev/null
  grep -iE '\.js(\?|$)' "$OUT/urls/all.txt" 2>/dev/null | sort -u | head -400 > "$OUT/urls/js.txt"
  local urln jsn
  urln=$(wc -l < "$OUT/urls/all.txt" 2>/dev/null || echo 0)
  jsn=$(wc -l < "$OUT/urls/js.txt" 2>/dev/null || echo 0)
  ok "URLs: $urln   JS files: $jsn"
  if [ "$urln" -gt 100 ] && [ "$jsn" -eq 0 ]; then
    warn "many URLs but zero .js — check urls/all.txt; may be a bot-wall block page, not the real app"
  fi
}
