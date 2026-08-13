#!/usr/bin/env bash
# _common.sh (recon-kit-v2) — shared helpers + 2026 signal packs.
# Sourced by rkv2.sh and every lib/*.sh module. NOT run directly.
#
# Philosophy (unchanged from recon-kit v1, sharpened for 2026): do the MECHANICAL
# discovery + primitive extraction fast and cheaply, rank it, and hand the human a
# ranked LEADS.md + a browsable report.html + a STAY/LEAVE verdict. Do NOT exploit.
#
# What v2 adds over v1 — driven by the 2025 HackerOne HPSR reality (access-control /
# IDOR / logic pay the most now; hackbots eat the pattern bugs; AI surface exploded;
# AST beats regex): AST-accurate JS extraction (jsluice), sourcemap UNPACKING, and
# five surfaces v1 was blind to — AI/LLM, IDOR/BOLA candidates, origin-IP, GitHub,
# cloud — plus a self-contained HTML map. It optimises for what a HUMAN gets paid for.

# ---- knobs (override via env / target .env) ----------------------------------
: "${RATE:=5}"                 # max req/sec for active tools (politeness ceiling)
: "${THREADS:=40}"
: "${TOP_HOSTS:=15}"           # ranked hosts that get the deep JS pull (wildcard)
: "${KATANA_DEPTH:=2}"
: "${JS_MAX:=300}"             # cap JS bodies fetched per run (politeness / wall-clock)
: "${NUCLEI_TAGS:=exposure,misconfig,takeover,config}"
: "${NUCLEI_SEV:=medium,high,critical}"
: "${API_PREFIXES:=v1 v2 v3 internal private admin beta staging public}"
: "${TOOL_TIMEOUT:=150}"       # per external-tool wall-clock cap in seconds (0 = no cap).
                               # A slow/hung archive (gau→CommonCrawl) must never stall the run.

# opt-in LOUD toggles (default = safe/quiet, exactly like v1)
: "${PASSIVE_ONLY:=1}"         # 1 = passive sub-enum only
: "${DO_PORTS:=0}"             # 1 = naabu top-100 connect scan on ranked hosts
: "${NAABU_RATE:=500}"
: "${RUN_NUCLEI:=0}"           # nuclei is opt-in
: "${PARAM_DISCOVERY:=0}"      # 1 = arjun hidden-param discovery (active fuzzing)
: "${DEEP_SECRETS:=0}"         # 1 = trufflehog entropy/verified scan over harvested corpus
: "${ARJUN_MAX:=25}"

# v2 module toggles — these are CHEAP + high-signal, so default ON (flip off if noisy/OOS)
: "${USE_JSLUICE:=1}"          # 1 = AST route/secret extraction (falls back to regex if missing)
: "${PULL_SOURCEMAPS:=1}"      # 1 = fetch + unpack exposed .map -> original source, re-grep it
: "${DO_AISURFACE:=1}"         # 1 = detect AI/LLM endpoints / keys / SDKs / system prompts
: "${DO_IDOR:=1}"              # 1 = extract + rank IDOR/BOLA candidates (surface only, no exploit)
: "${CONFIRM_TAKEOVER:=1}"     # 1 = subzy/nuclei confirm on CNAME takeover candidates

# v2 module toggles — these touch 3rd parties / need keys, so default OFF
: "${DO_ORIGIN:=0}"            # 1 = origin-IP behind WAF (favicon hash -> Shodan/FOFA, historical DNS)
: "${DO_GITHUB:=0}"           # 1 = GitHub source intel (needs GITHUB_TOKEN); ties to securitycontext.dev
: "${DO_CLOUD:=0}"            # 1 = S3/GCS/Azure bucket enum + public-access check

# ---- credentials / keys (all optional; empty = feature degrades gracefully) ---
: "${CHAOS_API_KEY:=}"         # ProjectDiscovery Chaos (extra passive subs)
: "${SHODAN_API_KEY:=}"        # origin-IP favicon pivot + host intel
: "${FOFA_EMAIL:=}"; : "${FOFA_KEY:=}"   # FOFA favicon pivot (alt to Shodan)
: "${GITHUB_TOKEN:=}"          # github-subdomains / github-endpoints / gitleaks / trufflehog github

# ---- program attribution header (platform-agnostic, unchanged from v1) --------
: "${RECON_HEADER:=}"
: "${INTIGRITI_USERNAME:=}"
if [ -z "$RECON_HEADER" ] && [ -n "$INTIGRITI_USERNAME" ]; then
  RECON_HEADER="X-Intigriti-Username: $INTIGRITI_USERNAME"
fi
: "${USER_AGENT:=Mozilla/5.0 (X11; Linux x86_64) recon-kit-v2/2.0}"

CURL_HDR=(-A "$USER_AGENT")
HDR_ARGS=(-H "User-Agent: $USER_AGENT")
if [ -n "$RECON_HEADER" ]; then
  CURL_HDR+=(-H "$RECON_HEADER")
  HDR_ARGS+=(-H "$RECON_HEADER")
fi
ARJUN_HEADERS="User-Agent: $USER_AGENT"
[ -n "$RECON_HEADER" ] && ARJUN_HEADERS="$ARJUN_HEADERS"$'\n'"$RECON_HEADER"

c_grn=$'\e[32m'; c_yel=$'\e[33m'; c_cyn=$'\e[36m'; c_red=$'\e[31m'; c_rst=$'\e[0m'
log(){  printf '%s[*]%s %s\n' "$c_cyn" "$c_rst" "$*" >&2; }
ok(){   printf '%s[+]%s %s\n' "$c_grn" "$c_rst" "$*" >&2; }
warn(){ printf '%s[!]%s %s\n' "$c_yel" "$c_rst" "$*" >&2; }
err(){  printf '%s[x]%s %s\n' "$c_red" "$c_rst" "$*" >&2; }
have(){ command -v "$1" >/dev/null 2>&1; }
# to CMD... — run an external tool under TOOL_TIMEOUT so a slow network source can't
# stall the pipeline. Falls through untimed if the knob is 0 or `timeout` is absent.
# Preserves stdin redirection (timeout inherits our fds), so `to gau < seed | anew` works.
to(){ if [ "${TOOL_TIMEOUT:-0}" -gt 0 ] && have timeout; then timeout "$TOOL_TIMEOUT" "$@"; else "$@"; fi; }

# ---- signal packs (used with: grep -E -i) ------------------------------------
# High-signal secret patterns. v2 adds 2026 AI-provider + modern token formats.
RE_SECRET='AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{35}|ya29\.[0-9A-Za-z_-]{20,}|xox[baprs]-[0-9A-Za-z-]{10,48}|sk_live_[0-9A-Za-z]{20,}|rk_live_[0-9A-Za-z]{20,}|sk-ant-[A-Za-z0-9_-]{20,}|sk-(proj|svcacct|admin)?-?[A-Za-z0-9_-]{20,}T3BlbkFJ[A-Za-z0-9_-]{20,}|hf_[A-Za-z0-9]{30,}|github_pat_[0-9A-Za-z_]{22,}|gh[pousr]_[0-9A-Za-z]{36,}|glpat-[0-9A-Za-z_-]{20}|npm_[A-Za-z0-9]{36}|SG\.[A-Za-z0-9_.-]{22}\.[A-Za-z0-9_.-]{43}|SK[0-9a-f]{32}|PMAK-[0-9a-f]{24}-[0-9a-f]{34}|dop_v1_[a-f0-9]{64}|eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|(client[_-]?secret|api[_-]?key|secret[_-]?key|access[_-]?token|auth[_-]?token|bearer)["'"'"'`:= ]{1,4}[A-Za-z0-9_/+.-]{16,}'

# Interesting relative routes embedded in JS / responses.
RE_ROUTE='/(api|v[0-9]|graphql|gql|admin|internal|oauth|auth|sso|login|account|users?|upload|files?|import|export|webhook|callback|proxy|fetch|redirect|debug|actuator|swagger|openapi|\.git|\.env)[A-Za-z0-9_./{}:-]*'

# Client-side DOM sinks (XSS / postMessage recon).
RE_SINK='innerHTML|outerHTML|insertAdjacentHTML|document\.write|\beval\(|new Function|location\.(href|hash|search|assign|replace)|postMessage|addEventListener\(["'"'"'`]message|dangerouslySetInnerHTML|\.html\('

# Hosts worth looking at first (matched on host+title+tech).
RE_HOST_INTEREST='admin|staging|stage|dev|test|qa|uat|internal|intranet|jenkins|grafana|kibana|swagger|graphql|gitlab|jira|confluence|portal|vpn|sso|oauth|backend|legacy|old|beta|preprod|sandbox|api|dashboard|console'

# --- v2: AI / LLM attack-surface packs (the 2026 differentiator) --------------
# AI/LLM endpoints (OpenAI-style, generic chat/assistant, MCP, AI plugin manifests).
RE_AI_ROUTE='/(v[0-9]+/(chat/completions|completions|embeddings|responses|messages|assistants|threads|runs|images/generations)|api/(chat|ai|llm|assistant|copilot|agent|completion|complete|generate|prompt|inference|rag|embed))|chat/stream|/\.well-known/(ai-plugin\.json|mcp|openai\.json)|/mcp(/|$)'
# LLM SDKs / vector DBs shipped in bundles = an AI feature exists here.
RE_AI_SDK='openai|anthropic|@anthropic-ai|claude|langchain|langgraph|llamaindex|llama_index|cohere|@huggingface|huggingface|vercel[/-]?ai|"ai-sdk"|ai/react|mistral|groq-sdk|pinecone|weaviate|chromadb|qdrant|ollama|litellm|semantic-kernel|autogen'
# Embedded system prompts / guardrail strings leaking in client code.
RE_AI_PROMPT='[Yy]ou are (a|an|the) [a-z]|[Ss]ystem prompt|[Yy]ou must not|[Dd]o not reveal|[Ii]gnore (all )?previous instructions|[Aa]s an AI( language)? model|You are ChatGPT|You are Claude|assistant that'

# --- v2: IDOR / BOLA candidate packs (the #1 paid class in 2026) ---------------
# Params that name an object owned by someone -> object-level authz test surface.
RE_IDOR_PARAM='(user|account|acct|org|organi[sz]ation|tenant|customer|company|group|team|project|workspace|member|profile|employee|client|invoice|order|payment|card|doc|document|file|report|ticket|record|entity|object|item|booking|subscription|message|conversation)[_-]?(id|uuid|guid|no|number|key)'
# ID-shaped path segments: long ints, UUIDs, Mongo ObjectIds -> sequential/substitution tests.
RE_ID_UUID='[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
RE_ID_MONGO='\b[0-9a-f]{24}\b'
RE_ID_INT='/[0-9]{3,}(/|$|\?)'
# GraphQL global-id / node() substitution surface (Relay pattern).
RE_GQL_NODE='node\(|nodes\(|globalId|toGlobalId|fromGlobalId|"__typename"|Relay|"id":"[A-Za-z][A-Za-z0-9]+:'

# ---- LEADS.md + verdict ------------------------------------------------------
# Caller sets:  LEADS=<path>  before calling lead()/verdict().
lead(){ # sev(HIGH|MED|LOW)  title  detail
  printf -- '- [%s] **%s** — %s\n' "$1" "$2" "$3" >> "$LEADS"
}

# shoot URLS_FILE OUTDIR — thumbnails so a human eyeballs admin-vs-parked at a glance.
shoot(){
  local list="$1" dir="$2"; mkdir -p "$dir"; [ -s "$list" ] || return 0
  if have gowitness; then
    gowitness scan file -f "$list" --screenshot-path "$dir" --write-db=false >/dev/null 2>&1 \
      || gowitness file -f "$list" --screenshot-path "$dir" >/dev/null 2>&1 || true
  elif have aquatone; then
    aquatone -out "$dir" < "$list" >/dev/null 2>&1 || true
  elif have chromium || have chromium-browser; then
    local bin; bin=$(command -v chromium || command -v chromium-browser); local i=0
    while IFS= read -r u && [ "$i" -lt 25 ]; do
      local name; name=$(printf '%s' "$u" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g')
      "$bin" --headless=new --disable-gpu --no-sandbox --hide-scrollbars \
             --window-size=1280,800 --timeout=15000 \
             --screenshot="$dir/$name.png" "$u" >/dev/null 2>&1 || true
      i=$((i+1))
    done < "$list"
  else
    warn "no screenshot tool (gowitness/aquatone/chromium) — skipping thumbnails"; return 0
  fi
  ok "screenshots -> $dir"
}

# probe_secret_files BASE_URL ROUTES_FILE — content-verify exposed .git/.env (not just 200).
probe_secret_files(){
  local base="${1%/}" routes="$2" body
  if grep -qi '\.git' "$routes" 2>/dev/null; then
    body=$(curl -s -m 10 "${CURL_HDR[@]}" "$base/.git/config" 2>/dev/null)
    if printf '%s' "$body" | grep -qiE '\[core\]|repositoryformatversion' \
       && ! printf '%s' "$body" | grep -qiE '<html|<!doctype'; then
      lead HIGH "Exposed .git CONFIRMED ($base)" "$base/.git/config returns repo config — git-dumper it; load hunt-source-leak"
    fi
  fi
  if grep -qi '\.env' "$routes" 2>/dev/null; then
    body=$(curl -s -m 10 "${CURL_HDR[@]}" "$base/.env" 2>/dev/null)
    if printf '%s' "$body" | grep -qiE '^[A-Za-z][A-Za-z0-9_]*=' \
       && ! printf '%s' "$body" | grep -qiE '<html|<!doctype'; then
      lead HIGH "Exposed .env CONFIRMED ($base)" "$base/.env returns key=value secrets — VERIFY keys (keyhacks); load secrets-hunt"
    fi
  fi
}

# Map a fingerprint string -> the skill you should load. Echoes a suggestion line.
skill_for(){ # haystack
  local h; h=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$h" in
    *next.js*|*_next*|*__next_data__*) echo "hunt-nextjs (server actions / middleware auth / RSC)";;
    *laravel*)                         echo "hunt-laravel (debug mode, deserialization, mass-assign)";;
    *spring*|*actuator*)               echo "hunt-springboot (actuator heapdump/env/gateway)";;
    *asp.net*|*viewstate*|*__viewstate*) echo "hunt-aspnet (ViewState deser, trace.axd)";;
    *graphql*|*graphiql*|*apollo*)     echo "hunt-graphql (introspection, batching, IDOR via node())";;
    *wordpress*|*wp-*)                 echo "hunt-misc/wp (xmlrpc, REST users, plugin CVEs)";;
    *)                                 echo "";;
  esac
}

verdict(){
  local hi me lo
  hi=$(grep -c '^- \[HIGH\]' "$LEADS" 2>/dev/null || true); hi=${hi:-0}
  me=$(grep -c '^- \[MED\]'  "$LEADS" 2>/dev/null || true); me=${me:-0}
  lo=$(grep -c '^- \[LOW\]'  "$LEADS" 2>/dev/null || true); lo=${lo:-0}
  local v
  if   [ "$hi" -ge 1 ];               then v="STAY — confirmed high-signal primitive(s) present.";
  elif [ "$me" -ge 3 ];               then v="STAY — multiple medium leads; one deserves an hour.";
  elif [ "$me" -ge 1 ] || [ "$lo" -ge 5 ]; then v="MAYBE — thin. Skim the top lead, then decide.";
  else                                     v="LEAVE — no primitive surfaced. Don't sink time here.";
  fi
  { echo; echo "## VERDICT"; echo "_HIGH=$hi  MED=$me  LOW=${lo}_"; echo; echo "**$v**"; } >> "$LEADS"
  VERDICT_LINE="$v"; VERDICT_HI="$hi"; VERDICT_ME="$me"; VERDICT_LO="$lo"
  ok "VERDICT: $v  (HIGH=$hi MED=$me LOW=$lo)"
}

# slug URL -> filesystem-safe name
slug(){ printf '%s' "$1" | sed -E 's#https?://##; s#[^A-Za-z0-9._-]#_#g' | cut -c1-120; }

# fetch_js_corpus JS_URL_LIST DEST_DIR  — download JS bodies to a dir (for jsluice/trufflehog/mantra).
# Rate-limited, size-capped, honours JS_MAX. Prints count fetched. Reused by js/secrets/aisurface.
fetch_js_corpus(){
  local list="$1" dest="$2"; mkdir -p "$dest"
  local sleep_s; sleep_s=$(awk "BEGIN{ r=${RATE}; if (r<=0) r=1; print 1/r }")
  local n=0 u body
  while IFS= read -r u && [ "$n" -lt "$JS_MAX" ]; do
    [ -z "$u" ] && continue
    body=$(curl -sL -m 12 --max-filesize 8000000 "${CURL_HDR[@]}" "$u" 2>/dev/null) || { sleep "$sleep_s"; continue; }
    [ -z "$body" ] && { sleep "$sleep_s"; continue; }
    printf '%s' "$body" > "$dest/$(slug "$u").js"
    n=$((n+1)); sleep "$sleep_s"
  done < "$list"
  printf '%s' "$n"
}
