#!/usr/bin/env bash
# lib/github.sh — GitHub source intelligence (opt-in, DO_GITHUB=1, needs GITHUB_TOKEN).
# For OSS / greybox targets, developer repos leak endpoints, internal hosts, and live secrets.
# Ties into securitycontext.dev: when a target repo is known, the AGENT should call the
# securitycontext MCP (get_security_context / get_vulnerability_leads) to turn the repo's
# fix-commit history into a variant-hunting map — this module flags that as a next action.
#
# Set GITHUB_REPO=owner/name (or a clone URL) to deep-scan a specific repo with gitleaks+trufflehog.

mod_github(){
  [ -n "${GITHUB_TOKEN:-}" ] || { warn "DO_GITHUB=1 but GITHUB_TOKEN unset — skipping"; return 0; }
  log "GitHub source intelligence"
  mkdir -p "$OUT/github"

  if have github-endpoints; then
    log "github-endpoints (API paths mined from code)"
    github-endpoints -d "$TARGET" -t "$GITHUB_TOKEN" 2>/dev/null | sort -u > "$OUT/github/endpoints.txt" || true
    local gen; gen=$(grep -c . "$OUT/github/endpoints.txt" 2>/dev/null); gen=${gen:-0}
    [ "$gen" -gt 0 ] && lead MED "GitHub-mined endpoints ($gen)" "github/endpoints.txt — internal API paths from developer code; fold into idor/api testing"
  fi

  # deep-scan a specific repo if named
  if [ -n "${GITHUB_REPO:-}" ]; then
    local url="$GITHUB_REPO"; case "$url" in http*|git@*) : ;; */*) url="https://github.com/$GITHUB_REPO";; esac
    local dst="$OUT/github/repo"
    log "cloning $url (shallow)"
    rm -rf "$dst"
    if git clone --depth 1 "$url" "$dst" >/dev/null 2>&1; then
      if have gitleaks; then
        gitleaks detect --source "$dst" --report-format json --report-path "$OUT/github/gitleaks.json" --no-banner >/dev/null 2>&1 || true
        local gl; gl=$(jq 'length' "$OUT/github/gitleaks.json" 2>/dev/null); gl=${gl:-0}
        [ "$gl" -gt 0 ] && lead HIGH "gitleaks secrets in $GITHUB_REPO ($gl)" "github/gitleaks.json — VERIFY each; deleted-but-in-history secrets often still live"
      fi
      if have trufflehog; then
        trufflehog git "file://$dst" --no-update -j 2>/dev/null > "$OUT/github/trufflehog.jsonl" || true
        local tv; tv=$(grep -c '"Verified":true' "$OUT/github/trufflehog.jsonl" 2>/dev/null); tv=${tv:-0}
        [ "$tv" -gt 0 ] && lead HIGH "trufflehog VERIFIED secrets in repo ($tv)" "github/trufflehog.jsonl — LIVE credentials in $GITHUB_REPO history"
      fi
      lead LOW "securitycontext.dev — build the hunting map" "repo $GITHUB_REPO is OSS: call get_security_context + get_vulnerability_leads (MCP) to turn its fix history into ranked variant leads"
    else
      warn "clone failed: $url"
    fi
  else
    lead LOW "GitHub deep-scan available" "set GITHUB_REPO=owner/name to gitleaks+trufflehog a specific repo; and if OSS, run securitycontext.dev get_vulnerability_leads via MCP"
  fi
}
