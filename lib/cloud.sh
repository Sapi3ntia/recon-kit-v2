#!/usr/bin/env bash
# lib/cloud.sh — cloud bucket enumeration + public-access check (opt-in, DO_CLOUD=1).
# Dependency-free by design (curl only) — matches the kit's ethos and avoids a fragile
# python/tool dep. Generates bucket-name candidates from the target base name, then checks
# S3 / GCS / Azure Blob. Content-verified: a public LISTING is HIGH; a private-but-present
# bucket (403/AccessDenied) is LOW (still an ACL target). CLOUD_WORDS adds custom names.

: "${CLOUD_WORDS:=assets static media images img files uploads downloads data backup backups db dump dumps prod production dev staging test qa internal private public app web cdn logs export reports docs documents user users content}"

_cloud_base(){ # derive the short brand name from the target apex (target.com -> target)
  printf '%s' "$TARGET" | sed -E 's/\.[a-z.]+$//' | tr 'A-Z' 'a-z' | sed -E 's/[^a-z0-9-]//g'
}

_check_bucket(){ # name -> emits provider hits into files
  local n="$1" body code
  # S3
  body=$(curl -s -m 8 -o - -w '\n%{http_code}' "https://$n.s3.amazonaws.com/" 2>/dev/null)
  code=$(printf '%s' "$body" | tail -1)
  if printf '%s' "$body" | grep -q '<ListBucketResult'; then
    printf 'PUBLIC  s3  https://%s.s3.amazonaws.com/\n' "$n" >> "$OUT/cloud/hits.txt"
  elif printf '%s' "$body" | grep -qE '<Code>AccessDenied|<Code>InvalidAccessKeyId' || [ "$code" = 403 ]; then
    printf 'PRIVATE s3  https://%s.s3.amazonaws.com/\n' "$n" >> "$OUT/cloud/hits.txt"
  fi
  # GCS
  body=$(curl -s -m 8 "https://storage.googleapis.com/$n/" 2>/dev/null)
  if printf '%s' "$body" | grep -q '<ListBucketResult'; then
    printf 'PUBLIC  gcs https://storage.googleapis.com/%s/\n' "$n" >> "$OUT/cloud/hits.txt"
  elif printf '%s' "$body" | grep -qE '<Code>AccessDenied|storage#'; then
    printf 'PRIVATE gcs https://storage.googleapis.com/%s/\n' "$n" >> "$OUT/cloud/hits.txt"
  fi
  # Azure Blob
  body=$(curl -s -m 8 "https://$n.blob.core.windows.net/?comp=list" 2>/dev/null)
  printf '%s' "$body" | grep -q '<EnumerationResults' \
    && printf 'PUBLIC  az  https://%s.blob.core.windows.net/\n' "$n" >> "$OUT/cloud/hits.txt"
}

mod_cloud(){
  log "cloud bucket enumeration (S3/GCS/Azure, curl-only)"
  mkdir -p "$OUT/cloud"; : > "$OUT/cloud/hits.txt"
  local base; base=$(_cloud_base); [ -z "$base" ] && { warn "could not derive base name"; return 0; }
  { printf '%s\n' "$base"
    for w in $CLOUD_WORDS; do printf '%s-%s\n%s%s\n%s.%s\n' "$base" "$w" "$base" "$w" "$base" "$w"; done
  } | sort -u > "$OUT/cloud/candidates.txt"
  local total; total=$(wc -l < "$OUT/cloud/candidates.txt")
  log "checking $total bucket-name candidates"
  local sleep_s; sleep_s=$(awk "BEGIN{ r=${RATE}; if (r<=0) r=1; print 1/r }")
  while IFS= read -r n; do _check_bucket "$n"; sleep "$sleep_s"; done < "$OUT/cloud/candidates.txt"
  sort -u "$OUT/cloud/hits.txt" -o "$OUT/cloud/hits.txt" 2>/dev/null

  local pub priv
  pub=$(grep -c '^PUBLIC'  "$OUT/cloud/hits.txt" 2>/dev/null); pub=${pub:-0}
  priv=$(grep -c '^PRIVATE' "$OUT/cloud/hits.txt" 2>/dev/null); priv=${priv:-0}
  [ "$pub"  -gt 0 ] && lead HIGH "PUBLIC cloud buckets ($pub)" "cloud/hits.txt (PUBLIC) — listable storage; enumerate + check for secrets/PII, confirm scope before download"
  [ "$priv" -gt 0 ] && lead LOW  "Private buckets exist ($priv)" "cloud/hits.txt (PRIVATE) — bucket names confirmed; ACL/write-test targets (upload, object-ACL)"
  ok "cloud: public=$pub private=$priv (from $total candidates)"
}
