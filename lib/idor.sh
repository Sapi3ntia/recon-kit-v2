#!/usr/bin/env bash
# lib/idor.sh — extract + rank IDOR/BOLA candidates. Access-control/IDOR is the #1 paid
# class in 2026 (it displaced XSS; logic/authz flaws pay most). This does NOT test IDOR
# (that needs two accounts + a human — see CLAUDE.md cross-tenant template). It SURFACES
# and RANKS the object-bearing endpoints so the human tests the best ones first.
#
# Of the five recurring 2026 IDOR patterns, three are statically surfaceable here:
#   sequential ids, GraphQL node() substitution, cross-tenant params.
#   (session-object misbinding + new-feature blind spots are runtime/manual.)

mod_idor(){
  log "IDOR/BOLA candidate extraction + ranking"
  mkdir -p "$OUT/idor"
  local surface="$OUT/idor/_surface.txt"
  cat "$OUT/urls/all.txt" "$OUT/js/routes.txt" "$OUT/js/urls.txt" 2>/dev/null | sort -u > "$surface"
  : > "$OUT/idor/candidates.txt"

  # A) cross-tenant / object-owner params (HIGHEST: names someone else's object explicitly)
  grep -Ei "[?&]$RE_IDOR_PARAM=" "$surface" 2>/dev/null \
    | sed -E 's/^/[owner-param] /' >> "$OUT/idor/candidates.txt" || true
  grep -Ei "$RE_IDOR_PARAM" "$OUT/js/urls.txt" 2>/dev/null | grep -Ei '/(api|v[0-9]|graphql)' \
    | sed -E 's/^/[api-object] /' >> "$OUT/idor/candidates.txt" || true

  # B) UUID / Mongo ObjectId in path (substitution: needs another id leak, but opaque=often unguarded)
  grep -Ei "/($RE_ID_UUID|$RE_ID_MONGO)" "$surface" 2>/dev/null \
    | sed -E 's/^/[opaque-id] /' >> "$OUT/idor/candidates.txt" || true

  # C) numeric id in an API-looking path (sequential: cheapest to test, +/-1)
  grep -Ei '/(api|v[0-9]+|internal|graphql|users?|accounts?|orders?|invoices?|documents?|files?|tickets?)/' "$surface" 2>/dev/null \
    | grep -Ei "$RE_ID_INT" | sed -E 's/^/[seq-int] /' >> "$OUT/idor/candidates.txt" || true

  # D) GraphQL node() / global-id substitution surface (from JS corpus)
  local gqln=0
  if ls "$OUT"/js/raw/*.js >/dev/null 2>&1; then
    gqln=$(grep -rEoh "$RE_GQL_NODE" "$OUT"/js/raw/ 2>/dev/null | sort -u | grep -c . || echo 0)
    [ "$gqln" -gt 0 ] && printf '[graphql-node] node()/globalId pattern in JS (%s hits) — test id substitution via node(id:)\n' "$gqln" >> "$OUT/idor/candidates.txt"
  fi

  sort -u "$OUT/idor/candidates.txt" -o "$OUT/idor/candidates.txt" 2>/dev/null
  rm -f "$surface"

  local own opq seq api total
  own=$(grep -c '^\[owner-param\]' "$OUT/idor/candidates.txt" 2>/dev/null); own=${own:-0}
  api=$(grep -c '^\[api-object\]'  "$OUT/idor/candidates.txt" 2>/dev/null); api=${api:-0}
  opq=$(grep -c '^\[opaque-id\]'   "$OUT/idor/candidates.txt" 2>/dev/null); opq=${opq:-0}
  seq=$(grep -c '^\[seq-int\]'     "$OUT/idor/candidates.txt" 2>/dev/null); seq=${seq:-0}
  total=$(grep -c . "$OUT/idor/candidates.txt" 2>/dev/null); total=${total:-0}

  if [ "$((own+api))" -gt 0 ]; then
    lead MED "IDOR: owner-object endpoints ($((own+api)))" "idor/candidates.txt [owner-param]/[api-object] — endpoints keyed by user/org/account id; run 2-account A→B test (needs auth_A.env+auth_B.env); load hunt-idor"
  fi
  [ "$gqln" -gt 0 ] && lead MED "IDOR: GraphQL node() substitution" "idor/candidates.txt [graphql-node] — Relay global-id substitution is a top-5 2026 IDOR pattern; load hunt-graphql"
  [ "$seq" -gt 0 ] && lead LOW "IDOR: sequential-int endpoints ($seq)" "idor/candidates.txt [seq-int] — cheapest test (+/-1); confirm cross-account before claiming"
  [ "$opq" -gt 0 ] && lead LOW "IDOR: opaque-id endpoints ($opq)" "idor/candidates.txt [opaque-id] — UUID/ObjectId paths; need an id leak, but often unguarded"
  ok "IDOR candidates: owner=$own api=$api opaque=$opq seq=$seq graphql=$gqln"
}
