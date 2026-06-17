# envs

Context-aware local env router for the worktree era.

`envs` is a tiny POSIX shell wrapper that picks the right `.env` file based on where you are (which repo, which branch, which directory), exports it, and runs your command. No per-project setup, no `.env` files inside your worktree, no accidental commits.

```sh
cd ~/code/myapp
envs development pnpm dev      # exports ~/.config/envs/myapp/.env.development, runs pnpm dev
envs production node build.js
```

## Why

Modern dev loops involve multiple worktrees of the same repo (for parallel features, AI agents, hot fixes). Putting `.env` inside a worktree means:

- Every new worktree needs the `.env` copied in.
- One forgotten `.gitignore` entry and your secrets land in a PR.
- AI agents that `mktemp` a worktree have to provision env separately.

`envs` keeps env files in **one global place** (`~/.config/envs/`) and a single routing table picks the right file based on the current context. New worktree? Zero setup. AI agent in a temp dir? Already routed. PR risk? Zero, because no env file ever touches the worktree.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/fronterior/envs/main/install.sh | sh
```

If `~/.local/bin` is not in your `PATH`, the installer will detect your shell and offer to add the export line to `~/.zshrc` / `~/.bashrc` / `~/.profile` (asks for confirmation).

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/fronterior/envs/main/uninstall.sh | sh
```

Removes `~/.local/bin/envs` and the clone at `~/.local/share/envs`. Your routing config at `~/.config/envs/` is **preserved** — `rm -rf ~/.config/envs` to delete it.

## Quick start

```sh
# 1. Create a project env directory and a development env file.
mkdir -p ~/.config/envs/myapp
echo 'API_KEY=xxx' > ~/.config/envs/myapp/.env.development

# 2. Add a routing rule to ~/.config/envs/config (create the file if missing).
echo '<repo:myapp>development:./myapp/.env.development' >> ~/.config/envs/config

# 3. Go into a git repo named "myapp" (or any directory named "myapp").
cd ~/code/myapp

# 4. Run a command with the env injected.
envs development pnpm dev
```

That's it. Add `~/.config/envs/myapp/.env.production` and `envs production ...` works too.

## Usage

```
envs <env_name> <command...>
```

## Config syntax

```
<cond1,cond2,...>env_name:path
```

- `<...>` block: zero or more comma-separated conditions. All must match (AND).
- `env_name`: the first CLI argument to `envs`.
- `path`: env file location.
- Order matters: **first match wins**.
- Exact string match only (no glob in the MVP).
- Lines starting with `#` and blank lines are ignored.

Paths can also contain `<keyword>` placeholders (no colon) that interpolate to the runtime context value. If any interpolation variable is empty (e.g. `<repo>` outside a git repo), the rule is skipped.

Examples:

```
# Inside the myapp repo, "envs development ..." -> ./myapp/.env.development
<repo:myapp>development:./myapp/.env.development

# Even outside git, if the current dir is named myapp, same rule.
<current_dir:myapp>development:./myapp/.env.development

# Branch-aware: on main, development maps to the production file.
<repo:myapp,branch:main>development:./myapp/.env.production

# Same rule but path uses <repo> — convenient for many repos sharing the same layout.
<repo:myapp>development:./<repo>/.env.development

# No condition — matches any git repo with a remote (skipped without git).
development:./<repo>/.env.development

# Multi-variable interpolation.
test:./<repo>/<branch>/.env.test
```

## Context keywords

The same keyword pool is used both as conditions (`<keyword:value>` at the start of a line, AND combined) and as path interpolation (`<keyword>` anywhere in the path, no colon).

| Key           | Source                                                    |
|---------------|-----------------------------------------------------------|
| `repo`        | `basename` of `git config --get remote.origin.url`, `.git` stripped |
| `org`         | The org/user segment of that URL (e.g. `ridi` in `git@github.com:ridi/myapp.git`) |
| `branch`      | `git symbolic-ref --short HEAD`                            |
| `current_dir` | `basename "$PWD"`                                          |
| `name`        | The env_name (the CLI first argument). Path-interpolation only — not usable as a condition. |

If you're not in a git repo, `repo`/`org`/`branch` are empty, so any rule using them never matches. `current_dir` always works — use it as your worktree-less fallback. `<name>` always resolves (it's the CLI arg) — useful for collapsing per-env duplicates into one rule, e.g. `<repo:myapp>development:./<repo>/.env.<name>` and `<repo:myapp>production:./<repo>/.env.<name>`. Unknown keywords (typos like `<rpeo:foo>`) are skipped with a stderr warning.

## Directory structure example

```
~/.config/envs/
├── config              # routing rules 
├── myapp/
│   ├── .env.development
│   ├── .env.production
│   └── .env.test
└── ...
```

## License

MIT

## Contributing

This project is not accepting contributions.
