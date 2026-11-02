#!/usr/bin/env bash
# Fails if the repo would publish a secret. Runs locally and in CI; needs only git and awk.
#  1. Every tracked file under secrets/ is SOPS-encrypted (all values ENC[...], has a MAC).
#  2. No tracked plaintext secret files (.env, .p8, .p12, profiles, age keys, *.local.xcconfig).
#  3. No private keys or well-known token formats in tracked text.
#  4. DEVELOPMENT_TEAM is not hard-coded in tracked project files.
#  5. If gitleaks is installed, scan the full git history too.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
fail=0
bad() { echo "check-secrets: $*" >&2; fail=1; }

# 1. secrets/ must hold only SOPS-encrypted YAML/JSON/dotenv files.
while IFS= read -r f; do
  [[ -z "$f" ]] && continue
  case "$f" in
    secrets/*.enc.yaml|secrets/*.enc.json|secrets/*.enc.env) ;;
    *) bad "$f: files in secrets/ must be named *.enc.{yaml,json,env}"; continue ;;
  esac
  grep -q 'mac.*ENC\[AES256_GCM' "$f" || { bad "$f: no SOPS MAC, not encrypted"; continue; }
  case "$f" in
    *.yaml)
      # Every scalar value above the `sops:` block must be ENC[...] (or a list/map opener).
      plain=$(awk '/^sops:/{exit} /^[[:space:]]*#/{next} /:[[:space:]]+[^[:space:]]/{
          v=$0; sub(/^[^:]*:[[:space:]]+/, "", v); if (v !~ /^ENC\[/ && v !~ /^[|>]/) print NR": "$0 }' "$f")
      [[ -z "$plain" ]] || bad "$f: plaintext values:"$'\n'"$plain" ;;
    *.json)
      plain=$(grep -nE '"[^"]+": *"' "$f" | grep -vE '"sops"|ENC\[|"(recipient|enc|lastmodified|version|unencrypted_suffix|created_at)"' || true)
      [[ -z "$plain" ]] || bad "$f: possible plaintext values:"$'\n'"$plain" ;;
    *.env)
      plain=$(grep -nE '^[A-Za-z_][A-Za-z0-9_]*=' "$f" | grep -vE '=ENC\[|^[0-9]+:sops_' || true)
      [[ -z "$plain" ]] || bad "$f: plaintext values:"$'\n'"$plain" ;;
  esac
done < <(git ls-files secrets)

# 2. Plaintext secret files must never be tracked.
files=$(git ls-files | grep -E '(^|/)\.env(\..*)?$|\.(p8|p12|cer|mobileprovision|provisionprofile|agekey)$|(^|/)keys\.txt$|\.local\.xcconfig$|\.dec\.' || true)
[[ -z "$files" ]] || bad "tracked plaintext secret files:"$'\n'"$files"

# 3. Key material and common token formats in tracked text files.
pattern='AGE-SECRET-KEY-1|-----BEGIN ([A-Z]+ )?PRIVATE KEY-----|AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{40,}|sk-[A-Za-z0-9_-]{32,}|xox[abpr]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{35}'
hits=$(git grep -nIE "$pattern" -- . ':!scripts/check-secrets.sh' || true)
[[ -z "$hits" ]] || bad "secret-looking strings:"$'\n'"$hits"

# 4. Team ID belongs in secrets/signing.enc.yaml, not in project files.
hits=$(git grep -nE 'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' -- '*.pbxproj' '*.xcconfig' || true)
[[ -z "$hits" ]] || bad "hard-coded DEVELOPMENT_TEAM (use scripts/secrets.sh xcconfig):"$'\n'"$hits"

# 5. Optional full-history scan.
if command -v gitleaks >/dev/null; then
  gitleaks git --redact --no-banner . >&2 || bad "gitleaks found leaks in history"
fi

if (( fail )); then exit 1; fi
echo "check-secrets: ok"
