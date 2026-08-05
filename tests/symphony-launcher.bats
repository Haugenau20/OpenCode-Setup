#!/usr/bin/env bats
#
# scripts/symphony is the host-side wrapper for the symphony overlay. Its
# preflight exists to catch, before anything starts, the mistakes that would
# otherwise show up as a confusing failure much later — or as an unattended
# agent doing something unintended. These test that it actually refuses.

setup() {
  load common
  LAUNCHER="$REPO_ROOT/scripts/symphony"
  [ -x "$LAUNCHER" ] || skip "scripts/symphony not present"
  WORK="$BATS_TEST_TMPDIR/stack"
  mkdir -p "$WORK/scripts" "$WORK/symphony"
  cp "$LAUNCHER" "$WORK/scripts/symphony"
  cp "$REPO_ROOT"/symphony/WORKFLOW*.example "$WORK/symphony/"
  cp "$REPO_ROOT"/docker-compose*.yml "$WORK/" 2>/dev/null || true
  cat > "$WORK/.env" <<EOF
PROJECT_SLUG=test
SYMPHONY_QUEUE_PATH=./q
SYMPHONY_WORKSPACES_PATH=./ws
SYMPHONY_CONFIG_PATH=./symphony
ALLOW_REMOTE_GIT=0
EOF
}

run_launcher() { run bash -c 'cd "$1" && shift && ./scripts/symphony "$@"' _ "$WORK" "$@"; }
use_file_queue() { cp "$WORK/symphony/WORKFLOW.md.example" "$WORK/symphony/WORKFLOW.md"; }
use_gitlab()     { cp "$WORK/symphony/WORKFLOW.gitlab.md.example" "$WORK/symphony/WORKFLOW.md"; }

@test "refuses to start without an .env" {
  rm "$WORK/.env"
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"no .env found"* ]]
}

@test "refuses to start without a WORKFLOW.md, and says how to make one" {
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"WORKFLOW.md.example"* ]]
}

@test "file queue: passes with no credentials at all" {
  use_file_queue
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" == *"symphony holds no credentials"* ]]
}

@test "reports the tracker kind it detected" {
  use_gitlab
  echo "SYMPHONY_GITLAB_TOKEN=x" >> "$WORK/.env"
  echo "SYMPHONY_HTTP_PROXY=http://squid:3128" >> "$WORK/.env"
  run_launcher check
  [[ "$output" == *"tracker: gitlab"* ]]
}

@test "gitlab tracker without a token is fatal" {
  use_gitlab
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYMPHONY_GITLAB_TOKEN is empty"* ]]
}

@test "gitlab tracker without egress is fatal" {
  use_gitlab
  echo "SYMPHONY_GITLAB_TOKEN=x" >> "$WORK/.env"
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"SYMPHONY_HTTP_PROXY is empty"* ]]
}

@test "warns when symphony and the agent share one token" {
  # The two-token split is the whole containment story for the gitlab tracker;
  # one token for both silently collapses it back to a single privilege level.
  use_gitlab
  cat >> "$WORK/.env" <<EOF
SYMPHONY_GITLAB_TOKEN=same
GITLAB_PAT=same
SYMPHONY_HTTP_PROXY=http://squid:3128
EOF
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" == *"are the same token"* ]]
}

@test "warns when remote git is on with no destination allowlist" {
  use_file_queue
  sed -i 's/ALLOW_REMOTE_GIT=0/ALLOW_REMOTE_GIT=1/' "$WORK/.env"
  run_launcher check
  [[ "$output" == *"GIT_REMOTE_ALLOWLIST is EMPTY"* ]]
}

@test "warns when GitLab writes are enabled but not project-limited" {
  use_file_queue
  echo "ALLOW_GITLAB_WRITE=1" >> "$WORK/.env"
  run_launcher check
  [[ "$output" == *"not project-limited"* ]]
}

@test "refuses when the workspaces mount is the repo itself" {
  # symphony treats workspaces as disposable and clones fresh per item.
  use_file_queue
  mkdir -p "$WORK/ws"
  echo "REPO_PATH=./ws" >> "$WORK/.env"
  run_launcher check
  [ "$status" -eq 1 ]
  [[ "$output" == *"same directory as REPO_PATH"* ]]
}

@test "surfaces max_turns and concurrency, and warns above one agent" {
  use_file_queue
  sed -i 's/max_concurrent_agents: 1/max_concurrent_agents: 4/' "$WORK/symphony/WORKFLOW.md"
  run_launcher check
  [[ "$output" == *"max_concurrent_agents=4"* ]]
  [[ "$output" == *"more than one agent at a time"* ]]
}

# --- add ---------------------------------------------------------------------

@test "add writes an item into todo/ with front matter the tracker accepts" {
  use_file_queue
  run_launcher add "Do the thing" --id SYM-042
  [ "$status" -eq 0 ]
  file="$(find "$WORK/q/todo" -name 'SYM-042*.md')"
  [ -n "$file" ]
  grep -q '^id: SYM-042$' "$file"
  grep -q '^attempts: 0$' "$file"
  grep -q '^next_retry_at: null$' "$file"
  grep -q 'Do the thing' "$file"
  # The directory IS the state, so a state: key must never be written.
  ! grep -q '^state:' "$file"
}

@test "add refuses an id the tracker would reject" {
  # The tracker requires ^[A-Za-z0-9][A-Za-z0-9._-]*$ and resolves every path
  # through a containment check; catching it here gives a better error.
  use_file_queue
  run_launcher add "x" --id "../escape"
  [ "$status" -eq 1 ]
}

@test "add refuses to overwrite an existing item" {
  use_file_queue
  run_launcher add "First" --id SYM-1 --title "same title"
  run_launcher add "Second" --id SYM-1 --title "same title"
  [ "$status" -eq 1 ]
  [[ "$output" == *"already exists"* ]]
}

@test "status reports per-directory counts" {
  use_file_queue
  run_launcher add "a" --id SYM-1
  run_launcher status
  [[ "$output" == *"todo"* ]]
  [[ "$output" == *"in-progress"* ]]
}

@test "an unknown verb fails and prints usage" {
  run_launcher frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command"* ]]
}
