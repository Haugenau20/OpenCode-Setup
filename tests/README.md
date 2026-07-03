# Tests

Local test harness for OpenCode-Setup, written with
[bats](https://bats-core.readthedocs.io) (Bash Automated Testing System),
mirroring the pattern used by the sibling `Opencode-Launcher` repo's
`tests/`. No Docker daemon is required — this is the part of the system
that's testable without infrastructure.

## Run

```bash
./tests/run.sh                # whole suite
./tests/run.sh git-guard.bats # one file
```

`run.sh` uses a system `bats` if you have one; otherwise it fetches
`bats-core` into `tests/.bats/` (gitignored) on first run. Installing bats
yourself (`brew install bats-core`, `apt install bats`, …) skips the fetch.

This suite is also wired into `scripts/check.sh`, the one-command local gate
run before cutting a release (see `MAINTAINERS.md`).

## What's covered

| File | Covers |
| --- | --- |
| `git-guard.bats` | `opencode/git-guard`, run directly as a subprocess (it's a fully standalone script — no image dependencies beyond `/usr/bin/git`, which the guard intentionally hardcodes rather than resolving through `PATH`). Every blocked remote subcommand (`push`/`fetch`/`pull`/`clone`/`ls-remote`) with `ALLOW_REMOTE_GIT` unset/`0`; the global-option bypass matrix (`-C`, `-c`, `--git-dir=`, stacked `--work-tree=`+`-C`, bare flags like `-p`/`--paginate`) in front of a blocked subcommand; `git remote add`/`set-url` blocked while `remote -v`/`remote show` (read-only) pass through; `ALLOW_REMOTE_GIT=1` actually reaching a real git operation (push/fetch/pull/clone/ls-remote/remote add/set-url against a local bare repo, no network); local commands (`init`/`status`/`add`/`commit`, including a real "nothing to commit" failure) behaving exactly like real git, exit codes included; empty argv and lone options (`--version`, `--help`) delegating to real git unmodified. |
| `entrypoint.bats` | The pure helpers in `opencode/entrypoint.sh`, sourced directly (the file wraps its top-level boot flow in `main()`, guarded by a source-guard at the bottom, so sourcing it never runs the PID-1 boot sequence — see the commit that introduced the wrap for the `git diff --color-moved` verification that it's a pure code-motion refactor). `trim()` (quote/whitespace stripping, including nested-quote and unbalanced-quote edge cases); `disabled_for()` (list-form and inline-array-form `disabled.yaml`, missing file, other-kind isolation — **note: this test file documents several genuine parser limitations it found**, see "Known limitations" below); `apply_policy_env()` (extracted from the former inline §7 policy-parse block — quoted/unquoted values, values containing colons like `NO_PROXY`, confirms exported values carry no quote characters); a direct-execution smoke test pinning the exact early-failure mode when there's no `dev` user (this sandbox never has one) so a future refactor can't silently change it. |
| `static.bats` | Repo-wide invariants that are cheap to check and easy to let drift: `opencode/manifest.json` is valid JSON, `manifest_version` is `1`, exactly `LLM_API_BASE`+`LLM_API_KEY` are `required:true`, every `env_keys[].key` exists in `.env.example`, `mcps[]` matches the directories under `opencode/mcp-servers/` (excluding `_lib`), `plugins[]` matches what `opencode/Dockerfile`'s `plugins-build` stage actually builds, every service in the entrypoint's `MCP_SERVICES` table is listed in `mcps[]`; every `squid/allowlist.d/*.conf` non-comment line is an `acl allowed_dst dstdomain ...` line (the ACL-type footgun `docs/TROUBLESHOOTING.md` warns about); `squid.conf` has `80`/`443`/`8090` in `SSL_ports`; the denial-logging `access_log` lines precede the terminal `access_log none`; `bash -n` (+ `shellcheck --severity=error` when installed, skipped otherwise) across every `*.sh` plus `opencode/git-guard`/`scripts/opencode`; `node --check` across every `opencode/mcp-servers/**/*.js`; `.env.example` carries every key `scripts/doctor.sh` treats as required/optional-Bitbucket; every tracked `*.json` file parses. |

## Known limitations (found while writing these tests)

`disabled_for()` in `opencode/entrypoint.sh` has two real parsing gaps,
pinned (not fixed) by `entrypoint.bats` so a future fix is a deliberate,
visible test change rather than a silent behavior shift:

1. **The `docs/ADDING_SKILLS.md`-documented same-line inline-array form
   (`agents:  [code-reviewer]`) is silently ignored.** The awk key-match
   pattern matches the whole line (key *and* its same-line value) and jumps
   to the next line before ever inspecting what follows the colon. The only
   inline-array form the parser actually honors is the array bracket on its
   *own* line, immediately after the key.
2. **A same-line-empty kind (`skills:  []`) that is not the last key in the
   file can leak the *next* kind's list-form items** when queried, because
   the section-boundary check never fires for indented section headers.

Neither is fixed here — this task is scope-limited to adding the test
harness and the minimal restructuring needed to make `entrypoint.sh`'s pure
parts testable, not to changing `entrypoint.sh`'s parsing behavior.

## What's NOT covered

- **The §4b MCP gate loop's per-service decision logic** (which env vars
  enable which MCP, `DISABLE_<SVC>_MCP`, the generated `opencode.json`
  block). It reads/writes real paths under `/opt/opencode/mcp-servers` and
  `/etc/opencode/opencode.json` that only exist inside the built image;
  stubbing that whole layout to unit-test the loop would mean
  reimplementing most of the image's filesystem rather than testing the
  real thing, so it's deliberately skipped rather than forced into a
  brittle test. `scripts/doctor.sh`'s `check_mcp` (run against a live
  container) is the real coverage for this, and `static.bats` separately
  pins the `MCP_SERVICES` table against `manifest.json`.
- **Anything requiring a Docker daemon**: building either image, booting
  the compose stack, `squid -k parse` against the real config, the
  `MAINTAINERS.md` smoke test. `scripts/check.sh` runs these when Docker is
  available and otherwise lists them as manual reminders.
- **The MCP servers' actual HTTP behavior** (talking to Bitbucket/Jira/etc.)
  — `node --check` only proves they parse; runtime behavior needs a live
  service or a real container, both out of scope for this local harness.

## Adding a test

- Pure helper in `opencode/entrypoint.sh`? Add to `entrypoint.bats`: run it
  inside its own `bash -c '... source "$ENTRYPOINT"; <call>'` subshell (never
  source directly into the bats test process — the file keeps
  `set -euo pipefail` at file scope, and sourcing it flips those options for
  whatever shell does the sourcing).
- `opencode/git-guard` behavior? Add to `git-guard.bats`, using `run_guard`
  (see `common.bash`) or a raw `bash -c` invocation for scenarios that need a
  different working directory or env.
- A cheap cross-file invariant (two files that must agree, or a config file
  that must parse/have some shape)? Add to `static.bats`.
