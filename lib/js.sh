#!/usr/bin/env bash
# lib/js.sh — the core v2 upgrade. AST-accurate JS extraction (jsluice) + sourcemap
# UNPACKING (sourcemapper) + regex fallback. Builds the JS corpus every later module
# reuses ($OUT/js/raw + $OUT/js/manifest.tsv).
#
# Why AST: regex found 47 endpoints where jsluice found 312 on the same Fortune-500
# bundles — modern JS hides URLs in string concat / fetch()/ template literals that
# regex structurally cannot see. jsluice walks the tree-sitter AST instead.

# _js_seed_from_page URL  -> prints absolute JS URLs referenced by the page HTML
_js_seed_from_page(){
  local url="$1" base; base=$(printf '%s' "$url" | grep -oE '^https?://[^/]+')
  local html; html=$(curl -sL -m 15 "${CURL_HDR[@]}" "$url" 2>/dev/null)
  [ -z "$html" ] && { warn "empty response from $url"; return 0; }
  _extract_script_srcs "$base" <<<"$html"
  if [ "${HEADLESS:-0}" = 1 ]; then
    local bin=""; have chromium && bin=chromium; have chromium-browser && bin=chromium-browser
    if [ -n "$bin" ]; then
      log "headless render pass ($bin)"
      local dom; dom=$("$bin" --headless=new --disable-gpu --no-sandbox --virtual-time-budget=8000 --dump-dom "$url" 2>/dev/null)
      [ -n "$dom" ] && _extract_script_srcs "$base" <<<"$dom"
    fi
  fi
}
_extract_script_srcs(){ # base on $1, HTML on stdin -> absolute .js URLs
  local base="$1"
  grep -oiE '<(script|link)[^>]+(src|href)="[^"]*"' | grep -oiE '(src|href)="[^"]*"' \
    | sed -E 's/^(src|href)="//I; s/"$//' | grep -iE '\.js([?#]|$)' \
    | while IFS= read -r s; do case "$s" in
        http*) printf '%s\n' "$s";; //*) printf 'https:%s\n' "$s";;
        /*) printf '%s%s\n' "$base" "$s";; *) printf '%s/%s\n' "$base" "$s";;
      esac; done
}
_extract_child_js(){ # base on $1, JS body on stdin -> absolute child JS URLs (chunks/federation remotes)
  local base="$1"
  grep -oiE 'https?://[a-z0-9._~:/?#@!$&()*+,;=%-]+\.js([?#][a-z0-9?=&._%-]*)?|/[a-z0-9._/-]*(_next/static|__remote/entry|remoteEntry)[a-z0-9._/-]*\.js' \
    | sed -E 's/[",'"'"'`)]+$//' \
    | while IFS= read -r s; do case "$s" in http*) printf '%s\n' "$s";; /*) printf '%s%s\n' "$base" "$s";; esac; done
}

# _js_fetch EXPAND  — BFS over $OUT/js/_queue.txt, saving raw + manifest(slug<TAB>url).
# EXPAND=1 queues child JS each bundle references (single-page federation coverage).
_js_fetch(){
  local expand="$1" base; base=$(printf '%s' "$URL" | grep -oE '^https?://[^/]+')
  local sleep_s; sleep_s=$(awk "BEGIN{ r=${RATE}; if (r<=0) r=1; print 1/r }")
  : > "$OUT/js/_seen.txt"; : > "$OUT/js/manifest.tsv"; mkdir -p "$OUT/js/raw"
  local fetched=0
  while :; do
    comm -23 <(sort -u "$OUT/js/_queue.txt") <(sort -u "$OUT/js/_seen.txt") > "$OUT/js/_todo.txt"
    [ ! -s "$OUT/js/_todo.txt" ] && break
    while IFS= read -r js; do
      [ "$fetched" -ge "$JS_MAX" ] && break
      [ -z "$js" ] && continue
      grep -qxF "$js" "$OUT/js/_seen.txt" && continue
      printf '%s\n' "$js" >> "$OUT/js/_seen.txt"
      local body; body=$(curl -sL -m 12 --max-filesize 8000000 "${CURL_HDR[@]}" "$js" 2>/dev/null)
      [ -z "$body" ] && { sleep "$sleep_s"; continue; }
      fetched=$((fetched+1))
      local sl; sl=$(slug "$js")
      printf '%s' "$body" > "$OUT/js/raw/$sl.js"
      printf '%s\t%s\n' "$sl" "$js" >> "$OUT/js/manifest.tsv"
      [ "$expand" = 1 ] && printf '%s' "$body" | _extract_child_js "$base" >> "$OUT/js/_queue.txt"
      sleep "$sleep_s"
    done < "$OUT/js/_todo.txt"
    [ "$fetched" -ge "$JS_MAX" ] && { warn "hit JS_MAX=$JS_MAX cap — raise it (JS_MAX=N) for fuller coverage"; break; }
    [ "$expand" = 1 ] || break
  done
  rm -f "$OUT/js/_queue.txt" "$OUT/js/_seen.txt" "$OUT/js/_todo.txt"
  ok "JS corpus: $fetched bundle(s) -> js/raw/"
  JS_FETCHED=$fetched
}

# _js_unpack_sourcemaps — for each raw bundle, resolve its .map and reconstruct original source.
_js_unpack_sourcemaps(){
  [ "$PULL_SOURCEMAPS" = 1 ] || return 0
  have sourcemapper || { warn "sourcemapper missing — sourcemap unpack skipped"; return 0; }
  mkdir -p "$OUT/js/sourcemaps"
  local unpacked=0 sl url body map mapurl dir
  while IFS=$'\t' read -r sl url; do
    [ -f "$OUT/js/raw/$sl.js" ] || continue
    body=$(cat "$OUT/js/raw/$sl.js")
    map=$(printf '%s' "$body" | grep -oE 'sourceMappingURL=[^ */[:space:]]+' | tail -1 | sed 's/sourceMappingURL=//')
    case "$map" in
      data:*) continue;;                                   # inline map, nothing to fetch
      http*) mapurl="$map";;
      /*)    mapurl="$(printf '%s' "$url" | grep -oE '^https?://[^/]+')$map";;
      ?*)    mapurl="${url%/*}/$map";;
      *)     mapurl="${url}.map";;                          # no comment -> try convention
    esac
    dir="$OUT/js/sourcemaps/$sl"
    if sourcemapper -url "$mapurl" -output "$dir" >/dev/null 2>&1 && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
      unpacked=$((unpacked+1))
    else
      rmdir "$dir" 2>/dev/null || true
    fi
  done < "$OUT/js/manifest.tsv"
  if [ "$unpacked" -gt 0 ]; then
    ok "sourcemaps unpacked: $unpacked -> js/sourcemaps/"
    lead HIGH "Sourcemaps UNPACKED ($unpacked)" "js/sourcemaps/ — original source recovered (routes, comments, logic, secrets); grep it, load hunt-source-leak"
  fi
}

# _js_analyse — jsluice (AST) + mantra + regex fallback over $OUT/js/raw + unpacked sources.
_js_analyse(){
  : > "$OUT/js/urls.txt"; : > "$OUT/js/secrets.txt"; : > "$OUT/js/routes.txt"; : > "$OUT/js/sinks.txt"
  local jsluice_urls=0
  if [ "$USE_JSLUICE" = 1 ] && have jsluice; then
    log "jsluice AST extraction (URLs + secrets)"
    jsluice urls "$OUT"/js/raw/*.js 2>/dev/null | jq -r '.url' 2>/dev/null | sort -u > "$OUT/js/urls.txt" || true
    jsluice secrets "$OUT"/js/raw/*.js 2>/dev/null > "$OUT/js/jsluice_secrets.jsonl" || true
    jq -r 'select(.severity=="high" or .severity=="medium") | "\(.kind) :: \(.data|tostring[:120])"' \
       "$OUT/js/jsluice_secrets.jsonl" 2>/dev/null | sort -u >> "$OUT/js/secrets.txt" || true
    jsluice_urls=$(wc -l < "$OUT/js/urls.txt" 2>/dev/null || echo 0)
    ok "jsluice: $jsluice_urls URLs/endpoints (AST)"
  else
    [ "$USE_JSLUICE" = 1 ] && warn "jsluice missing — regex-only extraction (weaker)"
  fi
  # regex fallback / supplement over raw bodies + any unpacked original source
  log "regex pass (routes/secrets/sinks) over corpus + unpacked source"
  local f
  for f in "$OUT"/js/raw/*.js $(find "$OUT/js/sourcemaps" -type f 2>/dev/null); do
    [ -f "$f" ] || continue
    grep -Eiao "$RE_SECRET" "$f" 2>/dev/null | sed "s#^#$f :: #" >> "$OUT/js/secrets.txt"
    grep -Eao  "$RE_ROUTE"  "$f" 2>/dev/null                     >> "$OUT/js/routes.txt"
    grep -Eio  "$RE_SINK"   "$f" 2>/dev/null | sed "s#^#$f :: #" >> "$OUT/js/sinks.txt"
  done
  # fold jsluice URLs into the route surface (idor/api read routes.txt + urls.txt)
  [ -s "$OUT/js/urls.txt" ] && cat "$OUT/js/urls.txt" >> "$OUT/js/routes.txt"
  sort -u "$OUT/js/secrets.txt" -o "$OUT/js/secrets.txt" 2>/dev/null
  sort -u "$OUT/js/routes.txt"  -o "$OUT/js/routes.txt"  2>/dev/null
  sort -u "$OUT/js/sinks.txt"   -o "$OUT/js/sinks.txt"   2>/dev/null

  # mantra — quick second-opinion secret scan over the live JS URLs (opt-in via DEEP_SECRETS)
  if [ "$DEEP_SECRETS" = 1 ] && have mantra && [ -s "$OUT/urls/js.txt" ]; then
    log "mantra secret scan over JS URLs"
    mantra < "$OUT/urls/js.txt" 2>/dev/null | sed -E 's/\x1b\[[0-9;]*m//g' >> "$OUT/js/mantra.txt" || true
  fi

  local secn rtn snk
  secn=$(grep -c . "$OUT/js/secrets.txt" 2>/dev/null); secn=${secn:-0}
  rtn=$(grep -c . "$OUT/js/routes.txt" 2>/dev/null); rtn=${rtn:-0}
  snk=$(grep -c . "$OUT/js/sinks.txt" 2>/dev/null); snk=${snk:-0}
  [ "$secn" -gt 0 ] && lead HIGH "Secrets in JS ($secn)" "js/secrets.txt — VERIFY (keyhacks) before claiming; load secrets-hunt"
  [ "$rtn"  -gt 0 ] && lead MED  "API routes from JS ($rtn)" "js/routes.txt (+jsluice urls.txt) — the real attack surface; feeds idor/api"
  [ "$snk"  -gt 0 ] && lead LOW  "DOM sinks ($snk)" "js/sinks.txt — trace source->sink; hunt-dom/hunt-xss if user-controlled"
  probe_secret_files "$URL" "$OUT/js/routes.txt"
}

# entrypoint for wildcard/host: seed from the harvested JS URL list, fetch, unpack, analyse.
mod_js(){
  cp -f "$OUT/urls/js.txt" "$OUT/js/_queue.txt" 2>/dev/null || : > "$OUT/js/_queue.txt"
  [ -s "$OUT/js/_queue.txt" ] || { warn "no JS URLs to analyse"; : > "$OUT/js/routes.txt"; : > "$OUT/js/secrets.txt"; return 0; }
  _js_fetch 0
  _js_unpack_sourcemaps
  _js_analyse
}

# entrypoint for js single-page mode: BFS from one page, following child chunks + federation remotes.
mod_js_singlepage(){
  : > "$OUT/urls/js.txt"
  _js_seed_from_page "$URL" | sort -u > "$OUT/js/_queue.txt"
  cp -f "$OUT/js/_queue.txt" "$OUT/urls/js.txt"
  local seedn; seedn=$(wc -l < "$OUT/js/_queue.txt" 2>/dev/null || echo 0)
  ok "seed JS bundles from page: $seedn"
  [ "$seedn" -eq 0 ] && warn "no <script src>/<link href *.js> — JS inlined, or a bot-wall, not the real app"
  _js_fetch 1     # expand: follow federation remotes + dynamic chunks
  # keep urls/js.txt in sync with everything we actually fetched (for mantra / ai / idor)
  cut -f2 "$OUT/js/manifest.tsv" 2>/dev/null | sort -u > "$OUT/urls/js.txt"
  _js_unpack_sourcemaps
  _js_analyse
}
