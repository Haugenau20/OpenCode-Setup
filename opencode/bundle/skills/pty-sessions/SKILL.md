---
name: pty-sessions
description: "Runs and drives long-running or interactive processes in a real pseudo-terminal using the opencode-pty tools (pty_spawn / pty_write / pty_read / pty_list / pty_kill), instead of the blocking one-shot bash tool. Use this skill whenever a command needs to keep running in the background, be watched over time, or receive input while running. Trigger situations include but are not limited to: starting a dev server or file watcher ('run npm run dev', 'start the vite server', 'watch the tests'), driving a REPL or interactive shell ('open a python shell and…', 'run psql and query…', 'ssh in and…'), answering a command's interactive prompts (login/confirm/y-n), tailing or grepping the live output of something already running, or monitoring a slow build while doing other work. Prefer the normal bash tool for quick commands that finish on their own; reach for these PTY tools the moment a process is interactive, backgrounded, or long-lived."
---

# PTY Sessions Skill

Drive background and interactive processes through the `opencode-pty` plugin's
tools. Unlike the standard `bash` tool — which runs one command to completion and
blocks until it exits — a PTY session keeps a real terminal open: the process
runs in the background, its output accumulates in a buffer you can read (and
filter) at any time, and you can send it input while it runs.

---

## Available tools

| Tool         | What it does                                                              |
|--------------|---------------------------------------------------------------------------|
| `pty_spawn`  | Start a command in a new background PTY session; returns a **session id**  |
| `pty_write`  | Send input (a line of text, keystrokes, Ctrl-C, etc.) to a session        |
| `pty_read`   | Read a session's output buffer, with pagination and an optional regex filter |
| `pty_list`   | List all sessions with status, PID, and line count                        |
| `pty_kill`   | Terminate a session (optionally discard its buffer)                        |

---

## When to use this instead of `bash`

Reach for the PTY tools when the process is **interactive, backgrounded, or
long-lived**:

- **Dev servers / watchers** — `npm run dev`, `vite`, `webpack --watch`,
  `jest --watch`. They never exit on their own, so `bash` would hang.
- **REPLs / interactive shells** — `python`, `node`, `psql`, an `ssh` session.
  You need to send commands *into* the process over time.
- **Commands that prompt** — anything that stops to ask (login, `y/n`,
  passphrase). `bash` can't answer; `pty_write` can.
- **Slow builds you want to monitor** — spawn it, then poll `pty_read` for
  progress while you do other work.

Keep using the ordinary `bash` tool for quick commands that finish on their own
(`ls`, `git status`, a one-shot build). Don't reach for a PTY when a plain
command will do.

---

## Core workflow

1. **Spawn** the process with `pty_spawn`; keep the returned session id.
   **The `command` must be something that keeps the terminal open** if you
   intend to send input to it afterwards. A command that runs and exits — e.g.
   `command=echo hello` — ends the session the moment it finishes, so there is
   nothing left to write to. Spawn a shell (`command=bash`) or the interactive
   program itself (`command=python`, `command=psql`), then type your actual
   commands into it with `pty_write`.
2. **Read** its output with `pty_read`. Poll again after a moment for
   long-running work — the buffer grows as the process emits more.
3. **Write** input with `pty_write` when the process is waiting on you (a REPL
   prompt, a `y/n`, a command to type into a shell). **To submit the input you
   must end it with a newline (`\n`) — that newline is how you "press Enter".**
   Without the trailing `\n` the text just sits at the prompt unsubmitted. For
   example, send `ls -la\n`, not `ls -la`.
4. **List** with `pty_list` to see what's still running and how much output each
   session holds.
5. **Kill** with `pty_kill` when you're done, so background processes and their
   buffers don't pile up.

---

## Practical tips

- **Give output time to appear.** After `pty_spawn` or `pty_write`, a process
  may take a moment to print. If `pty_read` looks empty or truncated, read again
  shortly after rather than assuming nothing happened.
- **Filter with regex.** For chatty processes, pass `pty_read` a regex to pull
  out just what matters — a "Local: http://…" line from a dev server, a
  `PASS`/`FAIL` from a test run, an error stack, or the prompt you're waiting on
  — instead of paging the whole buffer.
- **Match the prompt before writing.** When driving a REPL, read until you see
  its prompt, then `pty_write` the next line. Writing blind can send input before
  the process is ready.
- **Send control keys as input.** Interrupt a runaway process with a Ctrl-C via
  `pty_write` (rather than killing the session) when you want it to shut down
  cleanly and keep the session for follow-up.
- **Clean up.** End sessions you no longer need with `pty_kill`. Use `pty_list`
  first if you're unsure which sessions are still alive.

---

## Web viewer (optional)

The plugin also serves a live web terminal for following sessions in a browser,
started from the TUI with `/pty-open-background-spy`. It's a convenience for a
human watching along — the tools above are the interface you use to actually
drive sessions.
