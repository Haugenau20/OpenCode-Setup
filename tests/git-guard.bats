#!/usr/bin/env bats
#
# opencode/git-guard is a fully standalone script (no image dependencies
# beyond /usr/bin/git), so it's tested directly rather than inside a
# container: run it as a subprocess and assert on exit status / stderr /
# delegation to the real git.

setup() {
  load common
  require_real_git
  clean_git_env
  REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$REPO"
  git -C "$REPO" init -q
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" config user.email "test@example.invalid"
}

# run_guard [args...] — invoke git-guard from inside $REPO.
run_guard() {
  run bash -c 'cd "$1" && shift && exec "$GIT_GUARD" "$@"' _ "$REPO" "$@"
}

# --- blocked remote subcommands (ALLOW_REMOTE_GIT unset/0) ------------------

@test "push is blocked by default" {
  run_guard push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "push is blocked when ALLOW_REMOTE_GIT=0" {
  ALLOW_REMOTE_GIT=0 run_guard push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "fetch is blocked by default" {
  run_guard fetch origin
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "pull is blocked by default" {
  run_guard pull origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "clone is blocked by default" {
  BARE="$BATS_TEST_TMPDIR/bare.git"
  git init -q --bare "$BARE"
  run_guard clone "$BARE" "$BATS_TEST_TMPDIR/dest"
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
  [ ! -d "$BATS_TEST_TMPDIR/dest" ]
}

@test "ls-remote is blocked by default" {
  run_guard ls-remote origin
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "blocked message references ALLOW_REMOTE_GIT and the docs pointer" {
  run_guard push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"ALLOW_REMOTE_GIT=1"* ]]
  [[ "$output" == *"ALLOWING_GIT_PUSH.md"* ]]
}

# --- global-option bypass matrix ---------------------------------------------
# git dispatches on the first non-option token, so any of these must NOT let
# a remote op slip past the guard by hiding the subcommand behind global
# options.

@test "bypass attempt: -C <path> push is still blocked" {
  run_guard -C /tmp push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "bypass attempt: -c k=v fetch is still blocked" {
  run_guard -c a=b fetch origin
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "bypass attempt: --git-dir=<path> pull is still blocked" {
  run_guard --git-dir=/tmp pull origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "bypass attempt: --work-tree=<x> -C <y> push (stacked globals) is still blocked" {
  run_guard --work-tree=/x -C /tmp push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

@test "bypass attempt: -p --paginate push (bare flags) is still blocked" {
  run_guard -p --paginate push origin main
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked by workplace policy"* ]]
}

# --- git remote subcommand gating --------------------------------------------

@test "remote add is blocked by default" {
  run_guard remote add origin https://example.invalid/repo.git
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked"* ]]
  run git -C "$REPO" remote
  [ -z "$output" ]   # never actually added
}

@test "remote set-url is blocked by default" {
  git -C "$REPO" remote add origin https://example.invalid/repo.git
  run_guard remote set-url origin https://evil.invalid/repo.git
  [ "$status" -eq 1 ]
  [[ "$output" == *"blocked"* ]]
  run git -C "$REPO" remote get-url origin
  [ "$output" = "https://example.invalid/repo.git" ]   # unchanged
}

@test "remote -v passes through (read-only, not gated)" {
  run_guard remote -v
  [ "$status" -eq 0 ]
}

@test "remote show (no args) passes through (read-only, not gated)" {
  run_guard remote show
  [ "$status" -eq 0 ]
}

@test "remote -v with a configured remote reports it (delegates to real git)" {
  git -C "$REPO" remote add origin https://example.invalid/repo.git
  run_guard remote -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"origin"* ]]
  [[ "$output" == *"example.invalid/repo.git"* ]]
}

# --- ALLOW_REMOTE_GIT=1 lets everything through to real git ------------------

@test "ALLOW_REMOTE_GIT=1: push/fetch/pull/clone/ls-remote reach the real git (against a local bare remote)" {
  BARE="$BATS_TEST_TMPDIR/bare2.git"
  git init -q --bare "$BARE"
  git -C "$REPO" remote add origin "$BARE"
  printf 'hello\n' > "$REPO/f.txt"
  git -C "$REPO" add f.txt
  git -C "$REPO" commit -q -m "first commit"
  # Determine the current branch name (init default may be main or master).
  BR="$(git -C "$REPO" branch --show-current)"

  ALLOW_REMOTE_GIT=1 run_guard push -u origin "$BR"
  [ "$status" -eq 0 ]
  [[ "$output" != *"blocked"* ]]

  ALLOW_REMOTE_GIT=1 run_guard ls-remote origin
  [ "$status" -eq 0 ]
  [[ "$output" == *"refs/heads/$BR"* ]]

  ALLOW_REMOTE_GIT=1 run_guard fetch origin
  [ "$status" -eq 0 ]

  ALLOW_REMOTE_GIT=1 run_guard pull origin "$BR"
  [ "$status" -eq 0 ]

  DEST="$BATS_TEST_TMPDIR/cloned"
  ALLOW_REMOTE_GIT=1 run bash -c 'exec "$1" clone "$2" "$3"' _ "$GIT_GUARD" "$BARE" "$DEST"
  [ "$status" -eq 0 ]
  [ -d "$DEST/.git" ]
}

@test "ALLOW_REMOTE_GIT=1: remote add/set-url reach the real git" {
  ALLOW_REMOTE_GIT=1 run_guard remote add origin https://example.invalid/repo.git
  [ "$status" -eq 0 ]
  run git -C "$REPO" remote get-url origin
  [ "$output" = "https://example.invalid/repo.git" ]

  ALLOW_REMOTE_GIT=1 run_guard remote set-url origin https://example.invalid/other.git
  [ "$status" -eq 0 ]
  run git -C "$REPO" remote get-url origin
  [ "$output" = "https://example.invalid/other.git" ]
}

# --- local commands pass through unchanged and keep working ------------------

@test "local workflow (init/status/commit) behaves exactly like real git, including exit codes" {
  WORK="$BATS_TEST_TMPDIR/localwork"
  mkdir -p "$WORK"

  run bash -c 'cd "$1" && exec "$GIT_GUARD" init -q' _ "$WORK"
  [ "$status" -eq 0 ]
  [ -d "$WORK/.git" ]

  run bash -c 'cd "$1" && "$GIT_GUARD" config user.name t && "$GIT_GUARD" config user.email t@example.invalid && exec "$GIT_GUARD" status --porcelain' _ "$WORK"
  [ "$status" -eq 0 ]
  [ -z "$output" ]   # clean tree, no output — matches real `git status --porcelain`

  printf 'x\n' > "$WORK/a.txt"
  run bash -c 'cd "$1" && exec "$GIT_GUARD" status --porcelain' _ "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"?? a.txt"* ]]

  run bash -c 'cd "$1" && exec "$GIT_GUARD" add a.txt' _ "$WORK"
  [ "$status" -eq 0 ]

  run bash -c 'cd "$1" && exec "$GIT_GUARD" commit -m "add a.txt"' _ "$WORK"
  [ "$status" -eq 0 ]
  [[ "$output" == *"add a.txt"* ]]

  # A second commit with nothing staged fails with real git's own exit code
  # (1) and message — the guard must not swallow or alter this.
  run bash -c 'cd "$1" && exec "$GIT_GUARD" commit -m "nothing to commit"' _ "$WORK"
  [ "$status" -ne 0 ]
  [[ "$output" == *"nothing to commit"* ]]
}

@test "local commands never mention the workplace policy" {
  run_guard status
  [ "$status" -eq 0 ]
  [[ "$output" != *"blocked by workplace policy"* ]]
}

# --- empty argv / lone options behave like real git --------------------------

@test "no arguments: same exit code and same usage-style output as real git" {
  run_guard
  real_status=$status
  real_output="$output"
  run git
  [ "$real_status" -eq "$status" ]
  [ "$real_output" = "$output" ]
}

@test "--version: behaves like real git --version (delegates, not gated)" {
  run_guard --version
  [ "$status" -eq 0 ]
  run git --version
  expected="$output"
  run_guard --version
  [ "$output" = "$expected" ]
}

@test "--help: delegates to real git (not treated as a subcommand)" {
  run_guard --help -a
  real_status=$status
  run git --help -a
  [ "$real_status" -eq "$status" ]
}

# --- GIT_REMOTE_ALLOWLIST: destination gate ----------------------------------
#
# The second gate. ALLOW_REMOTE_GIT=1 throughout this section — the question is
# no longer "may remote git run" but "may it reach THAT remote". Blocked here
# means the allowlist rejected the destination, which is a different message
# from the ALLOW_REMOTE_GIT refusal above.

SANDBOX_URL="https://gitlab.internal.example/my-group/demo.git"
PROD_URL="https://gitlab.internal.example/production/payments.git"
ALLOWLIST="gitlab.internal.example/my-group/"

# allow_guard [args...] — remote git enabled, allowlist set, run from $REPO.
allow_guard() {
  ALLOW_REMOTE_GIT=1 GIT_REMOTE_ALLOWLIST="$ALLOWLIST" run_guard "$@"
}

# refused — true when the allowlist (not the ALLOW_REMOTE_GIT gate) rejected it.
refused() {
  [ "$status" -ne 0 ] && [[ "$output" == *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist unset: any destination still passes (back-compat)" {
  ALLOW_REMOTE_GIT=1 run_guard clone "$PROD_URL" "$BATS_TEST_TMPDIR/x"
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: clone inside the sandbox prefix is permitted" {
  allow_guard clone "$SANDBOX_URL" "$BATS_TEST_TMPDIR/x"
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: clone outside the sandbox prefix is refused" {
  allow_guard clone "$PROD_URL" "$BATS_TEST_TMPDIR/x"
  refused
}

@test "allowlist: push to an explicit out-of-sandbox URL is refused" {
  allow_guard push "$PROD_URL" main
  refused
}

@test "allowlist: push to a named remote resolves the remote's URL" {
  git -C "$REPO" remote add origin "$PROD_URL"
  allow_guard push origin main
  refused
}

@test "allowlist: push to a named in-sandbox remote is permitted" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard push origin main
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: bare push resolves the default remote" {
  git -C "$REPO" remote add origin "$PROD_URL"
  allow_guard push
  refused
}

@test "allowlist: scp-style git@host:path is normalized, not waved through" {
  allow_guard clone "git@gitlab.internal.example:production/payments.git" "$BATS_TEST_TMPDIR/x"
  refused
}

@test "allowlist: scp-style inside the sandbox is permitted" {
  allow_guard clone "git@gitlab.internal.example:my-group/demo.git" "$BATS_TEST_TMPDIR/x"
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: prefix match respects path segments (sandbox-evil is refused)" {
  allow_guard clone "https://gitlab.internal.example/my-group-evil/x.git" "$BATS_TEST_TMPDIR/x"
  refused
}

@test "allowlist: a port on the URL does not defeat the match" {
  allow_guard clone "https://gitlab.internal.example:8443/production/payments.git" "$BATS_TEST_TMPDIR/x"
  refused
}

@test "allowlist: userinfo in the URL does not defeat the match" {
  allow_guard clone "https://user:token@gitlab.internal.example/production/payments.git" "$BATS_TEST_TMPDIR/x"
  refused
}

@test "allowlist: remote add pointing outside the sandbox is refused" {
  allow_guard remote add evil "$PROD_URL"
  refused
}

@test "allowlist: remote set-url pointing outside the sandbox is refused" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard remote set-url origin "$PROD_URL"
  refused
}

@test "allowlist: remote set-url inside the sandbox is permitted" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard remote set-url origin "https://gitlab.internal.example/my-group/other.git"
  [ "$status" -eq 0 ]
}

@test "allowlist: git -C resolves the remote in the TARGET repo, not the cwd" {
  # The cwd repo is in-sandbox; the -C target is not. Reading remotes from the
  # wrong repo here would wave through a push to production.
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init -q
  git -C "$other" remote add origin "$PROD_URL"
  allow_guard -C "$other" push origin main
  refused
}

@test "allowlist: --git-dir resolves the remote in the target repo" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  other="$BATS_TEST_TMPDIR/other2"
  mkdir -p "$other"
  git -C "$other" init -q
  git -C "$other" remote add origin "$PROD_URL"
  allow_guard --git-dir="$other/.git" --work-tree="$other" push origin main
  refused
}

@test "allowlist: an unknown remote name is refused, not waved through" {
  allow_guard push nosuchremote main
  refused
}

@test "allowlist: comma-separated entries are honoured" {
  ALLOW_REMOTE_GIT=1 \
    GIT_REMOTE_ALLOWLIST="gitlab.internal.example/a/,gitlab.internal.example/my-group/" \
    run_guard clone "$SANDBOX_URL" "$BATS_TEST_TMPDIR/x"
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: does not gate local-only subcommands" {
  ALLOW_REMOTE_GIT=1 GIT_REMOTE_ALLOWLIST="$ALLOWLIST" run_guard status
  [ "$status" -eq 0 ]
}

@test "allowlist: refusal explains itself and names the destination" {
  allow_guard clone "$PROD_URL" "$BATS_TEST_TMPDIR/x"
  [[ "$output" == *"$PROD_URL"* ]]
  [[ "$output" == *"$ALLOWLIST"* ]]
}

# --- destinations that are not the first positional token -------------------
# The scanner walks to the first non-option token and treats it as the remote.
# Three git invocations name a destination somewhere else entirely, and each one
# used to sail past this gate: `--repo=<url>` is a joined long option (skipped
# as one token), while `fetch --all` and a bare `remote update` contact EVERY
# configured remote and only the default one was ever checked.

@test "allowlist: push --repo=<url> outside the sandbox is refused" {
  allow_guard push --repo="$PROD_URL"
  refused
}

@test "allowlist: push --repo <url> (separate token) is refused too" {
  allow_guard push --repo "$PROD_URL"
  refused
}

@test "allowlist: push --repo inside the sandbox is permitted" {
  allow_guard push --repo="$SANDBOX_URL"
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: --repo is checked even when a positional remote is allowed" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard push --repo="$PROD_URL" origin main
  refused
}

@test "allowlist: fetch --all refuses when ANY configured remote is outside" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  git -C "$REPO" remote add upstream "$PROD_URL"
  allow_guard fetch --all
  refused
  [[ "$output" == *"$PROD_URL"* ]]
}

@test "allowlist: fetch --all is permitted when every remote is inside" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard fetch --all
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: fetch --all with no remotes contacts nothing and is allowed" {
  allow_guard fetch --all
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: fetch --multiple checks every named remote, not just the first" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  git -C "$REPO" remote add upstream "$PROD_URL"
  allow_guard fetch --multiple origin upstream
  refused
  [[ "$output" == *"$PROD_URL"* ]]
}

@test "allowlist: bare remote update refuses when any remote is outside" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  git -C "$REPO" remote add upstream "$PROD_URL"
  allow_guard remote update
  refused
}

@test "allowlist: remote update names a remote, and 'update' is not one" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  allow_guard remote update origin
  [[ "$output" != *"not in GIT_REMOTE_ALLOWLIST"* ]]
}

@test "allowlist: remote update expands a remotes.<group> into its members" {
  git -C "$REPO" remote add origin "$SANDBOX_URL"
  git -C "$REPO" remote add upstream "$PROD_URL"
  git -C "$REPO" config --add remotes.everything "origin upstream"
  allow_guard remote update everything
  refused
  [[ "$output" == *"$PROD_URL"* ]]
}

@test "allowlist: remote -v is a local read and stays ungated" {
  git -C "$REPO" remote add upstream "$PROD_URL"
  ALLOW_REMOTE_GIT=1 GIT_REMOTE_ALLOWLIST="$ALLOWLIST" run_guard remote -v
  [ "$status" -eq 0 ]
  [[ "$output" == *"upstream"* ]]
}
