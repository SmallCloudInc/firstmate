#!/usr/bin/env bash
# fm-r2-upload.sh — upload image(s) to the shared firstmate R2 bucket and print
# their public URLs, so any firstmate crewmate can embed screenshots / testing
# evidence in a GitHub PR or comment.
#
# Bucket:  firstmate-screenshots  (SmallCloudInc Cloudflare account, public r2.dev)
# Usage:
#   fm-r2-upload.sh [--prefix <slug>] <file> [<file> ...]
#   fm-r2-upload.sh --markdown [--prefix <slug>] <file> [<file> ...]
#
# Options:
#   --prefix <slug>   Key prefix (folder) in the bucket. Default: "<cwd-basename>-<UTC timestamp>".
#                     Use something stable+unique per PR, e.g. "reader-app-pr25".
#   --markdown        Also print a ready-to-paste `![name](url)` line per file.
#
# Output: one public URL per uploaded file on stdout (markdown lines go to stdout too
#         under --markdown). Progress/info goes to stderr.
#
# Requires: wrangler (uses `wrangler` on PATH, else `npx --yes wrangler@4`) authenticated
#           to the SmallCloudInc account (the firstmate build box already is).
set -euo pipefail

BUCKET="firstmate-screenshots"
PUBLIC_BASE="https://pub-94367ac5ad9a457ea2cf82bb71ef2c3f.r2.dev"
# Pin the account — the build box is also authed to other accounts; without this
# wrangler dies with "more than one account available".
export CLOUDFLARE_ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-3c445f673c4e1e5dcca897aa7f6c3c30}"

PREFIX=""
MARKDOWN=0
FILES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)
      if [ $# -lt 2 ]; then
        echo "fm-r2-upload: --prefix requires a value. Usage: fm-r2-upload.sh [--prefix <slug>] <file> ..." >&2
        exit 2
      fi
      PREFIX="$2"; shift 2 ;;
    --markdown) MARKDOWN=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*) echo "fm-r2-upload: unknown option '$1'" >&2; exit 2 ;;
    *) FILES+=("$1"); shift ;;
  esac
done

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "fm-r2-upload: no files given. Usage: fm-r2-upload.sh [--prefix <slug>] <file> ..." >&2
  exit 2
fi

if [ -z "$PREFIX" ]; then
  PREFIX="$(basename "$PWD")-$(date -u +%Y%m%d-%H%M%S)"
fi

if command -v wrangler >/dev/null 2>&1; then
  WRANGLER=(wrangler)
else
  WRANGLER=(npx --yes wrangler@4)
fi

content_type_for() {
  ext="${1##*.}"
  case "$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')" in
    png) echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif) echo "image/gif" ;;
    webp) echo "image/webp" ;;
    svg) echo "image/svg+xml" ;;
    *) echo "application/octet-stream" ;;
  esac
}

# Slugify a filename into a URL-safe object-key segment: any character outside
# [A-Za-z0-9._-] becomes '-', runs collapse, and leading/trailing '-' are trimmed.
safe_key_segment() {
  printf '%s' "$1" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

key_for() {
  local base safe_base
  base="$(basename "$1")"
  safe_base="$(safe_key_segment "$base")"
  [ -n "$safe_base" ] || safe_base="file"
  printf '%s/%s' "$PREFIX" "$safe_base"
}

# Fail fast when two inputs in this invocation resolve to the same object key;
# otherwise the later upload silently overwrites the earlier one and both URLs
# would point at the same content. (Cross-invocation overwrite via a stable
# --prefix is intentional and unaffected.)
seen_keys=()
seen_files=()
for f in "${FILES[@]}"; do
  fkey="$(key_for "$f")"
  i=0
  while [ "$i" -lt "${#seen_keys[@]}" ]; do
    if [ "${seen_keys[$i]}" = "$fkey" ]; then
      echo "fm-r2-upload: object-key collision: '$f' and '${seen_files[$i]}' both map to '$fkey'; rename one or upload separately." >&2
      exit 2
    fi
    i=$((i + 1))
  done
  seen_keys+=("$fkey")
  seen_files+=("$f")
done

for f in "${FILES[@]}"; do
  if [ ! -f "$f" ]; then
    echo "fm-r2-upload: file not found: $f" >&2
    exit 1
  fi
  base="$(basename "$f")"
  ct="$(content_type_for "$f")"
  key="$(key_for "$f")"
  echo "fm-r2-upload: uploading $f -> $BUCKET/$key ($ct)" >&2
  "${WRANGLER[@]}" r2 object put "$BUCKET/$key" --file="$f" --content-type="$ct" --remote >&2
  url="$PUBLIC_BASE/$key"
  echo "$url"
  if [ "$MARKDOWN" -eq 1 ]; then
    echo "![${base%.*}]($url)"
  fi
done
