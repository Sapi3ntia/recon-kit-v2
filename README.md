# recon-kit-v2 — 2026 "stay or leave" triage, tuned for what actually pays

Same one question as [recon-kit](../recon-kit) v1 — **is there a primitive here
worth my time?** — re-tuned for the 2026 reality and re-built as modules. It does the
*mechanical* discovery + primitive extraction, ranks it, and hands you a ranked
`LEADS.md`, a **self-contained `report.html`**, and a STAY/LEAVE verdict. It does
**not** exploit — when a lead is real, YOU load exactly one `hunt-*` skill (map below).

> **v1 or v2?** v1 is the lean two-script original and stays as-is. v2 is the successor:
> modular, and it maps five surfaces v1 was blind to. If you want the smallest thing that
> works, v1 is still great. If you want the 2026-tuned surface, use v2. They are separate
> projects on purpose.

## Why v2 exists (what changed since v1)

The 2025 HackerOne HPSR + the current disclosed-report stream moved the goalposts:

- **Access-control / IDOR / BOLA displaced XSS** as the dominant *paid* class. Logic and
  authz flaws pay the most. Pattern bugs (reflected XSS, open redirect) are increasingly
  eaten by hackbots — **XSS was 78% of valid *bot* findings**, so a human competing on
  them loses. Humans win on access-control, logic, and chains.
- **AI/LLM surface exploded** — valid AI findings +210% YoY, prompt-injection reports
  +540%, AI in scope on 1,121 programs (+270%). No mainstream recon tool's *discovery*
  phase maps this yet.
- **AST beats regex on JS.** On the same Fortune-500 bundles, `jsluice` (tree-sitter AST)
  found **312** endpoints where regex found **47** — modern bundlers hide URLs in string
  concat / template literals regex structurally can't see.
- **Sourcemaps are exploitable, not just detectable.** If a `.map` is reachable you can
  reconstruct the *original* source (routes, comments, logic, secrets) — v1 only flagged it.

So v2 doubles down on what a human gets paid for, and refuses to become a scanner:

| New in v2 | Module | Why |
|---|---|---|
| AST endpoint/secret extraction (`jsluice`) + regex fallback | `lib/js.sh` | 6× the routes; the route list *is* the attack surface |
| Sourcemap **unpacking** (`sourcemapper`) → re-grep original source | `lib/js.sh` | recovers routes/logic/secrets, not just a HIGH flag |
| **IDOR/BOLA candidate** extraction + ranking | `lib/idor.sh` | the #1 paid class; surfaces the best endpoints to 2-account test |
| **AI/LLM surface** map (endpoints, keys, SDKs, system prompts, MCP/ai-plugin) | `lib/aisurface.sh` | the 2026 differentiator nothing else maps |
| Origin-IP behind WAF (favicon `mmh3` → Shodan/FOFA) | `lib/origin.sh` | bypass the WAF entirely — recurring high-value pivot |
| GitHub source intel + `securitycontext.dev` hook | `lib/github.sh` | dev repos leak endpoints/secrets; fix-history → variant leads |
| Cloud bucket enum + public-access check (curl-only, zero deps) | `lib/cloud.sh` | S3/GCS/Azure listable storage = fast HIGH |
| Takeover **confirmation** (`subzy`/`nuclei`), not just candidates | `lib/probe.sh` | v1 flagged dangling CNAMEs; v2 confirms them |
| Self-contained **`report.html`** — verdict + leads + screenshots + browsable surface | `lib/report.sh` | the "GUI" the kit was missing, in one offline file |

Everything active stays **opt-in and quiet by default** (exactly like v1). The cheap,
high-signal upgrades (jsluice, sourcemaps, AI surface, IDOR surfacing, takeover confirm)
default **ON**; anything that needs a key or touches a third party defaults **OFF**.

## Layout

```
rkv2.sh          orchestrator: wildcard | host | js | full  → runs the module chain, writes LEADS.md + report.html
_common.sh       shared knobs, 2026 signal packs (secret/route/AI/IDOR), CURL_HDR, lead()/verdict(), helpers
lib/enum.sh      passive subdomain enum + CNAME-takeover candidate capture
lib/probe.sh     httpx fingerprint → rank hosts → screenshots → takeover CONFIRMATION → optional ports
lib/urls.sh      gau + waybackurls + katana URL/JS harvest on the ranked hosts
lib/js.sh        ★ AST extraction (jsluice) + sourcemap UNPACK + regex fallback → routes/secrets/sinks
lib/secrets.sh   opt-in trufflehog live-verification over JS corpus + unpacked source
lib/aisurface.sh ★ AI/LLM endpoints, provider keys, SDKs, embedded system prompts, MCP/ai-plugin probe
lib/idor.sh      ★ IDOR/BOLA candidate extraction + ranking (surface only — no exploit)
lib/api.sh       GraphQL introspection probe, gf classification, arjun (opt-in), API version/prefix permutation
lib/origin.sh    opt-in origin-IP behind WAF via favicon mmh3 → Shodan/FOFA
lib/github.sh    opt-in GitHub endpoint/secret mining + securitycontext.dev MCP hook
lib/cloud.sh     opt-in S3/GCS/Azure bucket enum + public-access check (curl only)
lib/report.sh    self-contained report.html generator (theme-aware, screenshots inlined)
tests/selftest.sh  offline self-test (signal packs + IDOR/AI extractors + verdict + report), no network
```

## Which mode

| Scope you were given | Run | Why |
|---|---|---|
| `*.target.com` (wildcard) | `./rkv2.sh wildcard target.com` | breadth: enum → rank → deep JS/AI/IDOR map across many hosts |
| `target.com` / one host | `./rkv2.sh host https://app.target.com` | depth on one app: full JS + sourcemaps + API + AI + IDOR |
| one page's client-side surface | `./rkv2.sh js https://app.target.com/route` | BFS from one page (follows federation remotes / dynamic chunks) → source→sink + AI/IDOR |
| `*.target.com`, want it end-to-end | `./rkv2.sh full target.com` | wildcard, then auto-descends into the **hottest** host at host-depth |
| program **forbids** sub-enum | `./rkv2.sh host <host>` per in-scope host | never enumerate DNS where it's banned |

```bash
cd ~/bughunt/targets/<target> && source .env      # loads the knobs for THIS program
~/bughunt/recon-kit-v2/rkv2.sh wildcard target.com
```

Output: `recon/<target>/{subs,live,urls,js,ai,idor,github,cloud,screenshots}/` + `LEADS.md`
+ **`report.html`** (open it — verdict banner, ranked leads, screenshots inlined, browsable
routes/secrets/AI-surface/IDOR candidates, all in one offline file).

## Knobs — set in the target `.env`, from the program's rules

Every knob defaults to the safe/quiet value. Same platform-agnostic attribution as v1
(`RECON_HEADER`, or `INTIGRITI_USERNAME` shortcut).

**Cheap + high-signal → default ON** (flip off only if noisy / out-of-scope):

| Knob (default) | Off = | What it does |
|---|---|---|
| `USE_JSLUICE` (1) | regex-only | AST route/secret extraction; falls back to regex if `jsluice` missing |
| `PULL_SOURCEMAPS` (1) | detect-only | fetch + unpack exposed `.map` → original source, then re-grep it |
| `DO_AISURFACE` (1) | — | map AI/LLM endpoints / keys / SDKs / system prompts / MCP manifests |
| `DO_IDOR` (1) | — | extract + rank IDOR/BOLA candidates (surface only) |
| `CONFIRM_TAKEOVER` (1) | candidates-only | `subzy`/`nuclei` confirm on dangling-CNAME candidates |

**Touches third parties / needs a key → default OFF:**

| Knob (default) | On = | Needs |
|---|---|---|
| `DO_ORIGIN` (0) | origin-IP favicon pivot | `SHODAN_API_KEY` or `FOFA_EMAIL`+`FOFA_KEY` (hash is computed free without them) |
| `DO_GITHUB` (0) | GitHub endpoint/secret mining | `GITHUB_TOKEN`; optional `GITHUB_REPO=owner/name` for a deep repo scan |
| `DO_CLOUD` (0) | S3/GCS/Azure bucket enum | nothing (curl only); `CLOUD_WORDS` adds custom bucket-name parts |
| `RUN_NUCLEI` (0) | nuclei on the hot host | `NUCLEI_TAGS` / `NUCLEI_SEV` to scope it |
| `DO_PORTS` (0) | naabu top-100 on ranked hosts | — (`NAABU_RATE` pkts/s) |
| `PARAM_DISCOVERY` (0) | arjun hidden-param discovery (active) | — (host/full mode only, `ARJUN_MAX`) |
| `DEEP_SECRETS` (0) | trufflehog live-verify over corpus + unpacked source | `trufflehog` |

Shared reach/politeness knobs carry over from v1: `RATE` (5) · `THREADS` (40) ·
`TOP_HOSTS` (15) · `KATANA_DEPTH` (2) · `JS_MAX` (300, cap on JS bodies fetched) ·
`API_PREFIXES` · `CHAOS_API_KEY`.

## Tools it uses (all optional — each feature degrades gracefully if a tool is missing)

Core: `subfinder` `assetfinder` `amass` `dnsx` `httpx` `gau` `waybackurls` `katana`
`jq` `curl`. v2 additions: **`jsluice`** (AST), **`sourcemapper`** (sourcemap unpack),
`subzy` (takeover confirm), `gowitness`/`aquatone`/`chromium` (screenshots).
Opt-in: `naabu` `arjun` `ffuf` `gf` `nuclei` `trufflehog` `mantra` `gitleaks`
`github-subdomains` `github-endpoints`, plus `python3`+`mmh3` for the favicon pivot.
Cloud enum needs **nothing** beyond curl.

Install the two that matter most:
```bash
go install github.com/BishopFox/jsluice/cmd/jsluice@latest
go install github.com/denandz/sourcemapper@latest
```

## Driving it with an AI (the per-target ritual — unchanged from v1)

You don't memorize knobs. In an agent that reads your filesystem (Claude Code here), it
reads this README + the modules directly. You give it the one thing that changes per
target — **the scope** — and it maps rules → knob table → writes `scope_map.md` + `.env`,
tells you wildcard vs per-host, and hands you the command. You approve; you don't configure.

The `securitycontext.dev` and `mempalace` integrations are **agent-driven** (MCP), not CLI:
`lib/github.sh` emits a lead telling the agent to call `get_security_context` /
`get_vulnerability_leads` when a target repo is known — turning a repo's fix-commit history
into a ranked variant-hunting map. That's a deliberate design choice: the "control panel"
for this kit is the agent reading the filesystem, not a web UI.

## SKILL MAP — load ONE when a lead confirms

| LEADS.md signal | load skill |
|---|---|
| Secrets in JS / sourcemaps / `.git` / `.env` / trufflehog-verified | `secrets-hunt` → `hunt-source-leak` → `cloud-iam-deep` |
| **IDOR: owner-object / GraphQL node() / seq-int** (2 accounts) | `hunt-idor` (needs `auth_A.env` + `auth_B.env`) / `hunt-graphql` |
| **AI/LLM endpoint / embedded system prompt / MCP manifest** | `hunt-prompt-injection` / `hunt-llm` (test unauth access + IDOR on conversation ids too) |
| **AI provider key in JS** | `secrets-hunt` (billing abuse + data access; VERIFY scope first) |
| Subdomain-takeover **confirmed** | `/takeover` → `hunt-subdomain` |
| GraphQL introspection open | `hunt-graphql` |
| **Public cloud bucket** | `cloud-iam-deep` (enumerate objects, check PII/secrets, confirm scope) |
| **Origin-IP candidate** (favicon) | curl with `Host:` header, diff vs WAF; then normal host recon |
| Hidden params (arjun) / reflected param / DOM sink | `hunt-xss` / `hunt-dom` |
| URL-fetch / webhook / `redirect=` | `hunt-ssrf` (OOB mandatory) / `hunt-open-redirect` |
| login / SSO / OAuth / SAML | `hunt-oauth` / `hunt-saml` / `hunt-auth-bypass` |
| Next.js / Laravel / Spring / ASP.NET fingerprint | `hunt-nextjs` / `hunt-laravel` / `hunt-springboot` / `hunt-aspnet` |

No signal a skill covers → don't force one. `WebSearch` a 2026 technique on the exact
stack, and `mempalace_search "<stack> <class>"` for a proven PoC, then form a hypothesis.

## Guardrails (same as `~/bughunt/CLAUDE.md`)

Authorized, in-scope testing only. Recon **does not exploit**: IDOR/ATO need a 2-account
A→B test, SSRF needs an OOB callback — this kit only *surfaces and ranks* those. Never
print full bodies/cookies/tokens (status | len | `body[:150]`). Secrets come from env
files. A STAY/LEAVE verdict is a **time-allocation hint**, not a claim about the target —
confirm every lead by hand before reporting.

## After triage

1. Open `report.html` (or read `LEADS.md`) — the verdict line is your stay/leave at a glance.
2. **STAY**: pick the top lead, state a one-line hypothesis, load its skill, fire the
   minimum test. Record in `funnel/<target>/`.
3. **LEAVE**: 2-line "DEAD: nothing surfaced" and move on. Not every target has a bug;
   the point of the kit is to find that out in minutes, not hours.

## Test

```bash
bash tests/selftest.sh     # 37 offline assertions: signal packs + IDOR/AI extractors + verdict + report
```
