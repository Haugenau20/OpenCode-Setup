# Plugins: enabling, disabling, and adding

OpenCode plugins are JS/TS modules that hook into the agent's lifecycle (and can
bundle skills/tools). This image ships a curated set **baked in but turned OFF**
— they are pure opt-in. Enabling one needs **no network**: the code and its
dependencies are already vendored in the image.

## What's baked in

| Name | What it does | Default |
|------|--------------|---------|
| `superpowers` | Skills library — brainstorming, writing-plans, systematic-debugging, TDD, requesting/receiving code review, and more. | OFF |
| `dcp` | Dynamic context pruning — trims stale tool output from the context window to save tokens. | OFF |
| `opencode-workspace` | `plan_save`/`plan_read` planning tools + background-agent delegation (async sub-agents). | OFF |

Run **`/plugins`** in the TUI for the live catalog and current on/off state.

### How to tell a plugin is working

Each plugin surfaces differently — there is no single "plugins" list in the TUI
that shows them (the Ctrl-P plugins dialog only lists `opencode.json` `plugin`
array entries, which we don't use):

- **superpowers** registers skills and injects a bootstrap — ask *"tell me about
  your superpowers"* or check the skills list.
- **opencode-workspace** adds model-callable tools — `plan_save`, `plan_read`,
  and `delegate*`. Ask the agent what tools it has.
- **dcp** is **invisible by design**. It does **not** add a tool the model can
  call — it works purely through a `chat.messages.transform` hook that *silently
  prunes obsolete tool outputs from the context*, and only once a conversation
  passes a token **threshold**. In a short chat it correctly does nothing, and
  the model will say it has no "compress/prune" tool — that is expected, not a
  failure. To see it act, set `"debug": true` in `~/.config/opencode/dcp.jsonc`,
  restart, run a long tool-heavy session, and watch the log.

  > **Caveat:** dcp relies on `experimental.chat.messages.transform`, which is
  > deprecated upstream. It works today but is the plugin most likely to break
  > on an OpenCode bump — re-test it whenever you change `OPENCODE_VERSION`.

## Turning a plugin on or off (developer)

Plugins are controlled from the **live** switch file *inside the container*:
`~/.config/opencode/disabled.yaml` (i.e. `/home/dev/.config/opencode/disabled.yaml`).
It lives in the user-config volume and is seeded on first boot from the image's
`disabled.yaml.default` template.

> **Don't edit the repo's `opencode/disabled.yaml.default`** to toggle anything —
> that's only the build-time seed. It's copied to the live file once, on a fresh
> config volume, and editing it does nothing to a running stack.

Find the `plugins:` block in the live file:

```yaml
plugins:
  enabled:
    # - superpowers
    # - dcp
    # - opencode-workspace
```

- **Enable**: uncomment a name (remove the leading `# `).
- **Disable**: delete its line (or comment it back out).

Two ways to edit the live file, then **restart** (`docker compose restart
opencode`, or re-run the launcher):

```bash
# In-container (vim ships in the image; the dev user owns the file):
docker exec -u dev -it opencode-<slug> vim /home/dev/.config/opencode/disabled.yaml

# Or, for host-side editing, set this in .env and restart once:
#   USER_LAYER_PATH=./user-layer
# then edit ./user-layer/disabled.yaml in your normal editor.
```

Verify it took effect — the entrypoint symlinks enabled plugins on boot:

```bash
docker exec opencode-<slug> ls -l /home/dev/.config/opencode/plugin/
```

The change is per-developer and follows you across repos (it's in your
user-config volume).

> The same file's `disabled:` block turns *off* bundled agents/skills/commands
> (those ship ON). Plugins are the opposite — opt-in — which is why they use an
> `enabled:` list. See [`ADDING_SKILLS.md`](ADDING_SKILLS.md) for the rest.

## Why you can't just paste a GitHub plugin URL

The usual OpenCode instruction — `"plugin": ["foo@git+https://github.com/..."]`
in `opencode.json` — makes OpenCode run a **Bun install at startup**, reaching
out to GitHub/npm. This image's egress is locked to the LLM endpoint, Bitbucket,
and JIRA, so that install would fail. Instead, plugins are vendored at build time
and loaded from local files (OpenCode auto-imports `plugin/*.{ts,js}` from your
config dir). To add a plugin that isn't baked in, it has to go into the
image — see below.

## Adding a plugin to the image (maintainer)

This requires an image rebuild. Open a PR against this repo.

1. **Vendor it at build time.** Add a block to the `plugins-build` stage in
   [`../opencode/Dockerfile`](../opencode/Dockerfile): clone at a **pinned** ref
   (tag or commit SHA — never a moving branch), build if it needs compiling,
   install/prune its **runtime** dependencies, and lay the result out under
   `/staging/plugins/<name>/` with an `entries` manifest
   (`<symlink-name>=<relative/entry/path>` per line).
2. **Default it OFF.** Add the name as a commented line under
   `plugins.enabled` in
   [`../opencode/disabled.yaml.default`](../opencode/disabled.yaml.default).
3. **Make it discoverable.** Add a one-line description to the map in
   [`../opencode/bundle/commands/plugins.md`](../opencode/bundle/commands/plugins.md)
   and a row to the table in
   [`../opencode/bundle/plugins/README.md`](../opencode/bundle/plugins/README.md).

The entrypoint does the rest: at start it symlinks the entry files of every
*enabled* plugin into `~/.config/opencode/plugin/`, and OpenCode imports them
directly. Imports resolve against the entry file's real path, so a vendored
`node_modules/` next to it is found automatically.

### Offline ground rules for a candidate plugin

A plugin is a clean fit only if **all** of these hold:

- It runs on **Node 20** (or under OpenCode's bundled Bun) — no `>=22` engine.
- It makes **no required network calls at runtime** (a best-effort,
  failure-tolerant version check is fine; a hard dependency on an external API
  or model download is not). Disable any auto-update — e.g. `dcp` ships a seeded
  `dcp.jsonc` with `"autoUpdate": false`.
- Its dependencies can be **fully vendored** at build time (no runtime
  `npm install`, no native addon whose ABI won't match the runtime).
- It doesn't assume host capabilities the sandbox lacks (spawning terminals or
  sibling containers, desktop notifications, multiple worktrees, etc.). This is
  why only two of `opencode-workspace`'s four plugins are baked.

If a plugin needs live egress to function, it does **not** belong here — flag it
for a deliberate allowlist decision instead.
