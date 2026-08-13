#!/usr/bin/env bash
# lib/report.sh — self-contained, theme-aware HTML triage map (the aligned "GUI").
# Not a control panel (that would fight the AI-driven design); it's the OUTPUT viewer the
# kit was missing: verdict banner + ranked leads + screenshots inlined + browsable
# routes/secrets/AI/IDOR/subs, all in ONE file you open in a browser. Zero deps, offline.

_html_escape(){ sed -e 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

# _panel TITLE FILE LIMIT  — collapsible <details> with the head of a file (escaped)
_panel(){
  local title="$1" file="$2" limit="${3:-200}" n
  [ -s "$file" ] || return 0
  n=$(grep -c . "$file" 2>/dev/null); n=${n:-0}
  { printf '<details><summary>%s <span class=count>%s</span></summary><pre>' "$title" "$n"
    head -n "$limit" "$file" | _html_escape
    printf '</pre></details>\n'; } >> "$REPORT"
}

mod_report(){
  REPORT="$OUT/report.html"
  local banner_class="leave"
  case "$VERDICT_LINE" in STAY*) banner_class="stay";; MAYBE*) banner_class="maybe";; esac
  local now; now=$(date -u +%FT%TZ)

  # ---- head + header + verdict ----
  cat > "$REPORT" <<HTMLHEAD
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>recon-kit-v2 — ${TARGET}</title>
<style>
:root{--bg:#f6f7f9;--panel:#fff;--fg:#1a1d21;--mut:#5b6470;--bd:#e3e6ea;--hi:#d11149;--me:#d9822b;--lo:#3a7ca5;--stay:#1a7f37;--maybe:#d9822b;--leave:#6b7280;--code:#f0f2f4}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--panel:#161b22;--fg:#e6edf3;--mut:#8b949e;--bd:#30363d;--hi:#ff5c8a;--me:#e3a008;--lo:#5aa9d6;--stay:#3fb950;--maybe:#e3a008;--leave:#8b949e;--code:#0b0f14}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 -apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif}
.wrap{max-width:1100px;margin:0 auto;padding:24px}
h1{font-size:20px;margin:0 0 2px}.sub{color:var(--mut);font-size:13px;margin-bottom:18px}
.banner{border-radius:12px;padding:16px 20px;margin:0 0 18px;font-weight:600;font-size:17px;color:#fff}
.banner.stay{background:var(--stay)}.banner.maybe{background:var(--maybe)}.banner.leave{background:var(--leave)}
.counts{display:flex;gap:10px;margin:0 0 20px;flex-wrap:wrap}
.chip{border:1px solid var(--bd);border-radius:999px;padding:5px 13px;font-size:13px;background:var(--panel)}
.chip b{font-size:15px}.chip.hi b{color:var(--hi)}.chip.me b{color:var(--me)}.chip.lo b{color:var(--lo)}
h2{font-size:15px;margin:26px 0 10px;color:var(--mut);text-transform:uppercase;letter-spacing:.04em}
.lead{background:var(--panel);border:1px solid var(--bd);border-left:4px solid var(--bd);border-radius:8px;padding:11px 14px;margin:8px 0}
.lead.HIGH{border-left-color:var(--hi)}.lead.MED{border-left-color:var(--me)}.lead.LOW{border-left-color:var(--lo)}
.lead .sev{font-size:11px;font-weight:700;letter-spacing:.05em;padding:2px 7px;border-radius:4px;color:#fff;margin-right:8px}
.lead.HIGH .sev{background:var(--hi)}.lead.MED .sev{background:var(--me)}.lead.LOW .sev{background:var(--lo)}
.lead .t{font-weight:600}.lead .d{color:var(--mut);font-size:13px;margin-top:3px}
.gal{display:grid;grid-template-columns:repeat(auto-fill,minmax(240px,1fr));gap:12px}
.gal figure{margin:0;background:var(--panel);border:1px solid var(--bd);border-radius:8px;overflow:hidden}
.gal img{width:100%;display:block;aspect-ratio:16/10;object-fit:cover;object-position:top}
.gal figcaption{font-size:11px;color:var(--mut);padding:6px 8px;word-break:break-all}
details{background:var(--panel);border:1px solid var(--bd);border-radius:8px;margin:8px 0}
summary{cursor:pointer;padding:10px 14px;font-weight:600}
.count{color:var(--mut);font-weight:400;font-size:12px}
pre{margin:0;padding:12px 14px;background:var(--code);overflow-x:auto;font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace;border-top:1px solid var(--bd);max-height:420px}
footer{color:var(--mut);font-size:12px;margin-top:30px;border-top:1px solid var(--bd);padding-top:12px}
</style></head><body><div class=wrap>
<h1>recon-kit-v2 &middot; ${TARGET}</h1>
<div class=sub>mode <b>${MODE}</b> &middot; ${URL} &middot; ${now}</div>
<div class="banner ${banner_class}">${VERDICT_LINE}</div>
<div class=counts>
<span class="chip hi">HIGH <b>${VERDICT_HI}</b></span>
<span class="chip me">MED <b>${VERDICT_ME}</b></span>
<span class="chip lo">LOW <b>${VERDICT_LO}</b></span>
</div>
<h2>Leads</h2>
HTMLHEAD

  # ---- leads (parse LEADS.md lines: "- [SEV] **title** — detail") ----
  local sev title detail
  while IFS= read -r line; do
    case "$line" in
      "- ["*)
        sev=$(printf '%s' "$line" | sed -E 's/^- \[([A-Z]+)\].*/\1/')
        title=$(printf '%s' "$line" | sed -E 's/^- \[[A-Z]+\] \*\*(.*)\*\* — .*/\1/' | _html_escape)
        detail=$(printf '%s' "$line" | sed -E 's/^- \[[A-Z]+\] \*\*.*\*\* — (.*)/\1/' | _html_escape)
        printf '<div class="lead %s"><span class=sev>%s</span><span class=t>%s</span><div class=d>%s</div></div>\n' \
          "$sev" "$sev" "$title" "$detail" >> "$REPORT";;
    esac
  done < "$LEADS"
  grep -q 'class="lead' "$REPORT" || printf '<p class=sub>No leads surfaced.</p>\n' >> "$REPORT"

  # ---- screenshots gallery (inline base64) ----
  local imgs; imgs=$(find "$OUT/screenshots" -type f \( -name '*.png' -o -name '*.jpeg' -o -name '*.jpg' \) 2>/dev/null | head -30)
  if [ -n "$imgs" ]; then
    printf '<h2>Screenshots</h2><div class=gal>\n' >> "$REPORT"
    while IFS= read -r img; do
      [ -f "$img" ] || continue
      [ "$(wc -c < "$img")" -gt 2500000 ] && continue
      local b64 ext mime; b64=$(base64 -w0 "$img" 2>/dev/null) || continue
      ext="${img##*.}"; mime="png"; [ "$ext" = jpg ] || [ "$ext" = jpeg ] && mime="jpeg"
      printf '<figure><img src="data:image/%s;base64,%s" loading=lazy><figcaption>%s</figcaption></figure>\n' \
        "$mime" "$b64" "$(basename "$img" | _html_escape)" >> "$REPORT"
    done <<<"$imgs"
    printf '</div>\n' >> "$REPORT"
  fi

  # ---- detail panels ----
  printf '<h2>Surface detail</h2>\n' >> "$REPORT"
  _panel "AI/LLM endpoints"          "$OUT/ai/endpoints.txt"     150
  _panel "AI provider keys"          "$OUT/ai/keys.txt"          100
  _panel "Embedded system prompts"   "$OUT/ai/prompts.txt"       100
  _panel "LLM SDKs in bundles"       "$OUT/ai/sdks.txt"          100
  _panel "IDOR / BOLA candidates"    "$OUT/idor/candidates.txt"  250
  _panel "Secrets in JS"             "$OUT/js/secrets.txt"       200
  _panel "API routes (regex+jsluice)" "$OUT/js/routes.txt"       300
  _panel "jsluice URLs (AST)"        "$OUT/js/urls.txt"          300
  _panel "DOM sinks"                 "$OUT/js/sinks.txt"         150
  _panel "Cloud buckets"             "$OUT/cloud/hits.txt"       100
  _panel "Origin-IP candidates"      "$OUT/origin/shodan_ips.txt" 100
  _panel "GitHub-mined endpoints"    "$OUT/github/endpoints.txt" 200
  _panel "Takeover candidates"       "$OUT/subs/cname_takeover_candidates.txt" 100
  _panel "Interesting hosts"         "$OUT/live/ranked.txt"      200
  _panel "Subdomains"                "$OUT/subs/all.txt"         500

  printf '<footer>recon-kit-v2 — mechanical triage only; confirm every lead by hand. STAY/LEAVE is a time-allocation hint, not a verdict on the target.</footer>\n</div></body></html>\n' >> "$REPORT"
  ok "report -> $REPORT"
}
