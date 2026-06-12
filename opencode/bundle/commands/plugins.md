---
description: List the workplace plugins baked into this image and whether each is ON or OFF.
---

Show me the catalog of bundled OpenCode plugins and their current on/off state.

Do this, then stop:

1. List the baked plugins — the directory names under
   `/opt/opencode/bundle/plugins/` (ignore non-directories like `README.md`).
2. Determine each plugin's ACTUAL loaded state by inspecting
   `~/.config/opencode/plugin/`: a plugin is `ON` if that directory contains a
   symlink whose target is under `/opt/opencode/bundle/plugins/<name>/`, else
   `OFF`. (This reflects what the entrypoint linked from `ENABLED_PLUGINS`.)
3. Print a compact table — one row per baked plugin — with: the plugin name,
   `ON`/`OFF`, and a one-line description from this map:
   - `superpowers` — skills library: brainstorming, writing-plans,
     systematic-debugging, TDD, requesting/receiving code review, and more.
   - `dcp` — dynamic context pruning: trims stale tool output from the context
     window to save tokens.
   - `opencode-workspace` — `plan_save`/`plan_read` planning tools plus
     background-agent delegation (async sub-agents).
   (If a baked plugin isn't in this map, show its name with "(no description).")
4. Finish with one line on how to toggle: set `ENABLED_PLUGINS` in `.env` on the
   host (space- or comma-separated, e.g. `ENABLED_PLUGINS=superpowers dcp`) and
   restart. Enabling needs no network; the plugins are already baked in.

Keep it to the table plus the one-line how-to. Do not modify any files.
