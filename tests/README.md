# tests

Bats-based regression suite for the three source-mode scripts.

## Run

```sh
brew install bats-core  # if missing
bats tests/
```

## Coverage

| File                       | Targets             | Shells covered    |
|----------------------------|---------------------|-------------------|
| `envs-source.bats`         | `envs-source.sh`    | zsh, bash         |
| `envs-dev-source.bats`     | `envs-dev-source.sh`| zsh, bash         |
| `envs-source.fish.bats`    | `envs-source.fish`  | fish              |

Cases per shell:

- function registration (activate / deactivate / precmd / status)
- `activate` exports all matched keys (3+ keys, exercises the zsh word-split path)
- `cd` to a non-matching dir + a prompt tick unsets every injected key
- `cd` to another dir whose `current_dir` matches the same env_name swaps keys
- re-`activate` with a different name switches routing in place (not nested)
- `deactivate` restores prior environment and unsets bookkeeping vars
- dev variant: `status` shows `inactive` / `active name/matched/keys/dump` payload

## Isolation

`helpers/isolate.bash` builds a fresh `mktemp -d` per test:

- fake `$HOME`
- isolated `$ENVS_CONFIG_DIR` with a synthetic routing config and `.env` files
- private `$BIN_DIR` containing a copy of `bin/envs` (and a duplicated `envs-dev`) prepended to `PATH`
- `$ENVS_DEV_BIN=envs-dev` for the dev variant

No user dotfiles (`~/.zshrc`, `~/.bashrc`, `~/.config/fish/`, `~/.config/envs/`, `~/.local/bin/envs*`, `~/.local/share/envs/`) are read or written. fish cases run with `fish --no-config`.
