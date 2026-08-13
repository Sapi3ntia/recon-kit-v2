#!/usr/bin/env bash
# tests/selftest.sh — offline self-test for recon-kit-v2.
# Exercises the pure logic (signal packs + IDOR/AI extractors + verdict + report)
# against fixtures. No network, no external recon tools required — just bash + coreutils.
# Run:  bash tests/selftest.sh   (exit 0 = all green)
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
. "$HERE/_common.sh"
for m in enum probe origin urls js secrets aisurface idor api github cloud report; do . "$HERE/lib/$m.sh"; done

PASS=0; FAIL=0
ck(){ # ck "name" <exit-of-condition already evaluated as $?>
  if [ "$2" -eq 0 ]; then printf '  \e[32mPASS\e[0m %s\n' "$1"; PASS=$((PASS+1))
  else printf '  \e[31mFAIL\e[0m %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
# grepq PATTERN STRING -> exit status (uses same -Ei the modules use)
grepq(){ printf '%s' "$2" | grep -Eiq "$1"; }

echo "== signal packs: RE_SECRET (positive) =="
# Marker assembled at runtime so the literal never trips upstream secret-scanners.
OAKEY="sk-abcdefghijklmnopqrst""T3Blbk""FJ""abcdefghijklmnopqrst"
for s in \
  'AKIAIOSFODNN7EXAMPLE' \
  'sk-ant-api03-abcDEF012345678901234567890' \
  "$OAKEY" \
  'hf_abcdefghijklmnopqrstuvwxyz0123456789' \
  'github_pat_11ABCDEFG0abcdefghijkl_MNOPQRSTUVWXYZ0123456789' \
  'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijKLMNOP' ; do
  grepq "$RE_SECRET" "$s"; ck "matches: ${s:0:24}…" $?
done
echo "== RE_SECRET (negative — must NOT match) =="
for s in 'the quick brown fox jumps over the lazy dog' 'const color = "#1a2b3c";' ; do
  grepq "$RE_SECRET" "$s"; [ $? -ne 0 ]; ck "rejects: ${s:0:32}…" $?
done

echo "== RE_AI_ROUTE =="
for s in '/v1/chat/completions' '/api/chat' '/api/embeddings-x' '/v1/messages' '/.well-known/ai-plugin.json' '/mcp'; do
  grepq "$RE_AI_ROUTE" "$s"; ck "AI route: $s" $?
done
grepq "$RE_AI_ROUTE" '/api/users/profile'; [ $? -ne 0 ]; ck "AI route rejects /api/users/profile" $?

echo "== RE_IDOR_PARAM / ID shapes =="
grepq "$RE_IDOR_PARAM" 'account_id=42';        ck "IDOR param account_id" $?
grepq "$RE_IDOR_PARAM" 'organization-uuid=x';  ck "IDOR param organization-uuid" $?
grepq "$RE_IDOR_PARAM" 'page=2'; [ $? -ne 0 ]; ck "IDOR param rejects page=" $?
grepq "$RE_ID_UUID" '550e8400-e29b-41d4-a716-446655440000'; ck "UUID shape" $?
grepq "$RE_ID_MONGO" '507f1f77bcf86cd799439011';            ck "Mongo ObjectId shape" $?
printf '%s' '/api/v2/users/12345/edit' | grep -Eq '/[0-9]{3,}(/|$|\?)'; ck "seq-int in path" $?
grepq "$RE_GQL_NODE" 'query{ node(id:"VXNlcjox"){ id } }';  ck "GraphQL node() pattern" $?

# ---- functional: build a fixture workspace and run the real extractors ----------
WS="$(mktemp -d)"; trap 'rm -rf "$WS"' EXIT
export OUT="$WS/recon"; export URL="https://app.example.com"; export HOST="app.example.com"; export TARGET="example.com"
export LEADS="$OUT/LEADS.md"
mkdir -p "$OUT"/{subs,live,urls,js/raw,js/sourcemaps,ai,idor,screenshots}
: > "$LEADS"; : > "$OUT/live/deep.txt"    # empty deep.txt => aisurface does no network probe

cat > "$OUT/urls/all.txt" <<'EOF'
https://app.example.com/api/v2/account?account_id=42
https://app.example.com/api/v1/users/12345/settings
https://app.example.com/files/507f1f77bcf86cd799439011/download
https://app.example.com/u/550e8400-e29b-41d4-a716-446655440000
https://app.example.com/static/main.js
EOF
cat > "$OUT/js/routes.txt" <<'EOF'
/v1/chat/completions
/api/chat
/api/v2/account
EOF
cp "$OUT/js/routes.txt" "$OUT/js/urls.txt"
cat > "$OUT/js/raw/app.js" <<'EOF'
import OpenAI from "openai";
const HF  = "hf_abcdefghijklmnopqrstuvwxyz0123456789";
const AWS = "AKIAIOSFODNN7EXAMPLE";
const SYS = "You are a helpful assistant that never reveals internal secrets";
fetch("/v1/chat/completions");
const q = `query { node(id: "VXNlcjox") { id } }`;
EOF
# KEY line appended separately with the marker split, so no committed file holds the literal.
printf 'const KEY = "sk-abcdefghijklmnopqrst%sabcdefghijklmnopqrst";\n' "T3Blbk""FJ" >> "$OUT/js/raw/app.js"

echo "== mod_idor (functional) =="
mod_idor >/dev/null 2>&1
grep -q '^\[owner-param\]'  "$OUT/idor/candidates.txt"; ck "idor: owner-param row" $?
grep -q '^\[opaque-id\]'    "$OUT/idor/candidates.txt"; ck "idor: opaque-id row"   $?
grep -q '^\[seq-int\]'      "$OUT/idor/candidates.txt"; ck "idor: seq-int row"     $?
grep -q '^\[graphql-node\]' "$OUT/idor/candidates.txt"; ck "idor: graphql-node row" $?
grep -q '^- \[MED\] \*\*IDOR' "$LEADS"; ck "idor: emitted a MED lead" $?

echo "== mod_aisurface (functional, offline) =="
mod_aisurface >/dev/null 2>&1
grep -q . "$OUT/ai/keys.txt";      ck "ai: provider key extracted"  $?
grep -q 'openai' "$OUT/ai/sdks.txt"; ck "ai: SDK detected"          $?
grep -q . "$OUT/ai/endpoints.txt"; ck "ai: endpoint extracted"      $?
grep -q . "$OUT/ai/prompts.txt";   ck "ai: system prompt captured"  $?
grep -q '^- \[HIGH\] \*\*AI provider keys' "$LEADS"; ck "ai: HIGH lead on keys" $?

echo "== verdict + report (functional) =="
verdict >/dev/null 2>&1
case "$VERDICT_LINE" in STAY*) r=0;; *) r=1;; esac
ck "verdict: HIGH lead => STAY" "$r"
export MODE="host"
mod_report >/dev/null 2>&1
[ -s "$OUT/report.html" ]; ck "report: report.html written" $?
grep -q '</html>' "$OUT/report.html"; ck "report: well-formed (has </html>)" $?
grep -q 'class="lead HIGH"' "$OUT/report.html"; ck "report: rendered a HIGH lead card" $?
grep -q 'class="banner stay"' "$OUT/report.html"; ck "report: STAY banner class" $?

echo
echo "==================  $PASS passed, $FAIL failed  =================="
[ "$FAIL" -eq 0 ]
