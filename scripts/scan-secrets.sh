#!/bin/bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scanner="${GITLEAKS_BIN:-gitleaks}"
if ! command -v "$scanner" >/dev/null 2>&1; then
    printf '%s\n' 'Install verified Gitleaks 8.30.1 locally, or set GITLEAKS_BIN. No source was uploaded.' >&2
    exit 2
fi
if [[ "$("$scanner" version)" != '8.30.1' ]]; then
    printf '%s\n' 'This check requires reviewed Gitleaks 8.30.1.' >&2
    exit 2
fi
scan="$(mktemp -d "${TMPDIR:-/tmp}/lyricmate-secret-check.XXXXXX")"
trap 'rm -rf "$scan"' EXIT
python3 "$root/scripts/public-source.py" archive --output "$scan/source.tar.gz"
tar -xzf "$scan/source.tar.gz" -C "$scan"
# Do not honor ambient rule overrides, suppression files or inline allow comments.
args=(--redact=100 --no-banner --no-color --ignore-gitleaks-allow
      --gitleaks-ignore-path "$scan" --max-archive-depth 2 --timeout 120)
env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML "$scanner" git "$root" --log-opts=--all "${args[@]}"
env -u GITLEAKS_CONFIG -u GITLEAKS_CONFIG_TOML "$scanner" dir "$scan/LyricMate" "${args[@]}"
printf '%s\n' 'All local refs and the exact source export passed. No report was uploaded.'
