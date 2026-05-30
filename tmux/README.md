# tmux

Terminal multiplexer configuration and plugin manager.

## Scripts

| Script | Description |
|---|---|
| `install.sh` | Installs tmux, clones dotfiles, symlinks config, and sets up TPM. |
| `update.sh` | Pulls latest dotfiles, updates TPM and plugins, reloads config. |

## Execution order

```
install.sh
update.sh   (run any time to upgrade)
```
