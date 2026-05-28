#!/usr/bin/env bash
# Plain-bash tests for cerebro's read-only bridge subcommands. No external
# test framework. Run with: bash bin/cerebro-tests/run.sh
#
# We exercise validation paths -- denied subcommands, denied flags, path
# containment -- which fire before any actual git/gh/rg invocation. The
# happy-path tests do invoke real git and rg.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CEREBRO_BIN="$here/../cerebro"
[[ -x "$CEREBRO_BIN" ]] || { echo "cerebro not found or not executable: $CEREBRO_BIN" >&2; exit 1; }

# Isolated sandbox.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

export CEREBRO_HOME="$WORKDIR/cerebro-home"
export CEREBRO_SESSION_ID="test-session"
mkdir -p "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/plans" \
         "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/children"
: > "$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID/transcript.jsonl"

REPO="$WORKDIR/repo"
mkdir -p "$REPO"
(
  cd "$REPO"
  git init -q -b main . 2>/dev/null || git init -q .
  git config user.email test@example.com
  git config user.name test
  git commit --allow-empty -q -m init
  : > a.txt
  git add a.txt
  git commit -q -m "add a.txt"
) || { echo "failed to set up test repo" >&2; exit 1; }

pass=0
fail=0
failures=()

# run_case <id> <description> <expected-rc> -- <cmd...>
# Optional: STDERR_CONTAINS=<substring> env to assert a substring of stderr.
run_case() {
  local id="$1" desc="$2" expected="$3"
  shift 3
  [[ "$1" == "--" ]] && shift
  local needle="${STDERR_CONTAINS:-}"
  local out err rc
  out="$("$@" 2>"$WORKDIR/stderr")"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"

  local note=""
  if (( rc != expected )); then
    note="rc=$rc (expected $expected)"
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    note="${note:+$note; }stderr missing '$needle': $err"
  fi

  if [[ -z "$note" ]]; then
    printf 'PASS  %s  %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s  %s  [%s]\n' "$id" "$desc" "$note"
    fail=$((fail + 1))
    failures+=("$id $desc :: $note")
  fi
  unset STDERR_CONTAINS
}

# --- 1. git happy paths ---
run_case 01 "git status happy" 0 -- "$CEREBRO_BIN" git "$REPO" status

run_case 02 "git log --oneline happy" 0 -- "$CEREBRO_BIN" git "$REPO" log --oneline -n 1

run_case 03 "git diff HEAD~1 HEAD happy" 0 -- "$CEREBRO_BIN" git "$REPO" diff HEAD~1 HEAD

# --- 4. denied git subcommand ---
STDERR_CONTAINS="not on allow-list" \
run_case 04 "git commit denied" 4 -- "$CEREBRO_BIN" git "$REPO" commit -m x

# --- 5. denied git flag (branch mutate) ---
STDERR_CONTAINS="mutating flag" \
run_case 05 "git branch -d denied" 5 -- "$CEREBRO_BIN" git "$REPO" branch -d main

# --- 6. denied git config write (positional with no --get) ---
STDERR_CONTAINS="missing --get" \
run_case 06 "git config user.email x@y denied" 5 -- "$CEREBRO_BIN" git "$REPO" config user.email x@y

# --- 7. denied global git flag (subcommand position is a flag) ---
STDERR_CONTAINS="subcommand position cannot be a flag" \
run_case 07 "git -c foo=bar log denied" 5 -- "$CEREBRO_BIN" git "$REPO" -c foo=bar log

# --- 8. shell metachars are inert (no shell in the exec path) ---
"$CEREBRO_BIN" git "$REPO" log ';foo;' >/dev/null 2>"$WORKDIR/stderr"
err="$(cat "$WORKDIR/stderr")"
if [[ "$err" != *"shell metacharacter"* ]]; then
  printf 'PASS  08  shell-metachar arg reaches git\n'
  pass=$((pass + 1))
else
  printf 'FAIL  08  bridge still rejects shell metachars: %s\n' "$err"
  fail=$((fail + 1))
  failures+=("08 :: $err")
fi

# --- 9. non-repo path ---
STDERR_CONTAINS="not a git repo" \
run_case 09 "git /tmp status (not a repo)" 3 -- "$CEREBRO_BIN" git /tmp status

# --- 10. non-absolute path ---
STDERR_CONTAINS="must be absolute" \
run_case 10 "git relative status" 3 -- "$CEREBRO_BIN" git relative status

# --- 11. denied gh write ---
STDERR_CONTAINS="not allow-listed" \
run_case 11 "gh pr create denied" 4 -- "$CEREBRO_BIN" gh "$REPO" pr create

# --- 12. denied gh api method ---
STDERR_CONTAINS="write flag" \
run_case 12 "gh api -X POST denied" 5 -- "$CEREBRO_BIN" gh "$REPO" api -X POST /repos/x/y

# --- 13. unknown gh top-level ---
STDERR_CONTAINS="not allow-listed" \
run_case 13 "gh gist list denied" 4 -- "$CEREBRO_BIN" gh "$REPO" gist list

# --- 14. read happy ---
run_case 14 "read a.txt happy" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt

# --- 15. read escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 15 "read ../etc/passwd denied" 6 -- "$CEREBRO_BIN" read "$REPO" ../etc/passwd

# --- 16. read non-file ---
STDERR_CONTAINS="not a regular file" \
run_case 16 "read . (directory) denied" 3 -- "$CEREBRO_BIN" read "$REPO" .

# --- 17. grep happy (no match -> rg returns 1; accept 0 or 1) ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'something' >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 0 || $rc -eq 1 ]]; then
    printf 'PASS  17  grep happy (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  17  grep happy [rc=%d expected 0 or 1]\n' "$rc"
    fail=$((fail + 1))
    failures+=("17 grep happy :: rc=$rc")
  fi
else
  printf 'SKIP  17  grep happy (rg not installed)\n'
fi

# --- 17b. grep with NO flag args (regression for nounset + empty rg_args) ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'no-such-literal' >/dev/null 2>&1
  rc=$?
  if [[ $rc -eq 0 || $rc -eq 1 ]]; then
    printf 'PASS  17b  grep no-flag-args (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  17b  grep no-flag-args [rc=%d expected 0 or 1]\n' "$rc"
    fail=$((fail + 1))
    failures+=("17b grep no-flag-args :: rc=$rc")
  fi
fi

# --- 18. grep escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 18 "grep --path ../.. escape denied" 6 -- "$CEREBRO_BIN" grep "$REPO" foo --path ../..

# --- 19. ls happy ---
out="$("$CEREBRO_BIN" ls "$REPO" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"a.txt"* ]]; then
  printf 'PASS  19  ls happy (lists a.txt)\n'
  pass=$((pass + 1))
else
  printf 'FAIL  19  ls happy [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("19 ls happy :: rc=$rc out=$out")
fi

# --- 20. ls escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 20 "ls ../.. escape denied" 6 -- "$CEREBRO_BIN" ls "$REPO" ../..

# --- 21. unknown top-level subcommand ---
STDERR_CONTAINS="unknown subcommand" \
run_case 21 "cerebro doesnotexist" 1 -- "$CEREBRO_BIN" doesnotexist

# --- 22. read outside repo refused (not a git worktree) ---
STDERR_CONTAINS="not a git worktree" \
run_case 22 "read /etc passwd (not a worktree)" 3 -- "$CEREBRO_BIN" read /etc passwd

# --- 23. grep outside repo refused ---
STDERR_CONTAINS="not a git worktree" \
run_case 23 "grep /etc foo (not a worktree)" 3 -- "$CEREBRO_BIN" grep /etc foo

# --- 24. ls outside repo refused ---
STDERR_CONTAINS="not a git worktree" \
run_case 24 "ls /etc (not a worktree)" 3 -- "$CEREBRO_BIN" ls /etc

# --- 25. git symbolic-ref removed from allow-list ---
STDERR_CONTAINS="not on allow-list" \
run_case 25 "git symbolic-ref denied" 4 -- "$CEREBRO_BIN" git "$REPO" symbolic-ref HEAD refs/heads/x

# --- 26. git remote add denied ---
STDERR_CONTAINS="git remote" \
run_case 26 "git remote add denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote add foo http://example/

# --- 27. git remote -v add smuggle denied ---
STDERR_CONTAINS="git remote: mutating action" \
run_case 27 "git remote -v add denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote -v add foo http://example/

# --- 28. git remote set-url denied ---
STDERR_CONTAINS="git remote: mutating action" \
run_case 28 "git remote set-url denied" 5 -- "$CEREBRO_BIN" git "$REPO" remote set-url origin foo

# --- 29. git diff --no-index denied ---
STDERR_CONTAINS="no-index" \
run_case 29 "git diff --no-index denied" 5 -- "$CEREBRO_BIN" git "$REPO" diff --no-index /etc/passwd /etc/hosts

# --- 30. git blame --contents denied ---
STDERR_CONTAINS="contents" \
run_case 30 "git blame --contents denied" 5 -- "$CEREBRO_BIN" git "$REPO" blame --contents /etc/passwd HEAD --

# --- 31. git config --file denied ---
STDERR_CONTAINS="git config" \
run_case 31 "git config --file /etc/passwd denied" 5 -- "$CEREBRO_BIN" git "$REPO" config --file /etc/passwd --get foo

# --- 32. git config --global denied ---
STDERR_CONTAINS="git config" \
run_case 32 "git config --global denied" 5 -- "$CEREBRO_BIN" git "$REPO" config --global --get user.email

# --- 33. git ls-files --exclude-from denied ---
STDERR_CONTAINS="ls-files" \
run_case 33 "git ls-files --exclude-from denied" 5 -- "$CEREBRO_BIN" git "$REPO" ls-files --exclude-from /etc/passwd

# --- 34. gh api -XPOST attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 34 "gh api -XPOST denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -XPOST /repos/x/y

# --- 35. gh api -Ffoo=bar attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 35 "gh api -Ffoo=bar denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -Ffoo=bar /repos/x/y

# --- 36. gh api -ffoo=bar attached short denied ---
STDERR_CONTAINS="write flag" \
run_case 36 "gh api -ffoo=bar denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api -ffoo=bar /repos/x/y

# --- 37. gh api --method=POST attached long denied ---
STDERR_CONTAINS="write flag" \
run_case 37 "gh api --method=POST denied (attached)" 5 -- "$CEREBRO_BIN" gh "$REPO" api --method=POST /repos/x/y

# --- 38. git config --list defaults to local (succeeds) ---
run_case 38 "git config --list happy (forced --local)" 0 -- "$CEREBRO_BIN" git "$REPO" config --list

# --- 39. git config -fpath attached form denied ---
STDERR_CONTAINS="git config" \
run_case 39 "git config -f/etc/passwd denied (attached)" 5 -- "$CEREBRO_BIN" git "$REPO" config -f/etc/passwd --get foo

# --- 40. git config --file=/etc/passwd attached form denied ---
STDERR_CONTAINS="git config" \
run_case 40 "git config --file=/etc/passwd denied (attached)" 5 -- "$CEREBRO_BIN" git "$REPO" config --file=/etc/passwd --get foo

# --- 41/42. .git/index left untouched by read-only bridge ---
# We poke a workdir file's mtime so a stat-only refresh of the index would
# otherwise happen. With `--no-optional-locks` plumbed into the bridge,
# `git status` skips the lazy index rewrite. (`git diff` upstream still
# refreshes the index when stat info is stale even with --no-optional-locks,
# so we exercise diff without the artificial mtime poke -- under realistic
# use the bridge must not touch the index there either.)
stat_index() {
  python3 - "$REPO/.git/index" <<'PY'
import os, sys
s = os.stat(sys.argv[1])
print(s.st_mtime_ns, s.st_ino, s.st_size)
PY
}

touch -t 202001010000 "$REPO/a.txt"
before_status="$(stat_index)"
"$CEREBRO_BIN" git "$REPO" status >/dev/null 2>&1
after_status="$(stat_index)"
if [[ "$before_status" == "$after_status" ]]; then
  printf 'PASS  41  git status leaves .git/index untouched\n'
  pass=$((pass + 1))
else
  printf 'FAIL  41  git status mutated .git/index [before=%s after=%s]\n' \
    "$before_status" "$after_status"
  fail=$((fail + 1))
  failures+=("41 git status leaves .git/index untouched :: before=$before_status after=$after_status")
fi

# Settle the index after the status path (also clears any pending stat
# discrepancy from earlier tests) before sampling for the diff test.
git -C "$REPO" update-index --refresh >/dev/null 2>&1 || true
before_diff="$(stat_index)"
"$CEREBRO_BIN" git "$REPO" diff >/dev/null 2>&1
after_diff="$(stat_index)"
if [[ "$before_diff" == "$after_diff" ]]; then
  printf 'PASS  42  git diff leaves .git/index untouched\n'
  pass=$((pass + 1))
else
  printf 'FAIL  42  git diff mutated .git/index [before=%s after=%s]\n' \
    "$before_diff" "$after_diff"
  fail=$((fail + 1))
  failures+=("42 git diff leaves .git/index untouched :: before=$before_diff after=$after_diff")
fi

# --- 43-46. external-helper flags refused on read-only subcommands ---
STDERR_CONTAINS="external helper flag" \
run_case 43 "git diff --ext-diff denied" 5 -- "$CEREBRO_BIN" git "$REPO" diff --ext-diff
STDERR_CONTAINS="external helper flag" \
run_case 44 "git log --textconv denied" 5 -- "$CEREBRO_BIN" git "$REPO" log --textconv
STDERR_CONTAINS="external helper flag" \
run_case 45 "git show --filters denied" 5 -- "$CEREBRO_BIN" git "$REPO" show --filters
STDERR_CONTAINS="external helper flag" \
run_case 46 "git blame --textconv denied" 5 -- "$CEREBRO_BIN" git "$REPO" blame --textconv a.txt

# --- 47. positive: diff still works when repo config sets diff.external=/bin/false ---
# Without the `--no-ext-diff` injection (or with a working override), an
# attacker-controlled `.git/config` could redirect every diff through an
# arbitrary program. The bridge must produce normal diff output here.
git -C "$REPO" config diff.external /bin/false
echo "tampered" > "$REPO/a.txt"
diff_out="$("$CEREBRO_BIN" git "$REPO" diff -- a.txt 2>"$WORKDIR/stderr")"
diff_rc=$?
diff_err="$(cat "$WORKDIR/stderr")"
git -C "$REPO" config --unset diff.external
if [[ $diff_rc -eq 0 && "$diff_out" == *"+tampered"* && "$diff_err" != *"external diff"* ]]; then
  printf 'PASS  47  git diff bypasses repo diff.external=/bin/false\n'
  pass=$((pass + 1))
else
  printf 'FAIL  47  git diff with diff.external=/bin/false [rc=%d out=%s err=%s]\n' \
    "$diff_rc" "$diff_out" "$diff_err"
  fail=$((fail + 1))
  failures+=("47 diff.external bypass :: rc=$diff_rc out=$diff_out err=$diff_err")
fi
# Restore a.txt so later test rounds see a clean tree.
git -C "$REPO" checkout -q -- a.txt 2>/dev/null || true

# --- 48-50. gh happy paths via a PATH stub ---
# We can't (and don't want to) call the real `gh` from tests. Drop a stub on
# PATH that records argv to a file, then assert each allowed dispatch reaches
# the stub with the expected argv. This guards the actual exec path -- denial
# tests alone would miss a regression that broke `exec gh "$top" "$@"`.
GH_STUB_DIR="$WORKDIR/gh-stub"
mkdir -p "$GH_STUB_DIR"
GH_ARGV_LOG="$WORKDIR/gh-argv.log"
cat > "$GH_STUB_DIR/gh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GH_ARGV_LOG"
exit 0
EOF
chmod +x "$GH_STUB_DIR/gh"

gh_happy() {
  local id="$1" desc="$2" expected_argv="$3"; shift 3
  : > "$GH_ARGV_LOG"
  PATH="$GH_STUB_DIR:$PATH" "$CEREBRO_BIN" gh "$REPO" "$@" >/dev/null 2>"$WORKDIR/stderr"
  local rc=$?
  local got; got="$(cat "$GH_ARGV_LOG" 2>/dev/null)"
  if [[ $rc -eq 0 && "$got" == "$expected_argv" ]]; then
    printf 'PASS  %s  %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s  %s [rc=%d argv=%q expected=%q]\n' \
      "$id" "$desc" "$rc" "$got" "$expected_argv"
    fail=$((fail + 1))
    failures+=("$id $desc :: rc=$rc argv=$got expected=$expected_argv")
  fi
}

gh_happy 48 "gh pr view 123 dispatches" "pr view 123"        pr view 123
gh_happy 49 "gh pr list --limit 5 dispatches" "pr list --limit 5" pr list --limit 5
gh_happy 50 "gh api /repos/foo/bar dispatches" "api /repos/foo/bar" api /repos/foo/bar

# --- 51. shell metachars pass through to gh (jq -q with commas/parens) ---
gh_happy 51 "gh pr view --json with -q containing commas/parens/spaces" \
  "pr view 64 --json baseRefName,headRefName,commits -q .baseRefName, .headRefName, (.commits | length)" \
  pr view 64 --json baseRefName,headRefName,commits -q ".baseRefName, .headRefName, (.commits | length)"

# --- 52. cerebro note writes to sessions/<id>/plans/ ---
note_path="$("$CEREBRO_BIN" note 'fix: drop stray semicolon in foo.js' --out fix-foo 2>/dev/null)"
if [[ -f "$note_path" && "$note_path" == *"plans/fix-foo.md" ]] \
   && grep -q 'fix: drop stray semicolon' "$note_path"; then
  printf 'PASS  52  cerebro note writes plan file\n'; pass=$((pass + 1))
else
  printf 'FAIL  52  cerebro note [path=%s]\n' "$note_path"
  fail=$((fail + 1)); failures+=("52 note :: path=$note_path")
fi

# --- 53. cerebro note refuses overwrite ---
STDERR_CONTAINS="refusing to overwrite" \
run_case 53 "cerebro note --out fix-foo (collision)" 1 \
  -- "$CEREBRO_BIN" note 'second body' --out fix-foo

# --- 54. cerebro note auto-names without --out ---
auto_path="$("$CEREBRO_BIN" note 'auto body' 2>/dev/null)"
if [[ -f "$auto_path" && "$auto_path" == *"plans/note-1.md" ]]; then
  printf 'PASS  54  cerebro note auto-names\n'; pass=$((pass + 1))
else
  printf 'FAIL  54  cerebro note auto-name [path=%s]\n' "$auto_path"
  fail=$((fail + 1)); failures+=("54 note auto :: path=$auto_path")
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf '\nFailures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
exit 0
