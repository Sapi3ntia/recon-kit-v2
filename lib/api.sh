#!/usr/bin/env bash
# lib/api.sh — API attack-surface expansion.
#   mod_api_light : cheap GraphQL detection (wildcard/full breadth pass)
#   mod_api_full  : GraphQL introspection probe + gf classification + arjun (opt-in) +
#                   API version/prefix permutation (host depth pass)

_graphql_probe(){
  local gql; gql=$(grep -ioE "https?://[^\"' ]*graphql[^\"' ]*" "$OUT/urls/all.txt" "$OUT/js/routes.txt" "$OUT/js/urls.txt" 2>/dev/null | head -1)
  [ -z "${gql:-}" ] && return 0
  local q='{"query":"query{__schema{queryType{name}}}"}'
  local r; r=$(curl -s -m 10 -H 'Content-Type: application/json' "${CURL_HDR[@]}" -d "$q" "$gql" 2>/dev/null)
  if printf '%s' "$r" | grep -q '__schema\|queryType'; then
    lead HIGH "GraphQL introspection OPEN" "$gql — dump schema; enumerate node()/mutations for IDOR; load hunt-graphql"
  else
    lead LOW "GraphQL endpoint (introspection off?)" "$gql — try batching / field-level authz; load hunt-graphql"
  fi
}

mod_api_light(){ log "GraphQL detection (light)"; _graphql_probe; }

mod_api_full(){
  _graphql_probe
  if have gf; then
    log "gf classification"
    grep '=' "$OUT/urls/all.txt" 2>/dev/null | sort -u > "$OUT/urls/params.txt"
    for cls in xss sqli ssrf redirect lfi ssti; do
      gf "$cls" < "$OUT/urls/params.txt" 2>/dev/null | sort -u > "$OUT/urls/gf_$cls.txt" || true
      local c; c=$(grep -c . "$OUT/urls/gf_$cls.txt" 2>/dev/null); c=${c:-0}
      [ "$c" -gt 0 ] && lead LOW "gf:$cls candidates ($c)" "urls/gf_$cls.txt — test top few; load hunt-$cls on a real reflection/diff"
    done
  fi

  if [ "$PARAM_DISCOVERY" = 1 ] && have arjun; then
    log "hidden-param discovery (arjun, opt-in — active fuzzing)"
    local origin; origin=$(printf '%s' "$URL" | grep -oE '^https?://[^/]+')
    : > "$OUT/urls/_arjun_in.txt"
    cut -d'?' -f1 "$OUT/urls/params.txt" 2>/dev/null >> "$OUT/urls/_arjun_in.txt"
    grep -E '^/[A-Za-z0-9]' "$OUT/js/routes.txt" 2>/dev/null | sed "s#^#$origin#" >> "$OUT/urls/_arjun_in.txt"
    grep -E '^https?://' "$OUT/urls/_arjun_in.txt" 2>/dev/null | sort -u | head -n "$ARJUN_MAX" > "$OUT/urls/arjun_targets.txt"
    rm -f "$OUT/urls/_arjun_in.txt"
    local atn; atn=$(grep -c . "$OUT/urls/arjun_targets.txt" 2>/dev/null); atn=${atn:-0}
    if [ "$atn" -gt 0 ]; then
      arjun -i "$OUT/urls/arjun_targets.txt" -oT "$OUT/urls/arjun.txt" -t "$THREADS" \
            --rate-limit "$RATE" -q --headers "$ARJUN_HEADERS" 2>/dev/null || true
      local apd; apd=$(grep -c . "$OUT/urls/arjun.txt" 2>/dev/null); apd=${apd:-0}
      [ "$apd" -gt 0 ] && lead MED "Hidden params (arjun, $apd)" "urls/arjun.txt — undocumented params = fresh XSS/IDOR/SSRF surface"
    else
      warn "arjun: no first-party endpoints to probe"
    fi
  fi

  if have ffuf; then
    log "API version/prefix permutation (ffuf, -ac)"
    printf '%s\n' $API_PREFIXES > "$OUT/urls/_prefixes.txt"
    grep -E '/(v[0-9]+|internal|private|admin|beta|staging|public)/' "$OUT/js/routes.txt" 2>/dev/null \
      | sort -u | head -25 > "$OUT/urls/_apibase.txt"
    : > "$OUT/urls/api_perms.txt"
    while IFS= read -r p; do
      local orig fz; orig=$(printf '%s' "$p" | grep -oE '/(v[0-9]+|internal|private|admin|beta|staging|public)/' | head -1 | tr -d /)
      fz=$(printf '%s' "$p" | sed -E 's#/(v[0-9]+|internal|private|admin|beta|staging|public)/#/FUZZ/#')
      [ "$fz" = "$p" ] && continue
      while IFS= read -r hit; do
        [ "$hit" = "$orig" ] && continue
        printf '%s\n' "${URL%/}${fz/FUZZ/$hit}" >> "$OUT/urls/api_perms.txt"
      done < <(ffuf -s -w "$OUT/urls/_prefixes.txt:FUZZ" -u "${URL%/}$fz" "${HDR_ARGS[@]}" -mc 200,201,401,403,405 -ac -rate "$RATE" 2>/dev/null)
    done < "$OUT/urls/_apibase.txt"
    rm -f "$OUT/urls/_prefixes.txt" "$OUT/urls/_apibase.txt"
    sort -u "$OUT/urls/api_perms.txt" -o "$OUT/urls/api_perms.txt" 2>/dev/null
    local apn; apn=$(grep -c . "$OUT/urls/api_perms.txt" 2>/dev/null); apn=${apn:-0}
    [ "$apn" -gt 0 ] && lead LOW "API version/prefix candidates ($apn)" "urls/api_perms.txt — undocumented/older API versions; compare authz vs live (BOLA on deprecated API)"
  fi

  if [ "$RUN_NUCLEI" = 1 ] && have nuclei; then
    log "nuclei (tags=$NUCLEI_TAGS sev=$NUCLEI_SEV)"
    nuclei -silent -u "$URL" -tags "$NUCLEI_TAGS" -severity "$NUCLEI_SEV" -rl "$RATE" -no-color \
           "${HDR_ARGS[@]}" 2>/dev/null > "$OUT/nuclei_hits.txt" || true
    local nun; nun=$(grep -c . "$OUT/nuclei_hits.txt" 2>/dev/null); nun=${nun:-0}
    [ "$nun" -gt 0 ] && lead HIGH "nuclei hits ($nun)" "nuclei_hits.txt — confirm manually, check scope"
  fi
}
