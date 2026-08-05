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

# --- allowlist agreement -----------------------------------------------------
# GIT_REMOTE_ALLOWLIST gates the git plane and GITLAB_WRITE_PROJECTS gates the
# API plane, in two different processes. Nothing at runtime makes them agree, so
# a mismatch shows up mid-run as an agent that can push but not open the MR, or
# the reverse. The preflight is the only place that sees both.

setup_both_planes() {
  use_gitlab
  cat >> "$WORK/.env" <<EOF
SYMPHONY_GITLAB_TOKEN=reporter
SYMPHONY_HTTP_PROXY=http://squid:3128
ALLOW_GITLAB_WRITE=1
EOF
  sed -i 's/^ALLOW_REMOTE_GIT=0/ALLOW_REMOTE_GIT=1/' "$WORK/.env"
  sed -i 's#^  base_url:.*#  base_url: https://gitlab.example#' "$WORK/symphony/WORKFLOW.md"
  sed -i 's#^  project_id:.*#  project_id: mygroup/myproject#'  "$WORK/symphony/WORKFLOW.md"
}

@test "matching allowlists pass quietly and confirm the tracker project" {
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject
GITLAB_WRITE_PROJECTS=mygroup/myproject
EOF
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" == *"is git-reachable and API-writable"* ]]
  [[ "$output" != *"could not push the branch"* ]]
  [[ "$output" != *"could not open the merge request"* ]]
}

@test "warns when a write project is not git-reachable" {
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject
GITLAB_WRITE_PROJECTS=mygroup/myproject othergroup/other
EOF
  run_launcher check
  [[ "$output" == *"othergroup/other is in GITLAB_WRITE_PROJECTS"* ]]
  [[ "$output" == *"could not push the branch"* ]]
}

@test "warns when a git-pushable destination has no API write permission" {
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject gitlab.example/spare/repo
GITLAB_WRITE_PROJECTS=mygroup/myproject
EOF
  run_launcher check
  [[ "$output" == *"spare/repo is pushable per GIT_REMOTE_ALLOWLIST"* ]]
  [[ "$output" == *"could not open the merge request"* ]]
}

@test "a broader git allowlist still covers a narrower write project" {
  # `mygroup` admits `mygroup/myproject` — prefix match on a segment boundary,
  # the same rule git-guard and the MCP gate already use.
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup
GITLAB_WRITE_PROJECTS=mygroup
EOF
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" != *"is in GITLAB_WRITE_PROJECTS but"* ]]
}

@test "a lookalike group is not covered by a shorter allowlist entry" {
  # The entry has to be the SHORTER string for this to test anything: a plain
  # prefix match would let `mygroup` swallow `mygroup-evil/theirs`, which is
  # precisely the confusion the segment boundary exists to prevent.
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup
GITLAB_WRITE_PROJECTS=mygroup-evil/theirs
EOF
  run_launcher check
  [[ "$output" == *"mygroup-evil/theirs is in GITLAB_WRITE_PROJECTS"* ]]
  [[ "$output" == *"could not push the branch"* ]]
}

@test "warns when the tracker's own project is outside the git allowlist" {
  # The workflow tells the agent to clone exactly this project, so git-guard
  # refusing it is a guaranteed failure on the very first command of the run.
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/someone-else/theirs
GITLAB_WRITE_PROJECTS=mygroup/myproject
EOF
  run_launcher check
  [[ "$output" == *"tracker project gitlab.example/mygroup/myproject is not covered by GIT_REMOTE_ALLOWLIST"* ]]
}

@test "warns when the tracker's own project cannot be written via the API" {
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject
GITLAB_WRITE_PROJECTS=someone-else/theirs
EOF
  run_launcher check
  [[ "$output" == *"tracker project mygroup/myproject is not in GITLAB_WRITE_PROJECTS"* ]]
}

@test "scheme, userinfo, port, .git and case are normalized away before comparing" {
  # The two variables are written in different formats by different people, so
  # the comparison has to reduce both to the same shape first — otherwise the
  # cross-check invents disagreements that are not there, which is worse than
  # not checking at all.
  setup_both_planes
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=https://git@gitlab.example:8443/mygroup/myproject.git
GITLAB_WRITE_PROJECTS=MyGroup/MyProject
EOF
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" == *"is git-reachable and API-writable"* ]]
  [[ "$output" != *"GITLAB_WRITE_PROJECTS but"* ]]
  [[ "$output" != *"pushable per GIT_REMOTE_ALLOWLIST"* ]]
  [[ "$output" != *"is not in GITLAB_WRITE_PROJECTS"* ]]
}

@test "a numeric project_id is not compared against the allowlists" {
  # A numeric GitLab id is a valid reference but carries no path, so there is
  # nothing an allowlist could be matched against. Saying nothing beats a
  # warning that cannot be acted on.
  setup_both_planes
  sed -i 's#^  project_id:.*#  project_id: 4711#' "$WORK/symphony/WORKFLOW.md"
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject
GITLAB_WRITE_PROJECTS=mygroup/myproject
EOF
  run_launcher check
  [ "$status" -eq 0 ]
  [[ "$output" != *"tracker project"* ]]
}

@test "the cross-check stays quiet when only one plane is enabled" {
  # ALLOW_GITLAB_WRITE off means the write tools are not offered at all, so
  # GITLAB_WRITE_PROJECTS describes nothing to disagree with.
  setup_both_planes
  sed -i 's/^ALLOW_GITLAB_WRITE=1/ALLOW_GITLAB_WRITE=0/' "$WORK/.env"
  cat >> "$WORK/.env" <<EOF
GIT_REMOTE_ALLOWLIST=gitlab.example/mygroup/myproject gitlab.example/spare/repo
GITLAB_WRITE_PROJECTS=mygroup/myproject
EOF
  run_launcher check
  [[ "$output" != *"pushable per GIT_REMOTE_ALLOWLIST"* ]]
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

# --- the file queue is not the gitlab tracker's board -------------------------
# Under tracker.kind: gitlab the six state directories store nothing. Creating
# them, counting them, or writing into them presents an empty second board next
# to the real one — and leftovers from an earlier file-queue run read as work
# about to be picked up.

@test "gitlab: status names the project instead of counting local files" {
  use_gitlab
  echo "SYMPHONY_GITLAB_TOKEN=x" >> "$WORK/.env"
  echo "SYMPHONY_HTTP_PROXY=http://squid:3128" >> "$WORK/.env"
  sed -i 's#^  project_id:.*#  project_id: mygroup/myproject#' "$WORK/symphony/WORKFLOW.md"
  run_launcher status
  [[ "$output" == *"tracker: gitlab"* ]]
  [[ "$output" == *"mygroup/myproject"* ]]
  [[ "$output" != *"queue is empty"* ]]
}

@test "gitlab: a stale file queue is not reported as pending work" {
  use_gitlab
  mkdir -p "$WORK/q/todo"
  echo "leftover" > "$WORK/q/todo/SYM-999-old.md"
  run_launcher status
  [[ "$output" != *"todo         1"* ]]
}

# `up` runs preflight and ensure_dirs before it ever touches docker, so a
# DOCKER_HOST that cannot connect stops it exactly after the part under test.
run_up() { run bash -c 'cd "$1" && DOCKER_HOST=unix:///nonexistent ./scripts/symphony up' _ "$WORK"; }

@test "gitlab: starting the stack creates workspaces but no local queue board" {
  use_gitlab
  echo "SYMPHONY_GITLAB_TOKEN=x" >> "$WORK/.env"
  echo "SYMPHONY_HTTP_PROXY=http://squid:3128" >> "$WORK/.env"
  run_up
  [ -d "$WORK/ws" ]
  [ ! -d "$WORK/q/todo" ]
  [ ! -d "$WORK/q/cancelled" ]
}

@test "file queue: starting the stack creates all six state directories" {
  # They must exist and share one filesystem — the claim is a rename(2) between
  # them, which is only atomic within a device.
  use_file_queue
  run_up
  [ -d "$WORK/ws" ]
  for d in todo in-progress review done failed cancelled; do
    [ -d "$WORK/q/$d" ]
  done
}

@test "gitlab: add refuses and says how to queue work instead" {
  use_gitlab
  run_launcher add "do the thing"
  [ "$status" -eq 1 ]
  [[ "$output" == *"work items are GitLab issues"* ]]
  [[ "$output" == *"symphony::todo"* ]]
  [ ! -d "$WORK/q/todo" ]
}

@test "file queue: status and add are unchanged" {
  use_file_queue
  run_launcher add "do the thing" --id SYM-7
  [ "$status" -eq 0 ]
  [ -d "$WORK/q/todo" ]
  run_launcher status
  [[ "$output" == *"queue: ./q"* ]]
}

@test "an unknown verb fails and prints usage" {
  run_launcher frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown command"* ]]
}
