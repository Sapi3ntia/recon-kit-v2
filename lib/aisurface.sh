#!/usr/bin/env bash
# lib/aisurface.sh — the v2 differentiator. Maps the AI/LLM attack surface, which the
# 2025 HackerOne HPSR shows exploding (valid AI findings +210% YoY, prompt injection +540%,
# AI in scope on 1,121 programs). No existing recon tool's discovery phase maps this yet.
#
# It does NOT test prompt injection (that's manual + a hunt-skill). It SURFACES where the
# AI is: chat/agent endpoints, LLM SDKs shipped in bundles, embedded system prompts leaking
# in client code, exposed MCP servers / ai-plugin manifests, and AI provider keys.

mod_aisurface(){
  log "AI/LLM surface mapping"
  mkdir -p "$OUT/ai"
  : > "$OUT/ai/endpoints.txt"; : > "$OUT/ai/sdks.txt"; : > "$OUT/ai/prompts.txt"; : > "$OUT/ai/keys.txt"

  # 1) AI endpoints across the whole observed surface (routes + jsluice urls + crawled urls)
  cat "$OUT/js/routes.txt" "$OUT/js/urls.txt" "$OUT/urls/all.txt" 2>/dev/null \
    | grep -Eio "$RE_AI_ROUTE" 2>/dev/null | sort -u > "$OUT/ai/endpoints.txt" || true

  # 2/3/4) SDKs, embedded system prompts, provider keys — over the JS corpus + unpacked source
  local f
  for f in "$OUT"/js/raw/*.js $(find "$OUT/js/sourcemaps" -type f 2>/dev/null); do
    [ -f "$f" ] || continue
    grep -Eio "$RE_AI_SDK"    "$f" 2>/dev/null                                            >> "$OUT/ai/sdks.txt"
    grep -Eio ".{0,40}($RE_AI_PROMPT).{0,120}" "$f" 2>/dev/null | sed "s#^#$(basename "$f") :: #" >> "$OUT/ai/prompts.txt"
    grep -Eo  'sk-ant-[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9_-]{20,}T3BlbkFJ[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}' "$f" 2>/dev/null | sed "s#^#$f :: #" >> "$OUT/ai/keys.txt"
  done
  sort -u "$OUT/ai/sdks.txt"    -o "$OUT/ai/sdks.txt"    2>/dev/null
  sort -u "$OUT/ai/prompts.txt" -o "$OUT/ai/prompts.txt" 2>/dev/null
  sort -u "$OUT/ai/keys.txt"    -o "$OUT/ai/keys.txt"    2>/dev/null

  # 5) cheap active probe: exposed MCP server / ai-plugin manifest on the deep hosts (content-verified)
  while IFS= read -r h; do
    [ -z "$h" ] && continue
    local base; base=$(printf '%s' "$h" | grep -oE '^https?://[^/]+')
    for p in /.well-known/ai-plugin.json /.well-known/mcp.json /mcp; do
      local body; body=$(curl -s -m 8 "${CURL_HDR[@]}" "$base$p" 2>/dev/null)
      if printf '%s' "$body" | grep -qiE '"schema_version"|"api"|"mcp"|"tools"|jsonrpc|"protocolVersion"' \
         && ! printf '%s' "$body" | grep -qiE '<html|<!doctype'; then
        printf '%s%s\n' "$base" "$p" >> "$OUT/ai/endpoints.txt"
        lead MED "AI manifest/MCP exposed ($base$p)" "returns AI plugin/MCP descriptor — enumerate tools; test indirect prompt injection + tool-abuse (manual)"
      fi
    done
  done < <(head -5 "$OUT/live/deep.txt" 2>/dev/null)
  sort -u "$OUT/ai/endpoints.txt" -o "$OUT/ai/endpoints.txt" 2>/dev/null

  local en sn pn kn
  en=$(grep -c . "$OUT/ai/endpoints.txt" 2>/dev/null); en=${en:-0}
  sn=$(grep -c . "$OUT/ai/sdks.txt" 2>/dev/null); sn=${sn:-0}
  pn=$(grep -c . "$OUT/ai/prompts.txt" 2>/dev/null); pn=${pn:-0}
  kn=$(grep -c . "$OUT/ai/keys.txt" 2>/dev/null); kn=${kn:-0}
  [ "$kn" -gt 0 ] && lead HIGH "AI provider keys in JS ($kn)" "ai/keys.txt — OpenAI/Anthropic/HF keys client-side = billing abuse + data access; VERIFY scope, report"
  [ "$en" -gt 0 ] && lead MED  "AI/LLM endpoints ($en)" "ai/endpoints.txt — chat/agent/completion routes; test prompt-injection, unauth access, IDOR on conversation ids"
  [ "$pn" -gt 0 ] && lead MED  "Embedded system prompt(s) ($pn)" "ai/prompts.txt — guardrail/system prompt leaks client-side; maps jailbreak + injection surface"
  [ "$sn" -gt 0 ] && lead LOW  "LLM SDK in bundle ($sn)" "ai/sdks.txt — an AI feature exists here ($(sort -u "$OUT/ai/sdks.txt" | tr '\n' ',' | cut -c1-60)); find its input flow"
  ok "AI surface: endpoints=$en sdks=$sn prompts=$pn keys=$kn"
}
