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
curl -fsSL https://github.com/fronterior/envs/releases/latest/download/install.sh | sh
```

This installer is the one shipped with the latest release, so the script and
the binary it installs are always the same version (and it only ships after the
release pipeline's install smoke test passes). To install straight from `main`
instead, use `https://raw.githubusercontent.com/fronterior/envs/main/install.sh`.

If `~/.local/bin` is not in your `PATH`, the installer will detect your shell and offer to add the export line to `~/.zshrc` / `~/.bashrc` / `~/.profile` (asks for confirmation).

### Pre-built branch artifacts

Every push to any branch produces a rolling prebuilt release tagged `branch-<sanitized-name>` (one per branch, replaced on each push, marked as a prerelease). Install one without needing zig:

```sh
curl -fsSL https://raw.githubusercontent.com/fronterior/envs/main/install.sh \
  | sh -s -- --branch <name>
```

Branch name sanitization (must match between `install.sh` and the workflow):

- Allowed characters: `A-Z` `a-z` `0-9` `.` `_` `-`
- Anything else (including `/`) becomes `-`
- Repeated `-` collapsed; leading/trailing `-` stripped

So `feat/foo-bar` resolves to tag `branch-feat-foo-bar`, `main` resolves to `branch-main`.

## Uninstall

```sh
curl -fsSL https://github.com/fronterior/envs/releases/latest/download/uninstall.sh | sh
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

# Even outside git, if the cwd path contains "myapp", same rule.
# Use `*/myapp` instead to pin to "myapp as the last segment".
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
| `current_dir` | As a **condition** (`<current_dir:...>`): matched against the **absolute cwd path** with three glob forms (see below). As **path interpolation** (`<current_dir>`): `basename "$PWD"` — unchanged. |
| `name`        | The env_name (the CLI first argument). Path-interpolation only — not usable as a condition. |

If you're not in a git repo, `repo`/`org`/`branch` are empty, so any rule using them never matches. `current_dir` always works — use it as your worktree-less fallback. `<name>` always resolves (it's the CLI arg) — useful for collapsing per-env duplicates into one rule, e.g. `<repo:myapp>development:./<repo>/.env.<name>` and `<repo:myapp>production:./<repo>/.env.<name>`. Unknown keywords (typos like `<rpeo:foo>`) are skipped with a stderr warning.

### `current_dir` glob matching

`<current_dir:VALUE>` matches against the absolute cwd path string. Three patterns are supported:

| Pattern        | Meaning                                                                                  |
|----------------|------------------------------------------------------------------------------------------|
| `foo`          | cwd path **contains** `foo` as a substring (loose; matches anywhere in the path).        |
| `*/foo`        | cwd path **ends with** `/foo` — i.e. `foo` is the last segment (exact).                  |
| `*/foo/*`      | cwd path **contains** `/foo/` — i.e. `foo` is a segment somewhere with more path after.  |

Matching is ASCII case-insensitive, so `<current_dir:dev/frontends>` matches a cwd of `.../Dev/frontends`.

The wildcard `*` here is shell-glob-like and may cross slashes; only the three positions above are defined. Any other use of `*` (e.g. `*foo*bar*`) is treated as a literal substring search for the whole pattern. Such unsupported `*` patterns never match a real path, so normal mode prints a stderr warning to flag them (source mode stays silent).

Compatibility: prior to this change `current_dir` was an exact match against `basename(cwd)`. The new behaviour is intentionally looser by default — bare `foo` now also matches `myfoo`, `foobar`, `foo-extra` etc. anywhere in the path. If you need the old "last segment is exactly foo" semantics, write `<current_dir:*/foo>`.

An **empty `env_name`** (e.g. `<repo:myapp>:./<repo>/.env.shared`, or just `:./.env.global`) is reserved for `envs-source-activate` without a name argument — see the [envs-source](#envs-source-virtualenv-style) section.

## envs-source (virtualenv-style)

For workflows where you want env vars to stick across multiple commands in the same shell — like Python's `virtualenv` — use the source mode:

```sh
envs-source-activate            # uses source-mode rules (empty env_name)
envs-source-activate dev        # uses rules with env_name = "dev"
# ... run any number of commands ...
envs-source-status              # inspect current state
envs-source-deactivate          # restore original env vars
```

A `precmd` hook re-evaluates the routing context every shell prompt:

- The matched `.env` file's `KEY=VALUE` pairs are exported into the current shell.
- `cd` into a different repo → the match changes → keys are swapped automatically.
- No match (e.g. you `cd` out to an unrelated directory) → previously injected keys are restored to their original values.

Calling `envs-source-activate <other>` again switches routing in place — it is **not** nested (virtualenv pattern: re-activating swaps the active env rather than stacking).

### Core functions

| Function                  | Purpose                                                                  |
|---------------------------|--------------------------------------------------------------------------|
| `envs-source-activate [name]` | Activate source mode. With no argument, uses rules with an empty `env_name`. With a name, uses rules whose `env_name` matches. |
| `envs-source-deactivate`  | Deactivate and restore the original values of every key that was injected. |
| `envs-source-status`      | Print current state to stdout — `inactive`, or `active` with name, matched file, injected keys, and dump file path. |

A prod/dev pair is shipped: `envs-source.sh` (prod, `envs-source-*` functions) and `envs-dev-source.sh` (dev, `envs-dev-source-*` functions). The dev pair uses the same logic with a separate variable namespace so both can coexist for testing.

### Config syntax for source mode

Source mode without a name argument uses rules with an **empty `env_name`** (just `<cond>:path` or `:path`):

```
# Source-mode rule (empty env_name) — picked up by envs-source-activate (no name)
<repo:myapp>:./<repo>/.env.shared

# Prefix-mode rule (env_name = development) — picked up by envs development <cmd>
<repo:myapp>development:./<repo>/.env.development
```

Source mode with a name argument (`envs-source-activate dev`) uses the same rules as `envs dev <cmd>` — the `env_name` portion of each rule line acts as the routing key.

### Inspecting state — `envs-source-status`

Inactive:

```
envs-source: inactive
```

Active:

```
envs-source: active
  name:           dev
  matched:        /Users/me/.config/envs/myapp/.env.dev
  injected keys:  API_KEY DB_URL FOO
  dump file:      /tmp/envs-source-dump.XXXXX
```

### Exported environment variables

While source mode is on, these are exported so other tools (prompts, AI agents, CI scripts) can detect the state without spawning a subprocess:

| Variable                       | When active                                                | When inactive |
|--------------------------------|------------------------------------------------------------|---------------|
| `$ENVS_SOURCE_ACTIVE`          | `1`                                                        | unset         |
| `$ENVS_SOURCE_NAME`            | active name (may be empty string for empty-`env_name` rules) | unset         |
| `$ENVS_SOURCE_LAST_MATCHED`    | absolute path of the currently matched `.env` file (or empty if no rule matched) | unset |
| `$ENVS_SOURCE_INJECTED_KEYS`   | space-separated list of keys currently injected            | unset         |

The dev pair exports the same set under the `$ENVS_DEV_SOURCE_*` prefix (`$ENVS_DEV_SOURCE_ACTIVE`, `$ENVS_DEV_SOURCE_NAME`, `$ENVS_DEV_SOURCE_LAST_MATCHED`, `$ENVS_DEV_SOURCE_INJECTED_KEYS`).

### Showing active state in your prompt

**envs-source does not modify your prompt.** All it does is export the variables above on activation and unset them on deactivation. Your `PS1` / `PROMPT` / `fish_prompt` / `starship.toml` is yours — `envs` never touches it.

To surface the active state visually, add a line that references `$ENVS_SOURCE_ACTIVE` / `$ENVS_SOURCE_NAME` to your own shell rc file. The snippets below render a parenthesized tag like `(dev)` or `(prod)` while source mode is on, and nothing when it's off.

**zsh** — add to your `~/.zshrc` (envs does **not** do this automatically):

```sh
setopt PROMPT_SUBST
PROMPT='%~ ${ENVS_SOURCE_NAME:+(${ENVS_SOURCE_NAME}) }$ '
```

**bash** — add to your `~/.bashrc` (envs does **not** do this automatically):

```sh
PS1='\w ${ENVS_SOURCE_NAME:+(${ENVS_SOURCE_NAME}) }\$ '
```

**fish** — add inside your `fish_prompt` function in `~/.config/fish/config.fish` (envs does **not** do this automatically):

```fish
if set -q ENVS_SOURCE_ACTIVE
  echo -n "($ENVS_SOURCE_NAME) "
end
```

**starship** — add a custom module to your `~/.config/starship.toml` (envs does **not** do this automatically):

```toml
[custom.envs]
command = 'echo "($ENVS_SOURCE_NAME)"'
when = '[ -n "$ENVS_SOURCE_ACTIVE" ]'
```

> **Empty `env_name`**: source-mode rules with an empty `env_name` (e.g. `:./.env.global`) set `$ENVS_SOURCE_NAME` to the empty string, so the examples above render `()` — a visible-but-bare marker. If you'd rather show a fallback label, gate on `$ENVS_SOURCE_ACTIVE` and substitute a default:
>
> ```sh
> # zsh — falls back to (envs) when name is empty
> PROMPT='%~ ${ENVS_SOURCE_ACTIVE:+(${ENVS_SOURCE_NAME:-envs}) }$ '
> ```

For the dev pair (`envs-dev-source`), the same pattern applies — swap every `$ENVS_SOURCE_*` reference for `$ENVS_DEV_SOURCE_*` (e.g. `$ENVS_DEV_SOURCE_NAME`) in your rc file. Same separation of concerns: envs only exports; you wire it into your prompt.

> **Performance**: prompts run on every keystroke-cycle, so prefer the exported variables (`$ENVS_SOURCE_ACTIVE` / `$ENVS_SOURCE_NAME`) — zero subprocesses. Calling `envs-source-status` from the prompt forks once per prompt render and is noticeably slower; use it for interactive inspection only.

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

### Bumping the version (maintainer)

`src/version.zig` is the single source of truth. `build.zig.zon`'s `.version` mirrors it (verified at every `zig build`). To bump:

1. Edit the `VERSION` constant in `src/version.zig`.
2. Run `zig build -Dskip-version-check=true sync-version` to rewrite `build.zig.zon`.
3. Commit both files together.

A plain `zig build` afterward should pass without `-Dskip-version-check`.

## License

MIT

## Contributing

This project is not accepting contributions.
