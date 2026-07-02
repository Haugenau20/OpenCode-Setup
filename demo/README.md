# Demo onboarding pack (user layer)

An interactive onboarding/demo experience for the OpenCode workplace, shipped as
a **user layer** so it loads on top of the stock image — **no image rebuild**.

- `onboarding-layer/agents/guide.md` — a `mode: primary` host agent (Tab-selectable).
- `onboarding-layer/commands/tour.md` — `/tour`, the projector-driven walkthrough.
- `onboarding-layer/commands/try-it.md` — `/try-it`, the self-paced take-home.
- `DEMO-RUNSHEET.md` — the presenter run-sheet (pre-flight, `.env`, run of show).

> These are flat markdown (1 agent + 2 commands, no skill directories), so they
> slot straight into a user layer and load alongside the baked-in bundle. The
> names don't collide with any bundled item, so they're purely additive.

> **Why the folder isn't named `user-layer`.** Both this repo and the launcher
> gitignore `user-layer/` (unanchored — it matches at any depth, so even
> `demo/user-layer/` would be silently untracked). Naming it `onboarding-layer/`
> keeps it tracked. The directory name is arbitrary — `USER_LAYER_PATH` is what
> points the launcher at it — so just avoid the ignored token.

## Where this is meant to live

This folder is staged in the backbone repo only so the files are reachable. The
intended home is the **launcher** repo (`Opencode-Launcher`), where a developer
can point `USER_LAYER_PATH` at it without touching the image.

## Wiring it into the launcher

1. Copy `onboarding-layer/` into your launcher checkout as a **tracked** dir.
   Do **not** name it `user-layer` (gitignored in both repos); any other tracked
   path works:

   ```
   <launcher>/demo/onboarding-layer/agents/guide.md
   <launcher>/demo/onboarding-layer/commands/tour.md
   <launcher>/demo/onboarding-layer/commands/try-it.md
   ```

2. Set one line in the launcher `.env`:

   ```dotenv
   USER_LAYER_PATH=./demo/onboarding-layer
   ```

3. `./start.sh <repo>` — the launcher bind-mounts that dir at
   `/home/dev/.config/opencode`, and `guide` / `/tour` / `/try-it` load on top of
   the stock image. Iterate by editing the files on the host and re-running.

## How it loads (mechanics)

The backbone entrypoint symlinks the baked-in bundle into
`~/.config/opencode/{agents,skills,commands}` at boot. When `USER_LAYER_PATH`
bind-mounts a host dir over that same path, the two coexist: bundle items load,
and these user-layer files load alongside them. A user-layer file with the same
name as a bundle item would *shadow* it — these names don't, so nothing is
overridden.

> **Do not add an `AGENTS.md` to the user layer.** A real `AGENTS.md` there
> shadows the bundle's house rules (skills-over-raw-tools, git conventions).
> This pack deliberately ships none.

## Promoting to the image later

If the demo lands and you want it permanent for everyone (no opt-in), the same
three files can move into the backbone bundle
(`opencode/bundle/{agents,commands}/`) and ship in every image — they are
byte-identical, so it's a straight copy.
