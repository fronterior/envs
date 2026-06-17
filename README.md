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

An **empty `env_name`** (e.g. `<repo:myapp>:./<repo>/.env.shared`, or just `:./.env.global`) is reserved for `envs-source-activate` without a name argument — see the [envs-source](#envs-source-virtualenv-style) section.

## envs-source (virtualenv-style)

For workflows where you want env vars to stick across multiple commands in the same shell — like Python's `virtualenv` — use the source mode:

```sh
envs-source-activate            # uses source-mode rules (empty env_name)
envs-source-activate dev        # uses rules with env_name = "dev"
# ... run any number of commands ...
envs-source-deactivate
```

A `precmd` hook re-evaluates the routing context every shell prompt:

- The matched `.env` file's `KEY=VALUE` pairs are exported into the current shell.
- `cd` into a different repo → the match changes → keys are swapped automatically.
- No match (e.g. you `cd` out to an unrelated directory) → previously injected keys are restored to their original values.

Calling `envs-source-activate <other>` again switches routing in place — it is **not** nested (virtualenv pattern: re-activating swaps the active env rather than stacking).

### Config syntax for source mode

Source mode without a name argument uses rules with an **empty `env_name`** (just `<cond>:path` or `:path`):

```
# Source-mode rule (empty env_name) — picked up by envs-source-activate (no name)
<repo:myapp>:./<repo>/.env.shared

# Prefix-mode rule (env_name = development) — picked up by envs development <cmd>
<repo:myapp>development:./<repo>/.env.development
```

Source mode with a name argument (`envs-source-activate dev`) uses the same rules as `envs dev <cmd>` — the `env_name` portion of each rule line acts as the routing key.

### Detecting active state

While source mode is on:

- `$ENVS_SOURCE_ACTIVE=1` is exported (useful for AI agents, prompt themes, or other tools that want to know).
- `$ENVS_SOURCE_NAME` holds the active name (empty string for source-mode rules).

### Supported shells

- zsh — registers a `precmd_functions` hook.
- bash — chains into `PROMPT_COMMAND`.
- fish — uses an `--on-event fish_prompt` handler.

### Setup

`install.sh` will offer to add `source $ENVS_HOME/envs-source.sh` (or `.fish`) to your shell rc. To enable later:

```sh
# zsh / bash
echo 'source ~/.local/share/envs/envs-source.sh' >> ~/.zshrc

# fish
echo 'source ~/.local/share/envs/envs-source.fish' >> ~/.config/fish/config.fish
```

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

## Tests

```sh
brew install bats-core  # if missing
bats tests/
```

Covers `envs-source.sh`, `envs-dev-source.sh`, and `envs-source.fish` across zsh, bash, and fish. See `tests/README.md` for details.

## License

MIT

## Contributing

This project is not accepting contributions.
