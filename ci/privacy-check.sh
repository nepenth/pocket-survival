#!/bin/bash
# Fails if tracked files contain things that shouldn't be in a public repo: local home paths,
# personal email addresses, private network addresses, or credential-looking strings.
# Owner-specific terms live in a local, uncommitted pre-commit hook instead (.git/hooks/pre-commit).
set -euo pipefail
cd "$(dirname "$0")/.."
PATTERNS=(
  '/Users/[A-Za-z0-9._-]+'                                        # macOS home paths
  '/home/[a-z][a-z0-9._-]+/'                                      # Linux home paths
  '[A-Za-z0-9._%+-]+@(gmail|icloud|me|outlook|hotmail|yahoo|proton(mail)?)\.[a-z]+'
  '(^|[^0-9.])(10\.[0-9]{1,3}|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]{1,3}\.[0-9]{1,3}([^0-9]|$)'
  'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}'
  'BEGIN [A-Z ]*PRIVATE KEY'
  '0000[0-9]{4}-00[0-9A-F]{14}'                                   # iPhone UDID
)
fail=0
for p in "${PATTERNS[@]}"; do
  if git grep -n -I -E "$p" -- . ':!apps/PocketAssistant/llama.cpp' ':!apps/PocketMirror/PocketMirror/Web/vendor' ':!ci/privacy-check.sh'; then
    fail=1
  fi
done
[ $fail = 0 ] && echo "privacy check: clean" || echo "::error::privacy check found the lines above"
exit $fail
