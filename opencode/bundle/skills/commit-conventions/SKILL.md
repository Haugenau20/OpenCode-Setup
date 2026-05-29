---
name: commit-conventions
description: House commit-message conventions. Conventional Commits with a small set of allowed types.
---

# Commit conventions

We follow Conventional Commits with the type set frozen to:

| Type       | Use for                                                    |
|------------|------------------------------------------------------------|
| `feat`     | User-visible new behaviour.                                |
| `fix`      | Bug fix.                                                   |
| `refactor` | Code change that does not alter behaviour.                 |
| `docs`     | Documentation only.                                        |
| `test`     | Tests only, no production-code change.                     |
| `chore`    | Tooling, deps, formatting, generated code.                 |
| `build`    | Build system, Dockerfiles, CI image changes.               |
| `ci`       | CI pipeline changes.                                       |

## Rules

- Subject: `<type>(<scope>): <imperative summary>`, 72 chars max. Scope is
  optional but encouraged for monorepos.
- Body: present-tense imperative, wrapped at 72 columns, focused on *why*.
- One concern per commit. Split unrelated changes before committing.
- Reference Jira keys in a footer only: `Refs: ABC-1234`. Never in the
  subject.

## Bad

```
update files
fix(auth): fixed the thing
feat: ABC-1234 implement login
```

## Good

```
fix(auth): refuse logins when MFA challenge has expired

The previous flow accepted any non-empty challenge string because the
expiry check returned `nil` for missing rows instead of an error.
Treat a missing row as expired so the front end re-prompts.
```
