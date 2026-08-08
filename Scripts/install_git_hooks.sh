#!/usr/bin/env bash
#
# Installs repository git hooks. Run once per clone:
#
#   ./Scripts/install_git_hooks.sh
#
# WHY THIS EXISTS: `.gitignore` is a default, not a guarantee. `git add -f` overrides it without a
# warning, and so does any tool that stages with `--force`. Catalyst is a PUBLIC repository, and a
# provider config pushed to it cannot be un-published — git history is not something you walk back
# once people have cloned it. This repo has already had one Firebase config reach a public tag that
# way, so the guard is not hypothetical.
#
# Hooks live in .git/hooks/, which git does not track, which is why this installer is tracked
# instead. It is idempotent and safe to re-run.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$REPO_ROOT/.git/hooks"
mkdir -p "$HOOK_DIR"

cat > "$HOOK_DIR/pre-commit" <<'HOOK'
#!/usr/bin/env bash
# Blocks provider configs and key material from being committed, including via `git add -f`.
# Bypass ONLY if you are certain: git commit --no-verify
set -euo pipefail

BLOCKED='(^|/)GoogleService-Info\.plist$|\.p8$|\.p12$|\.pem$|\.mobileprovision$|sparkle_private\.key$|(^|/)\.env(\..*)?$'
staged="$(git diff --cached --name-only --diff-filter=ACMR || true)"
offenders="$(printf '%s\n' "$staged" | grep -E "$BLOCKED" || true)"

if [ -n "$offenders" ]; then
  echo "✗ pre-commit: refusing to commit credential-shaped files." >&2
  printf '%s\n' "$offenders" | sed 's/^/    /' >&2
  echo >&2
  echo "  This repository is PUBLIC. A config committed here cannot be un-published." >&2
  echo "  If a provider config is genuinely needed, it is CODEOWNERS-held and distributed" >&2
  echo "  out of band — see Telemetry/README.md. Unstage with:" >&2
  echo "      git restore --staged <file>" >&2
  exit 1
fi

# Second net: high-entropy key literals in the staged content itself, not just filenames.
if git diff --cached -U0 --diff-filter=ACMR \
   | grep -nE '^\+.*(AIza[0-9A-Za-z_-]{35}|rzp_live_[0-9A-Za-z]+|sk_live_[0-9A-Za-z]+|ghp_[0-9A-Za-z]{36}|-----BEGIN [A-Z ]*PRIVATE KEY-----)' >/dev/null; then
  echo "✗ pre-commit: a staged line looks like a live API key or private key." >&2
  echo "  Review the diff. Bypass with --no-verify only if it is a false positive." >&2
  exit 1
fi
HOOK

chmod +x "$HOOK_DIR/pre-commit"
echo "✓ Installed $HOOK_DIR/pre-commit"
echo "  Blocks: GoogleService-Info.plist, .p8/.p12/.pem, .mobileprovision, sparkle_private.key,"
echo "          .env*, and staged lines containing live-looking API or private keys."
