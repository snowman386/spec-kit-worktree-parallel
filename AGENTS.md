# Lessons Learned & Agent Guidelines

## Cross-Platform Git Worktree Paths
- **Gitdir Relative Paths**: `git worktree add` defaults to absolute paths in `.git` files, which breaks cross-environment access (e.g. WSL `/mnt/c/...` vs Windows native `C:\...`). Converting `.git` and `.git/worktrees/<branch>/gitdir` pointers to relative paths solves this cleanly.
- **Zero-Dependency Relative Path Calculation**: Avoid depending on `python` or GNU-specific `realpath --relative-to` in bash scripts. A pure Bash string-matching loop with MSYS `/c/` to `C:/` drive normalization is fully portable across WSL, Linux, macOS, and Git Bash without external dependencies.
- **Default Layout Consistency**: Ensure the default `LAYOUT` variable in `scripts/bash/create-worktree.sh` matches `extension.yml`, `worktree-config.yml`, `README.md`, and the test suite (`nested`).
