#!/usr/bin/env bash
# lib/secrets.sh — deep secret VERIFICATION over the JS corpus + unpacked sourcemap source.
# The always-on regex/jsluice pass (in lib/js.sh) is high-signal but can't prove a key is
# live. trufflehog does entropy + live verification: a "Verified":true hit is a real, working
# credential (-> HIGH). Verifiers make outbound calls to 3rd parties, so this is opt-in
# (DEEP_SECRETS=1). Scans js/raw AND js/sourcemaps (recovered source often holds the real keys).

mod_secrets(){
  [ "$DEEP_SECRETS" = 1 ] || { log "deep secrets skipped (DEEP_SECRETS=0) — regex/jsluice pass already ran"; return 0; }
  have trufflehog || { warn "trufflehog missing — deep secret scan skipped"; return 0; }
  local scanned=0
  : > "$OUT/js/trufflehog.jsonl"
  for d in "$OUT/js/raw" "$OUT/js/sourcemaps"; do
    [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ] || continue
    log "trufflehog filesystem scan: $d"
    trufflehog filesystem "$d" --no-update -j 2>/dev/null >> "$OUT/js/trufflehog.jsonl" || true
    scanned=$((scanned+1))
  done
  [ "$scanned" -eq 0 ] && { warn "no corpus on disk to deep-scan"; return 0; }
  local thv tht
  thv=$(grep -c '"Verified":true' "$OUT/js/trufflehog.jsonl" 2>/dev/null); thv=${thv:-0}
  tht=$(grep -c '"DetectorName"'  "$OUT/js/trufflehog.jsonl" 2>/dev/null); tht=${tht:-0}
  [ "$thv" -gt 0 ] && lead HIGH "trufflehog VERIFIED secrets ($thv)" "js/trufflehog.jsonl — LIVE credentials; confirm scope then report; load secrets-hunt"
  { [ "$thv" -eq 0 ] && [ "$tht" -gt 0 ]; } && lead MED "trufflehog unverified secrets ($tht)" "js/trufflehog.jsonl — triage each (may be FP); VERIFY before claiming"
}
