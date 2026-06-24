# envs

Context-aware local env router for the worktree era.

`envs` is a tiny POSIX shell wrapper that picks the right `.env` file based on where you are — which repo, which branch, which directory — exports it, and runs your command. No per-project setup, no `.env` inside your worktree, no accidental commits.

```sh
cd ~/code/myapp
envs development pnpm dev       # exports ~/.config/envs/myapp/.env.development, runs pnpm dev
envs production node build.js
```

## Why

Modern dev loops run multiple worktrees of the same repo (parallel features, AI agents, hot fixes). Putting `.env` *inside* a worktree means copying it into every new one, one missing `.gitignore` away from leaking secrets, and extra provisioning for agents that `mktemp` a worktree.

`envs` keeps every env file in **one global place** (`~/.config/envs/`) and a single routing table picks the right one from the current context. New worktree? Zero setup. Temp dir? Already routed. No env file ever touches the worktree.

## Install

```sh
curl -fsSL https://github.com/fronterior/envs/releases/latest/download/install.sh | sh
```

The installer ships with the release, so the script and the binary it installs are always the same version — and only after the release pipeline's install smoke test passes. Install from `main` instead with `https://raw.githubusercontent.com/fronterior/envs/main/install.sh`. If `~/.local/bin` isn't on your `PATH`, the installer offers to add it (with confirmation).

**Prebuilt branch artifacts** — every push produces a rolling prerelease tagged `branch-<name>` (no zig needed):

```sh
curl -fsSL https://raw.githubusercontent.com/fronterior/envs/main/install.sh | sh -s -- --branch <name>
```

Names are sanitized to `A-Za-z0-9._-` (everything else, including `/`, becomes `-`), so `feat/foo-bar` → `branch-feat-foo-bar`.

## Uninstall

```sh
curl -fsSL https://github.com/fronterior/envs/releases/latest/download/uninstall.sh | sh
```

Removes `~/.local/bin/envs` and the clone at `~/.local/share/envs`. Your config at `~/.config/envs/` is preserved (`rm -rf ~/.config/envs` to delete it).

## Use cases

### 1. Route a command to the right env file

One routing table, all env files under `~/.config/envs/`:

```sh
mkdir -p ~/.config/envs/myapp
echo 'API_KEY=dev-xxx'  > ~/.config/envs/myapp/.env.development
echo 'API_KEY=prod-xxx' > ~/.config/envs/myapp/.env.production

# ~/.config/envs/config — first match wins
echo '<repo:myapp>development:./myapp/.env.development' >> ~/.config/envs/config
echo '<repo:myapp>production:./myapp/.env.production'   >> ~/.config/envs/config

cd ~/code/myapp                 # any worktree of the myapp repo
envs development pnpm dev        # API_KEY=dev-xxx
envs production pnpm build       # API_KEY=prod-xxx
```

`<repo:myapp>` matches the repo's git remote, so every worktree routes the same with zero per-worktree setup. See [Routing config](#routing-config) and [Context keywords](#context-keywords).

### 2. Keep env vars across commands (source mode)

When the vars should stick for a whole shell session — like Python's `virtualenv` — activate source mode. A `precmd` hook re-routes on every prompt, so `cd` swaps envs automatically:

```sh
source ~/.local/share/envs/envs-source.sh    # once, in your rc

cd ~/code/myapp
envs-source-activate development   # API_KEY exported into this shell
pnpm dev                           # ...and every later command sees it
node scripts/seed.js

cd ~/code/myapp-prod-wt            # match changes → keys swap to production
cd /tmp                            # no rule matches → injected keys restored
envs-source-deactivate            # back to your original environment
```

See [Source mode](#source-mode) for the function list and config.

### 3. Show the active env in your prompt

`envs` only exports `$ENVS_SOURCE_*` variables; you wire them into your prompt. While source mode is on, a tag follows you as you move:

```text
~/code/myapp $ envs-source-activate development
~/code/myapp (development) $ cd ../myapp-prod-wt
~/code/myapp-prod-wt (production) $ cd /tmp
/tmp $                              # no match → tag gone
/tmp $ envs-source-deactivate
~/ $
```

One line in your shell rc does it — see [Prompt integration](#prompt-integration). zsh needs `setopt PROMPT_SUBST`; bash and fish work as-is.

## Routing config

```
<cond1,cond2,...>env_name:path
```

- `<...>`: zero or more comma-separated conditions, all must match (AND).
- `env_name`: the first CLI argument to `envs`.
- `path`: env file location (relative paths resolve under `~/.config/envs/`).
- **First match wins.** Lines starting with `#` and blank lines are ignored.

Paths may contain `<keyword>` placeholders (no colon) that interpolate the runtime context. If any interpolation value is empty (e.g. `<repo>` outside a git repo), the rule is skipped.

```
# Inside the myapp repo: envs development … → ./myapp/.env.development
<repo:myapp>development:./myapp/.env.development

# Outside git too, if the cwd path contains "myapp" (use */myapp to pin the last segment)
<current_dir:myapp>development:./myapp/.env.development

# Branch-aware: on main, development maps to the production file
<repo:myapp,branch:main>development:./myapp/.env.production

# Interpolate the repo name — one rule for many repos sharing a layout
<repo:myapp>development:./<repo>/.env.development

# No condition — matches any git repo with a remote (skipped without git)
development:./<repo>/.env.development
```

## Context keywords

Each keyword works both as a condition (`<keyword:value>`, AND-combined) and as path interpolation (`<keyword>`, no colon).

| Key | Source |
|---|---|
| `repo` | `basename` of the git `remote.origin.url`, `.git` stripped |
| `org` | the org/user segment of that URL (`octocat` in `git@github.com:octocat/myapp.git`) |
| `branch` | current branch (`git symbolic-ref --short HEAD`) |
| `current_dir` | **condition**: glob against the absolute cwd path (below). **interpolation**: `basename "$PWD"` |
| `name` | the `env_name` CLI arg — interpolation only, not a condition |

Outside a git repo, `repo`/`org`/`branch` are empty so rules using them never match; `current_dir` always works as a git-less fallback. Unknown keywords (typos like `<rpeo:…>`) are skipped with a stderr warning.

**`current_dir` glob** — ASCII case-insensitive, so `dev/frontends` matches `.../Dev/frontends`:

| Pattern | Matches |
|---|---|
| `foo` | cwd path **contains** `foo` (substring, anywhere) |
| `*/foo` | cwd path **ends with** `/foo` (`foo` is the last segment) |
| `*/foo/*` | cwd path **contains** `/foo/` (`foo` is an interior segment) |

Any other `*` usage is treated as a literal substring and never matches a real path; normal mode prints a stderr warning (source mode stays silent).

An **empty `env_name`** (`<repo:myapp>:./…` or `:./.env.global`) is reserved for `envs-source-activate` with no name argument — see Source mode.

## Source mode

```sh
envs-source-activate            # rules with an empty env_name
envs-source-activate dev        # rules with env_name = "dev"
envs-source-status              # inspect current state
envs-source-deactivate          # restore original env vars
```

On every prompt a `precmd` hook re-evaluates routing:

- The matched `.env`'s `KEY=VALUE` pairs are exported into the shell.
- `cd` to a different match → keys swap. No match → previously injected keys are restored to their original values.
- Re-activating with another name switches in place (not nested).

| Function | Purpose |
|---|---|
| `envs-source-activate [name]` | Activate. No arg → empty-`env_name` rules; with a name → matching rules. |
| `envs-source-deactivate` | Deactivate and restore every injected key's original value. |
| `envs-source-status` | Print state: `inactive`, or `active` with name, matched file, injected keys, dump file. |

A dev pair ships alongside: `envs-source.sh` (prod, `envs-source-*`) and `envs-dev-source.sh` (dev, `envs-dev-source-*`) — same logic, separate variable namespace, so both can run at once.

**Config** — source mode with no name uses empty-`env_name` rules; with a name it shares the same rules as `envs <name> <cmd>`:

```
<repo:myapp>:./<repo>/.env.shared                 # envs-source-activate          (no name)
<repo:myapp>development:./<repo>/.env.development  # envs development …  /  envs-source-activate development
```

**Exported while active** (so prompts, agents, CI can detect state without a subprocess):

| Variable | Active | Inactive |
|---|---|---|
| `$ENVS_SOURCE_ACTIVE` | `1` | unset |
| `$ENVS_SOURCE_NAME` | active name (empty string for empty-`env_name` rules) | unset |
| `$ENVS_SOURCE_LAST_MATCHED` | absolute path of the matched `.env` (empty if none) | unset |
| `$ENVS_SOURCE_INJECTED_KEYS` | space-separated injected keys | unset |

The dev pair exports the same set under `$ENVS_DEV_SOURCE_*`.

**Enable in your shell** (the installer offers to add this):

```sh
echo 'source ~/.local/share/envs/envs-source.sh'   >> ~/.zshrc                       # zsh / bash
echo 'source ~/.local/share/envs/envs-source.fish' >> ~/.config/fish/config.fish     # fish
```

Prompt hooks used: zsh `precmd_functions`, bash `PROMPT_COMMAND`, fish `--on-event fish_prompt`.

## Prompt integration

`envs` never touches your prompt — it only exports the variables above. To show a `(dev)` / `(prod)` tag, reference `$ENVS_SOURCE_NAME` in your prompt. **zsh requires `setopt PROMPT_SUBST`** (without it, `${…}` prints literally); bash and fish work as-is.

```sh
# zsh — ~/.zshrc
setopt PROMPT_SUBST
PROMPT='%~ ${ENVS_SOURCE_NAME:+(${ENVS_SOURCE_NAME}) }$ '
```

```sh
# bash — ~/.bashrc
PS1='\w ${ENVS_SOURCE_NAME:+(${ENVS_SOURCE_NAME}) }\$ '
```

```fish
# fish — inside fish_prompt in ~/.config/fish/config.fish
if set -q ENVS_SOURCE_ACTIVE
  echo -n "($ENVS_SOURCE_NAME) "
end
```

```toml
# starship — ~/.config/starship.toml
[custom.envs]
command = 'echo "($ENVS_SOURCE_NAME)"'
when = '[ -n "$ENVS_SOURCE_ACTIVE" ]'
```

**Empty `env_name`**: those rules set `$ENVS_SOURCE_NAME` to `""`. The zsh/bash snippets above (gated on `${ENVS_SOURCE_NAME:+…}`) then show nothing; fish/starship (gated on `$ENVS_SOURCE_ACTIVE`) show a bare `()`. To always show a labeled tag, gate on `$ENVS_SOURCE_ACTIVE` and default the name:

```sh
# zsh
setopt PROMPT_SUBST
PROMPT='%~ ${ENVS_SOURCE_ACTIVE:+(${ENVS_SOURCE_NAME:-envs}) }$ '
```

```sh
# bash
PS1='\w ${ENVS_SOURCE_ACTIVE:+(${ENVS_SOURCE_NAME:-envs}) }\$ '
```

```fish
# fish — inside fish_prompt
if set -q ENVS_SOURCE_ACTIVE
  set -l _name (test -n "$ENVS_SOURCE_NAME"; and echo $ENVS_SOURCE_NAME; or echo envs)
  echo -n "($_name) "
end
```

For the dev pair, swap every `$ENVS_SOURCE_*` for `$ENVS_DEV_SOURCE_*`. **Performance**: prefer the exported variables (zero subprocesses); calling `envs-source-status` from a prompt forks once per render and is noticeably slower — use it for interactive inspection only.

## Layout & maintenance

```
~/.config/envs/
├── config              # routing rules
└── myapp/
    ├── .env.development
    ├── .env.production
    └── .env.test
```

**Tests** — `brew install bats-core`, then `bats tests/` (covers `envs-source.sh`, `envs-dev-source.sh`, `envs-source.fish` across zsh/bash/fish; see `tests/README.md`).

**Version bump (maintainer)** — `src/version.zig` is the source of truth; `build.zig.zon`'s `.version` mirrors it (checked at every `zig build`). Edit `VERSION`, run `zig build -Dskip-version-check=true sync-version`, commit both.

## License

MIT. This project is not accepting contributions.
