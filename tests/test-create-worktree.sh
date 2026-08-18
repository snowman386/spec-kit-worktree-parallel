#!/usr/bin/env bash
# Tests for create-worktree.sh
# Usage: bash tests/test-create-worktree.sh
#
# Creates a temporary git repo, runs all tests, cleans up.
# Exit code 0 = all passed, 1 = failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CREATE_SCRIPT="$SCRIPT_DIR/scripts/bash/create-worktree.sh"
PASS=0
FAIL=0
TOTAL=0

# --- helpers ---

ORIG_DIR="$(pwd)"

setup_temp_repo() {
  TEMP_DIR=$(python3 -c "import os,tempfile; print(os.path.realpath(tempfile.mkdtemp()))")
  git -C "$TEMP_DIR" init -b main >/dev/null 2>&1
  echo "init" > "$TEMP_DIR/README.md"
  git -C "$TEMP_DIR" add . && git -C "$TEMP_DIR" commit -m "init" >/dev/null 2>&1
  mkdir -p "$TEMP_DIR/specs"
  cd "$TEMP_DIR"
  echo "$TEMP_DIR"
}

cleanup() {
  cd "$ORIG_DIR"
  if [[ -n "${TEMP_DIR:-}" ]] && [[ -d "$TEMP_DIR" ]]; then
    git -C "$TEMP_DIR" worktree prune 2>/dev/null || true
    rm -rf "${TEMP_DIR}"--* 2>/dev/null || true
    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
  fi
}

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$expected" == "$actual" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_exit() {
  local label="$1" expected_code="$2"
  shift 2
  TOTAL=$((TOTAL + 1))
  set +e
  "$@" >/dev/null 2>&1
  local actual_code=$?
  set -e
  if [[ "$actual_code" -eq "$expected_code" ]]; then
    PASS=$((PASS + 1))
    echo "  PASS: $label"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label (expected exit $expected_code, got $actual_code)"
  fi
}

# --- tests ---

echo "=== create-worktree.sh tests ==="
echo ""

# Test 1: --help exits 0
echo "[1] --help exits 0"
assert_exit "--help exits 0" 0 bash "$CREATE_SCRIPT" --help

# Test 2: missing branch name exits 1
echo "[2] missing branch name exits 1"
assert_exit "no branch exits 1" 1 bash "$CREATE_SCRIPT" --json

# Test 3: dry-run nested (default)
echo "[3] dry-run nested layout (default)"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --dry-run --repo-root "$TEMP_DIR" 005-test-feature)
assert_contains "output is JSON" '"branch":"005-test-feature"' "$output"
assert_contains "layout is nested" '"layout":"nested"' "$output"
assert_contains "path contains .worktrees" '.worktrees/005-test-feature' "$output"
assert_contains "dry_run is true" '"dry_run":true' "$output"
cleanup; trap - EXIT

# Test 4: dry-run sibling layout
echo "[4] dry-run sibling layout"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --dry-run --layout sibling --repo-root "$TEMP_DIR" 005-test-feature)
assert_contains "layout is sibling" '"layout":"sibling"' "$output"
base=$(basename "$TEMP_DIR")
assert_contains "sibling path pattern" "${base}--005-test-feature" "$output"
cleanup; trap - EXIT

# Test 5: dry-run with explicit --path
echo "[5] dry-run with explicit --path"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --dry-run --repo-root "$TEMP_DIR" --path /tmp/custom-wt 005-test-feature)
assert_contains "uses explicit path" '"/tmp/custom-wt"' "$output"
cleanup; trap - EXIT

# Test 6: --in-place skips worktree
echo "[6] --in-place skips worktree"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --in-place 005-test-feature)
assert_contains "worktree is false" '"worktree":false' "$output"
assert_contains "path is empty" '"path":""' "$output"
cleanup; trap - EXIT

# Test 7: SPECIFY_WORKTREE_PATH env override
echo "[7] SPECIFY_WORKTREE_PATH env override"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(SPECIFY_WORKTREE_PATH=/tmp/env-override bash "$CREATE_SCRIPT" --json --dry-run --repo-root "$TEMP_DIR" 005-test-feature)
assert_contains "uses env path" '"/tmp/env-override"' "$output"
cleanup; trap - EXIT

# Test 8: real worktree creation (nested)
echo "[8] real worktree creation (nested)"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 005-real-test 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
wt_path="$TEMP_DIR/.worktrees/005-real-test"
TOTAL=$((TOTAL + 1))
if [[ -d "$wt_path" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: worktree directory exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: worktree directory does not exist at $wt_path"
fi
# verify branch in worktree
branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
assert_eq "worktree is on correct branch" "005-real-test" "$branch"
# verify .gitignore was updated
TOTAL=$((TOTAL + 1))
if grep -qxF ".worktrees/" "$TEMP_DIR/.gitignore" 2>/dev/null; then
  PASS=$((PASS + 1))
  echo "  PASS: .worktrees/ in .gitignore"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: .worktrees/ not in .gitignore"
fi
# cleanup worktree
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 9: real worktree creation (sibling)
echo "[9] real worktree creation (sibling)"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --layout sibling --repo-root "$TEMP_DIR" 005-sibling-test 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--005-sibling-test"
TOTAL=$((TOTAL + 1))
if [[ -d "$sibling_path" ]]; then
  PASS=$((PASS + 1))
  echo "  PASS: sibling worktree directory exists"
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: sibling worktree directory does not exist at $sibling_path"
fi
branch=$(git -C "$sibling_path" branch --show-current 2>/dev/null)
assert_eq "sibling worktree on correct branch" "005-sibling-test" "$branch"
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 10: duplicate worktree path blocked
echo "[10] duplicate worktree path blocked"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 005-dup-test >/dev/null 2>&1
assert_exit "second create fails" 1 bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 005-dup-test
git -C "$TEMP_DIR" worktree remove "$TEMP_DIR/.worktrees/005-dup-test" 2>/dev/null || true
cleanup; trap - EXIT

# Test 11: config file overrides default layout (including CRLF and quotes)
echo "[11] config file overrides default layout (including CRLF and quotes)"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
mkdir -p "$TEMP_DIR/.specify/extensions/worktrees"
printf 'layout: "sibling"\r\nrelative_paths: "auto"\r\n' > "$TEMP_DIR/.specify/extensions/worktrees/worktree-config.yml"
output=$(bash "$CREATE_SCRIPT" --json --dry-run --repo-root "$TEMP_DIR" 005-config-test)
assert_contains "config overrides to sibling" '"layout":"sibling"' "$output"
cleanup; trap - EXIT

# Test 12: branch with slashes handled
echo "[12] branch name with slashes sanitized"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --dry-run --repo-root "$TEMP_DIR" feature/user-auth)
assert_contains "slashes replaced" 'feature-user-auth' "$output"
cleanup; trap - EXIT

# Test 13: nested layout with --relative-paths (git native)
echo "[13] nested layout with --relative-paths"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --relative-paths --repo-root "$TEMP_DIR" 013-rel-nested 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
wt_path="$TEMP_DIR/.worktrees/013-rel-nested"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
assert_contains "nested .git has relative gitdir" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 14: sibling layout with --relative-paths (git native)
echo "[14] sibling layout with --relative-paths"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(bash "$CREATE_SCRIPT" --json --layout sibling --relative-paths --repo-root "$TEMP_DIR" 014-rel-sibling 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--014-rel-sibling"
git_line=$(head -1 "$sibling_path/.git" 2>/dev/null || true)
assert_contains "sibling .git has relative gitdir" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 15: nested layout fallback relative path rewriting (mocking no native support)
echo "[15] nested layout fallback relative path rewriting"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --relative-paths --repo-root "$TEMP_DIR" 015-fallback-nested 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
wt_path="$TEMP_DIR/.worktrees/015-fallback-nested"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
assert_contains "nested .git rewritten to relative gitdir" "gitdir: ../" "$git_line"
repo_gitdir_line=$(cat "$TEMP_DIR/.git/worktrees/015-fallback-nested/gitdir" 2>/dev/null || true)
assert_contains "repo gitdir rewritten to relative" "../" "$repo_gitdir_line"
branch=$(git -C "$wt_path" branch --show-current 2>/dev/null)
assert_eq "fallback nested worktree works with git" "015-fallback-nested" "$branch"
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 16: sibling layout fallback relative path rewriting (mocking no native support)
echo "[16] sibling layout fallback relative path rewriting"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --layout sibling --relative-paths --repo-root "$TEMP_DIR" 016-fallback-sibling 2>/dev/null)
assert_contains "worktree is true" '"worktree":true' "$output"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--016-fallback-sibling"
git_line=$(head -1 "$sibling_path/.git" 2>/dev/null || true)
assert_contains "sibling .git rewritten to relative gitdir" "gitdir: ../" "$git_line"
repo_gitdir_line=$(cat "$TEMP_DIR/.git/worktrees/${base}--016-fallback-sibling/gitdir" 2>/dev/null || true)
assert_contains "repo gitdir rewritten to relative" "../" "$repo_gitdir_line"
branch=$(git -C "$sibling_path" branch --show-current 2>/dev/null)
assert_eq "fallback sibling worktree works with git" "016-fallback-sibling" "$branch"
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 17: config relative_paths: "true" for nested and sibling
echo "[17] config relative_paths: 'true' for nested and sibling"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
mkdir -p "$TEMP_DIR/.specify/extensions/worktrees"
echo 'relative_paths: "true"' > "$TEMP_DIR/.specify/extensions/worktrees/worktree-config.yml"
# nested with config
output_nested=$(SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 017-cfg-nested 2>/dev/null)
assert_contains "nested worktree true" '"worktree":true' "$output_nested"
wt_path="$TEMP_DIR/.worktrees/017-cfg-nested"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
assert_contains "nested .git relative from config" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
# sibling with config
output_sib=$(SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --layout sibling --repo-root "$TEMP_DIR" 017-cfg-sibling 2>/dev/null)
assert_contains "sibling worktree true" '"worktree":true' "$output_sib"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--017-cfg-sibling"
git_line=$(head -1 "$sibling_path/.git" 2>/dev/null || true)
assert_contains "sibling .git relative from config" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 18: force --no-relative-paths produces absolute path in .git
echo "[18] force --no-relative-paths for nested and sibling"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output_nested=$(bash "$CREATE_SCRIPT" --json --no-relative-paths --repo-root "$TEMP_DIR" 018-no-rel-nested 2>/dev/null)
assert_contains "nested worktree true" '"worktree":true' "$output_nested"
wt_path="$TEMP_DIR/.worktrees/018-no-rel-nested"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if echo "$git_line" | grep -q "gitdir: \.\./"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: nested .git unexpectedly has relative path: $git_line"
else
  PASS=$((PASS + 1))
  echo "  PASS: nested .git has absolute path"
fi
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
# sibling
output_sib=$(bash "$CREATE_SCRIPT" --json --layout sibling --no-relative-paths --repo-root "$TEMP_DIR" 018-no-rel-sibling 2>/dev/null)
assert_contains "sibling worktree true" '"worktree":true' "$output_sib"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--018-no-rel-sibling"
git_line=$(head -1 "$sibling_path/.git" 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if echo "$git_line" | grep -q "gitdir: \.\./"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: sibling .git unexpectedly has relative path: $git_line"
else
  PASS=$((PASS + 1))
  echo "  PASS: sibling .git has absolute path"
fi
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 19: simulated non-windows environment with relative_paths: auto
echo "[19] simulated non-windows environment with relative_paths: auto retains absolute paths"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output=$(SPECIFY_FORCE_WSL=false SPECIFY_FORCE_GIT_BASH=false bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 019-non-win 2>/dev/null)
assert_contains "worktree true" '"worktree":true' "$output"
wt_path="$TEMP_DIR/.worktrees/019-non-win"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if echo "$git_line" | grep -q "gitdir: \.\./"; then
  FAIL=$((FAIL + 1))
  echo "  FAIL: non-windows environment unexpectedly used relative path: $git_line"
else
  PASS=$((PASS + 1))
  echo "  PASS: non-windows environment kept absolute path"
fi
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 20: simulated WSL environment auto-enables relative paths for nested and sibling
echo "[20] simulated WSL environment auto-enables relative paths for nested and sibling"
TEMP_DIR=$(setup_temp_repo)
trap cleanup EXIT
output_nested=$(SPECIFY_FORCE_WSL=true SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 020-wsl-nested 2>/dev/null)
assert_contains "nested worktree true" '"worktree":true' "$output_nested"
assert_contains "windows_path in json" '"windows_path":' "$output_nested"
wt_path="$TEMP_DIR/.worktrees/020-wsl-nested"
git_line=$(head -1 "$wt_path/.git" 2>/dev/null || true)
assert_contains "wsl nested .git is relative" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true

output_sib=$(SPECIFY_FORCE_WSL=true SPECIFY_FORCE_GIT_RELATIVE_SUPPORT=false bash "$CREATE_SCRIPT" --json --layout sibling --repo-root "$TEMP_DIR" 020-wsl-sibling 2>/dev/null)
assert_contains "sibling worktree true" '"worktree":true' "$output_sib"
assert_contains "windows_path in json" '"windows_path":' "$output_sib"
base=$(basename "$TEMP_DIR")
sibling_path="$(dirname "$TEMP_DIR")/${base}--020-wsl-sibling"
git_line=$(head -1 "$sibling_path/.git" 2>/dev/null || true)
assert_contains "wsl sibling .git is relative" "gitdir: ../" "$git_line"
git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
cleanup; trap - EXIT

# Test 21: functional git operations on Windows worktree path (nested and sibling)
echo "[21] functional git operations on Windows worktree path (nested and sibling)"
is_windows_host() {
  if command -v git.exe >/dev/null 2>&1 || command -v cmd.exe >/dev/null 2>&1 || command -v wslpath >/dev/null 2>&1 || command -v cygpath >/dev/null 2>&1; then
    return 0
  fi
  local os
  os="$(uname -s 2>/dev/null || echo "${OSTYPE:-}")"
  case "$os" in
    MINGW*|MSYS*|CYGWIN*|msys*|cygwin*)
      return 0
      ;;
  esac
  if [[ -f /proc/version ]] && grep -qiE '(microsoft|wsl)' /proc/version 2>/dev/null; then
    return 0
  fi
  return 1
}

if is_windows_host; then
  TEMP_DIR=$(setup_temp_repo)
  trap cleanup EXIT

  # 21a: Nested layout
  output_nested=$(bash "$CREATE_SCRIPT" --json --repo-root "$TEMP_DIR" 021-win-nested 2>/dev/null)
  assert_contains "nested worktree created" '"worktree":true' "$output_nested"
  wt_path="$TEMP_DIR/.worktrees/021-win-nested"

  # Git operations in worktree
  echo "content in nested" > "$wt_path/nested-file.txt"
  git -C "$wt_path" add nested-file.txt
  git -C "$wt_path" commit -m "commit from nested worktree" >/dev/null 2>&1
  assert_contains "commit recorded in nested log" "commit from nested worktree" "$(git -C "$wt_path" log -1 --pretty=%B)"
  assert_eq "nested worktree clean" "" "$(git -C "$wt_path" status --porcelain)"

  # Git operations via native Windows git if running in Windows environment
  if command -v git.exe >/dev/null 2>&1; then
    win_path=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('windows_path', ''))" "$output_nested")
    if [[ -n "$win_path" ]]; then
      win_status=$(git.exe -C "$win_path" status --porcelain 2>/dev/null || true)
      assert_eq "windows native git status clean" "" "$win_status"
      git.exe -C "$win_path" commit --allow-empty -m "windows native commit nested" >/dev/null 2>&1
      win_log=$(git.exe -C "$win_path" log -1 --pretty=%B 2>/dev/null || true)
      assert_contains "windows native commit in log" "windows native commit nested" "$win_log"
    fi
  fi
  git -C "$TEMP_DIR" worktree remove "$wt_path" 2>/dev/null || true

  # 21b: Sibling layout
  output_sib=$(bash "$CREATE_SCRIPT" --json --layout sibling --repo-root "$TEMP_DIR" 021-win-sibling 2>/dev/null)
  assert_contains "sibling worktree created" '"worktree":true' "$output_sib"
  base=$(basename "$TEMP_DIR")
  sibling_path="$(dirname "$TEMP_DIR")/${base}--021-win-sibling"

  # Git operations in worktree
  echo "content in sibling" > "$sibling_path/sibling-file.txt"
  git -C "$sibling_path" add sibling-file.txt
  git -C "$sibling_path" commit -m "commit from sibling worktree" >/dev/null 2>&1
  assert_contains "commit recorded in sibling log" "commit from sibling worktree" "$(git -C "$sibling_path" log -1 --pretty=%B)"
  assert_eq "sibling worktree clean" "" "$(git -C "$sibling_path" status --porcelain)"

  # Git operations via native Windows git if running in Windows environment
  if command -v git.exe >/dev/null 2>&1; then
    win_path_sib=$(python3 -c "import json, sys; print(json.loads(sys.argv[1]).get('windows_path', ''))" "$output_sib")
    if [[ -n "$win_path_sib" ]]; then
      win_status_sib=$(git.exe -C "$win_path_sib" status --porcelain 2>/dev/null || true)
      assert_eq "windows native sibling git status clean" "" "$win_status_sib"
      git.exe -C "$win_path_sib" commit --allow-empty -m "windows native commit sibling" >/dev/null 2>&1
      win_log_sib=$(git.exe -C "$win_path_sib" log -1 --pretty=%B 2>/dev/null || true)
      assert_contains "windows native sibling commit in log" "windows native commit sibling" "$win_log_sib"
    fi
  fi
  git -C "$TEMP_DIR" worktree remove "$sibling_path" 2>/dev/null || true
  cleanup; trap - EXIT
else
  echo "  SKIP: not running on Windows host (skipped on Linux/macOS)"
fi

# --- summary ---
echo ""
echo "=== Results: $PASS/$TOTAL passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi

