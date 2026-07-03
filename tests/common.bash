# Shared helpers for the OpenCode-Setup bats suite.

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$COMMON_DIR/.." && pwd)"
GIT_GUARD="$REPO_ROOT/opencode/git-guard"
ENTRYPOINT="$REPO_ROOT/opencode/entrypoint.sh"
export REPO_ROOT GIT_GUARD ENTRYPOINT

# require_real_git — git-guard hardcodes REAL_GIT=/usr/bin/git (by design: a
# workplace-policy gate shouldn't itself be re-routable via PATH tricks). Skip
# tests that exec it on a system where that path doesn't exist rather than
# failing the suite for an environment mismatch.
require_real_git() {
  [ -x /usr/bin/git ] || skip "/usr/bin/git not present (git-guard hardcodes this path)"
}

# clean_git_env — unset the git-guard gate var and anything a parent shell may
# have exported, so each test starts from the documented default (blocked).
clean_git_env() {
  unset ALLOW_REMOTE_GIT || true
}
