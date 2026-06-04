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
# Optional: STDOUT_CONTAINS=<substring> env to assert a substring of stdout.
run_case() {
  local id="$1" desc="$2" expected="$3"
  shift 3
  [[ "$1" == "--" ]] && shift
  local needle="${STDERR_CONTAINS:-}"
  local out_needle="${STDOUT_CONTAINS:-}"
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
  if [[ -n "$out_needle" && "$out" != *"$out_needle"* ]]; then
    note="${note:+$note; }stdout missing '$out_needle': $out"
  fi

  if [[ -z "$note" ]]; then
    printf 'PASS  %s  %s\n' "$id" "$desc"
    pass=$((pass + 1))
  else
    printf 'FAIL  %s  %s  [%s]\n' "$id" "$desc" "$note"
    fail=$((fail + 1))
    failures+=("$id $desc :: $note")
  fi
  unset STDERR_CONTAINS STDOUT_CONTAINS
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

# --- 13. denied gh write (gist create); gist list itself is allow-listed ---
STDERR_CONTAINS="not allow-listed" \
run_case 13 "gh gist create denied" 4 -- "$CEREBRO_BIN" gh "$REPO" gist create

# --- 14. read happy ---
run_case 14 "read a.txt happy" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt

# --- 15. read escape ---
STDERR_CONTAINS="path escapes repo" \
run_case 15 "read ../etc/passwd denied" 6 -- "$CEREBRO_BIN" read "$REPO" ../etc/passwd

# --- 16. read non-file: benign by default (marker + exit 0) ---
STDOUT_CONTAINS="(not found:" \
run_case 16 "read . (directory) benign miss" 0 -- "$CEREBRO_BIN" read "$REPO" .

# --- 16b. read non-file --strict-missing restores exit 3 ---
STDERR_CONTAINS="not a regular file" \
run_case 16b "read . (directory) --strict-missing" 3 -- "$CEREBRO_BIN" read "$REPO" . --strict-missing

# --- 16c. read missing in-repo file: benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 16c "read no/such/file.txt benign miss" 0 -- "$CEREBRO_BIN" read "$REPO" no/such/file.txt

# --- 16d. read missing in-repo file --strict-missing ---
STDERR_CONTAINS="not a regular file" \
run_case 16d "read no/such/file.txt --strict-missing" 3 -- "$CEREBRO_BIN" read "$REPO" no/such/file.txt --strict-missing

# --- 17. grep zero matches: benign by default ('(no matches)' + exit 0) ---
if command -v rg >/dev/null 2>&1; then
  STDOUT_CONTAINS="(no matches)" \
  run_case 17 "grep zero-match benign" 0 -- "$CEREBRO_BIN" grep "$REPO" 'something'
else
  printf 'SKIP  17  grep zero-match (rg not installed)\n'
fi

# --- 17b. grep with NO flag args (regression for nounset + empty rg_args) ---
if command -v rg >/dev/null 2>&1; then
  STDOUT_CONTAINS="(no matches)" \
  run_case 17b "grep no-flag-args zero-match benign" 0 -- "$CEREBRO_BIN" grep "$REPO" 'no-such-literal'
fi

# --- 17c. grep zero matches --strict-missing restores rg-native exit 1 ---
if command -v rg >/dev/null 2>&1; then
  run_case 17c "grep zero-match --strict-missing (rg exit 1)" 1 -- "$CEREBRO_BIN" grep "$REPO" 'something' --strict-missing
fi

# --- 17d. grep bad regex: genuine rg error stays hard (rc >= 2) ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" '(' >/dev/null 2>&1
  rc=$?
  if [[ $rc -ge 2 ]]; then
    printf 'PASS  17d  grep bad-regex stays hard (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  17d  grep bad-regex [rc=%d expected >=2]\n' "$rc"
    fail=$((fail + 1))
    failures+=("17d grep bad-regex :: rc=$rc")
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

# --- 20b. ls missing in-repo dir: benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 20b "ls no/such/dir benign miss" 0 -- "$CEREBRO_BIN" ls "$REPO" no/such/dir

# --- 20c. ls missing in-repo dir --strict-missing ---
STDERR_CONTAINS="not a directory" \
run_case 20c "ls no/such/dir --strict-missing" 3 -- "$CEREBRO_BIN" ls "$REPO" no/such/dir --strict-missing

# --- 20d. ls bare-abs missing path: benign by default (exit-7 routing) ---
STDOUT_CONTAINS="(not found:" \
run_case 20d "ls bare-abs missing benign" 0 -- "$CEREBRO_BIN" ls "$WORKDIR/does-not-exist"

# --- 20e. ls bare-abs missing path --strict-missing ---
STDERR_CONTAINS="not found" \
run_case 20e "ls bare-abs missing --strict-missing" 3 -- "$CEREBRO_BIN" ls "$WORKDIR/does-not-exist" --strict-missing

# --- 21. unknown top-level subcommand ---
STDERR_CONTAINS="unknown subcommand" \
run_case 21 "cerebro doesnotexist" 1 -- "$CEREBRO_BIN" doesnotexist

# --- 22. read outside repo (not a git worktree): benign by default ---
STDOUT_CONTAINS="(not found:" \
run_case 22 "read /etc passwd (not a worktree) benign" 0 -- "$CEREBRO_BIN" read /etc passwd

# --- 22b. read /etc passwd --strict-missing restores exit 3 ---
STDERR_CONTAINS="not a git worktree" \
run_case 22b "read /etc passwd --strict-missing" 3 -- "$CEREBRO_BIN" read /etc passwd --strict-missing

# --- 23. grep bare-abs: pattern required (no worktree, but pattern missing) ---
STDERR_CONTAINS="usage" \
run_case 23 "grep /etc (no pattern) usage error" 2 -- "$CEREBRO_BIN" grep /etc

# Pre-create a directory the bare-abs cases below can read out of.
mkdir -p "$WORKDIR/lookups"
printf 'findme\n' > "$WORKDIR/lookups/needle.txt"

# --- 24. ls bare-abs against a directory the sandbox controls ---
out="$("$CEREBRO_BIN" ls "$WORKDIR/lookups" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"needle.txt"* ]]; then
  printf 'PASS  24  ls bare-abs (lists needle.txt)\n'
  pass=$((pass + 1))
else
  printf 'FAIL  24  ls bare-abs [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("24 ls bare-abs :: rc=$rc out=$out")
fi

# --- 25. git symbolic-ref SET form denied (read form is allowed; see 73) ---
STDERR_CONTAINS="SET form" \
run_case 25 "git symbolic-ref SET form denied" 5 -- "$CEREBRO_BIN" git "$REPO" symbolic-ref HEAD refs/heads/x

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

# ========================================================================
# Category A coverage (52-63): forgiving argv shapes for read/grep/ls.
# ========================================================================

# --- 52. read abs file path infers enclosing repo ---
out="$("$CEREBRO_BIN" read "$REPO/a.txt" --range 1:1 2>"$WORKDIR/stderr")"
rc=$?
err="$(cat "$WORKDIR/stderr")"
if [[ $rc -eq 0 && "$err" == *"inferred repo"* ]]; then
  printf 'PASS  52  read with abs file path infers repo\n'
  pass=$((pass + 1))
else
  printf 'FAIL  52  read abs-file repo-infer [rc=%d err=%s]\n' "$rc" "$err"
  fail=$((fail + 1))
  failures+=("52 read abs-file repo-infer :: rc=$rc err=$err")
fi

# --- 53. read abs file no flag (legacy file form ok) ---
run_case 53 "read abs file no flag happy" 0 -- "$CEREBRO_BIN" read "$REPO/a.txt"

# --- 54. read --range N-M ---
run_case 54 "read --range N-M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1-1

# --- 55. read --range N..M ---
run_case 55 "read --range N..M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1..1

# --- 56. read --range N M (two ints) ---
run_case 56 "read --range N M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1 1

# --- 57. read --from N --to M ---
run_case 57 "read --from N --to M" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --from 1 --to 1

# --- 58. read --range N (open-ended) ---
run_case 58 "read --range bare-N" 0 -- "$CEREBRO_BIN" read "$REPO" a.txt --range 1

# --- 59. read ./a.txt ---
run_case 59 "read ./a.txt" 0 -- "$CEREBRO_BIN" read "$REPO" ./a.txt

# --- 60. read bogus --range value emits canonical hint ---
STDERR_CONTAINS="canonical: --range" \
run_case 60 "read bad --range value with hint" 2 -- "$CEREBRO_BIN" read "$REPO" a.txt --range abc

# --- 61. grep --type rs aliased to rust ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'pattern' --type rs >/dev/null 2>"$WORKDIR/stderr"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$err" != *"unrecognized file type"* ]]; then
    printf 'PASS  61  grep --type rs aliased to rust (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  61  grep --type rs alias [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("61 grep --type rs alias :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  61  grep --type rs aliased (rg not installed)\n'
fi

# --- 62. grep --type yml aliased to yaml ---
if command -v rg >/dev/null 2>&1; then
  "$CEREBRO_BIN" grep "$REPO" 'pattern' --type yml >/dev/null 2>"$WORKDIR/stderr"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$err" != *"unrecognized file type"* ]]; then
    printf 'PASS  62  grep --type yml aliased to yaml (rc=%d)\n' "$rc"
    pass=$((pass + 1))
  else
    printf 'FAIL  62  grep --type yml alias [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("62 grep --type yml alias :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  62  grep --type yml aliased (rg not installed)\n'
fi

# --- 63. grep unknown arg with canonical hint ---
STDERR_CONTAINS="canonical: cerebro grep" \
run_case 63 "grep unknown arg with hint" 2 -- "$CEREBRO_BIN" grep "$REPO" foo --nope

# ========================================================================
# Category B coverage (64-73d): broadened git allow-list.
# ========================================================================

run_case 64 "git rev-list HEAD happy" 0 -- "$CEREBRO_BIN" git "$REPO" rev-list -n 1 HEAD
run_case 65 "git count-objects happy" 0 -- "$CEREBRO_BIN" git "$REPO" count-objects
run_case 66 "git show-ref happy" 0 -- "$CEREBRO_BIN" git "$REPO" show-ref
run_case 67 "git check-ref-format happy" 0 -- "$CEREBRO_BIN" git "$REPO" check-ref-format refs/heads/main
run_case 68 "git var GIT_EDITOR happy" 0 -- "$CEREBRO_BIN" git "$REPO" var GIT_EDITOR
run_case 69 "git diff-tree happy" 0 -- "$CEREBRO_BIN" git "$REPO" diff-tree -r HEAD
run_case 70 "git range-diff self happy" 0 -- "$CEREBRO_BIN" git "$REPO" range-diff HEAD~1..HEAD HEAD~1..HEAD

# --- 71. git archive --output denied (matched by global deny-list) ---
STDERR_CONTAINS="denied global flag: --output" \
run_case 71 "git archive --output denied" 5 -- "$CEREBRO_BIN" git "$REPO" archive --output /tmp/x.tar HEAD

# --- 72. git hash-object -w denied ---
STDERR_CONTAINS="-w writes" \
run_case 72 "git hash-object -w denied" 5 -- \
  bash -c "printf x | '$CEREBRO_BIN' git '$REPO' hash-object -w --stdin"

# --- 73. git symbolic-ref read form happy ---
run_case 73 "git symbolic-ref read form happy" 0 -- "$CEREBRO_BIN" git "$REPO" symbolic-ref HEAD

# --- 73b. git apply requires --check ---
STDERR_CONTAINS="only --check form allowed" \
run_case 73b "git apply without --check denied" 5 -- "$CEREBRO_BIN" git "$REPO" apply some.patch

# --- 73c. git fetch reaches git (allow-list + no mutating flags) ---
"$CEREBRO_BIN" git "$REPO" fetch >/dev/null 2>"$WORKDIR/stderr"
rc=$?
err="$(cat "$WORKDIR/stderr")"
if [[ "$err" != *"not on allow-list"* && "$err" != *"mutating flag"* && "$err" != *"denied global flag"* ]]; then
  printf 'PASS  73c  git fetch reaches git (rc=%d)\n' "$rc"
  pass=$((pass + 1))
else
  printf 'FAIL  73c  git fetch blocked by bridge [rc=%d err=%s]\n' "$rc" "$err"
  fail=$((fail + 1))
  failures+=("73c git fetch reaches git :: rc=$rc err=$err")
fi

# --- 73d. git fetch --prune denied ---
STDERR_CONTAINS="mutating flag: --prune" \
run_case 73d "git fetch --prune denied" 5 -- "$CEREBRO_BIN" git "$REPO" fetch --prune

# --- 73e. git fast-export --export-marks denied ---
STDERR_CONTAINS="mutating flag: --export-marks" \
run_case 73e "git fast-export --export-marks denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" fast-export --export-marks=/tmp/marks --all

# --- 73f. git replace positional SET form denied (no --list) ---
STDERR_CONTAINS="positional arg without --list" \
run_case 73f "git replace SET form denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" replace HEAD HEAD~1

# --- 73g. git symbolic-ref --delete denied ---
STDERR_CONTAINS="mutating flag: --delete" \
run_case 73g "git symbolic-ref --delete denied" 5 -- \
  "$CEREBRO_BIN" git "$REPO" symbolic-ref --delete HEAD

# ========================================================================
# Category C coverage (74-83b): broadened gh allow-list (via PATH stub).
# ========================================================================

gh_happy 74 "gh workflow list dispatches" "workflow list" workflow list

STDERR_CONTAINS="not allow-listed" \
run_case 75 "gh workflow run denied" 4 -- "$CEREBRO_BIN" gh "$REPO" workflow run wf.yml

gh_happy 76 "gh secret list dispatches" "secret list" secret list

STDERR_CONTAINS="not allow-listed" \
run_case 77 "gh secret set denied" 4 -- "$CEREBRO_BIN" gh "$REPO" secret set NAME

gh_happy 78 "gh cache list dispatches" "cache list" cache list
gh_happy 79 "gh label list dispatches" "label list" label list
gh_happy 80 "gh codespace list dispatches" "codespace list" codespace list

# --- 80b. gh codespace ports (bare) dispatches ---
gh_happy 80b "gh codespace ports happy" "codespace ports" codespace ports

# --- 80c. gh codespace ports forward denied (nested mutating verb) ---
STDERR_CONTAINS="codespace ports" \
run_case 80c "gh codespace ports forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports forward 8080

# --- 80d. gh codespace ports visibility denied (nested mutating verb) ---
STDERR_CONTAINS="codespace ports" \
run_case 80d "gh codespace ports visibility denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports visibility 8080:private

# --- 80e. gh codespace ports -c <name> forward denied (flag-before-subcmd) ---
STDERR_CONTAINS="forward" \
run_case 80e "gh codespace ports -c name forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports -c some-name forward 8080:8080

# --- 80f. gh codespace ports --json visibility happy (visibility as JSON field) ---
gh_happy 80f "gh codespace ports --json visibility happy" \
  "codespace ports --json visibility" \
  codespace ports --json visibility

# --- 80g. gh codespace ports -c visibility forward denied (flag value skipped) ---
STDERR_CONTAINS="forward" \
run_case 80g "gh codespace ports -c visibility forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports -c visibility forward 8080:8080

# --- 80h. gh codespace ports --codespace=visibility happy (equals-form value) ---
gh_happy 80h "gh codespace ports --codespace=visibility happy" \
  "codespace ports --codespace=visibility" \
  codespace ports --codespace=visibility

# --- 80i. gh codespace ports --repo-owner <owner> forward denied (codex case) ---
STDERR_CONTAINS="forward" \
run_case 80i "gh codespace ports --repo-owner alice forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports --repo-owner alice forward 8080:8080

# --- 80j. gh codespace ports --repo-owner=alice happy (equals form is self-contained) ---
gh_happy 80j "gh codespace ports --repo-owner=alice happy" \
  "codespace ports --repo-owner=alice" \
  codespace ports --repo-owner=alice

# --- 80k. gh codespace ports --display-name <name> forward denied (audit-added flag) ---
STDERR_CONTAINS="forward" \
run_case 80k "gh codespace ports --display-name name forward denied" 4 -- \
  "$CEREBRO_BIN" gh "$REPO" codespace ports --display-name my-space forward 8080:8080

STDERR_CONTAINS="not allow-listed" \
run_case 81 "gh auth token denied" 4 -- "$CEREBRO_BIN" gh "$REPO" auth token

gh_happy 82 "gh config get editor dispatches" "config get editor" config get editor

STDERR_CONTAINS="runs arbitrary code" \
run_case 83 "gh extension install denied with reason" 4 -- "$CEREBRO_BIN" gh "$REPO" extension install owner/repo

STDERR_CONTAINS="side-effect" \
run_case 83b "gh browse top-level denied" 4 -- "$CEREBRO_BIN" gh "$REPO" browse

# ========================================================================
# Category D coverage (84-92): bare-abs read/grep/ls.
# ========================================================================

# Sandbox-local file outside any worktree.
printf 'hello\n' > "$WORKDIR/outside.txt"

# --- 84. read bare-abs file happy ---
out="$("$CEREBRO_BIN" read "$WORKDIR/outside.txt" 2>"$WORKDIR/stderr")"
rc=$?
if [[ $rc -eq 0 && "$out" == *"hello"* ]]; then
  printf 'PASS  84  read bare-abs file happy\n'
  pass=$((pass + 1))
else
  printf 'FAIL  84  read bare-abs file happy [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("84 read bare-abs file :: rc=$rc out=$out")
fi

# --- 85. read bare-abs file with --range ---
run_case 85 "read bare-abs --range" 0 -- "$CEREBRO_BIN" read "$WORKDIR/outside.txt" --range 1:1

# --- 86. read bare-abs special path: security refusal stays hard (exit 6) ---
STDERR_CONTAINS="special path" \
run_case 86 "read /dev/null denied (security)" 6 -- "$CEREBRO_BIN" read /dev/null

# --- 87. read bare-abs another special path: security refusal stays hard ---
STDERR_CONTAINS="special path" \
run_case 87 "read /dev/tty denied (under /dev/)" 6 -- "$CEREBRO_BIN" read /dev/tty

# --- 88. read bare-abs nonexistent: benign by default (exit-7 routing) ---
STDOUT_CONTAINS="(not found:" \
run_case 88 "read nonexistent bare-abs benign" 0 -- "$CEREBRO_BIN" read /no/such/path/xyz

# --- 88b. read bare-abs nonexistent --strict-missing restores exit 3 ---
STDERR_CONTAINS="not found" \
run_case 88b "read nonexistent bare-abs --strict-missing" 3 -- "$CEREBRO_BIN" read /no/such/path/xyz --strict-missing

# --- 89. grep bare-abs happy (sandbox dir) ---
if command -v rg >/dev/null 2>&1; then
  out="$("$CEREBRO_BIN" grep "$WORKDIR/lookups" findme 2>/dev/null)"
  rc=$?
  if [[ ( $rc -eq 0 || $rc -eq 1 ) && "$out" == *"needle.txt"*"findme"* ]]; then
    printf 'PASS  89  grep bare-abs happy\n'
    pass=$((pass + 1))
  else
    printf 'FAIL  89  grep bare-abs happy [rc=%d out=%s]\n' "$rc" "$out"
    fail=$((fail + 1))
    failures+=("89 grep bare-abs happy :: rc=$rc out=$out")
  fi
else
  printf 'SKIP  89  grep bare-abs happy (rg not installed)\n'
fi

# --- 90. grep bare-abs missing pattern ---
STDERR_CONTAINS="usage" \
run_case 90 "grep bare-abs missing pattern" 2 -- "$CEREBRO_BIN" grep "$WORKDIR/lookups"

# --- 91. ls bare-abs happy ---
out="$("$CEREBRO_BIN" ls "$WORKDIR/lookups" 2>/dev/null)"
rc=$?
if [[ $rc -eq 0 && "$out" == *"needle.txt"* ]]; then
  printf 'PASS  91  ls bare-abs lists needle.txt\n'
  pass=$((pass + 1))
else
  printf 'FAIL  91  ls bare-abs [rc=%d out=%s]\n' "$rc" "$out"
  fail=$((fail + 1))
  failures+=("91 ls bare-abs :: rc=$rc out=$out")
fi

# --- 92. ls bare-abs special path: security refusal stays hard (exit 6) ---
STDERR_CONTAINS="special path" \
run_case 92 "ls /dev denied (security)" 6 -- "$CEREBRO_BIN" ls /dev

# ========================================================================
# apply-review default-findings and staleness validation.
# These validation paths fire BEFORE any child claude spawn, so the
# error cases need no claude. The happy cases install a `claude` PATH stub
# (mirroring the gh stub above) that consumes stdin and emits one success
# stream-json event, so apply-review completes.
# ========================================================================

SESS_DIR="$CEREBRO_HOME/sessions/$CEREBRO_SESSION_ID"
RSTATE="$SESS_DIR/review-state"
CHILDREN="$SESS_DIR/children"
# Per-repo key the same way cerebro computes it: sha1 of the canonical
# worktree root, first 16 hex.
RKEY="$(git -C "$REPO" rev-parse --show-toplevel \
        | python3 -c 'import hashlib,sys; print(hashlib.sha1(sys.stdin.read().strip().encode()).hexdigest()[:16])')"
BRANCH="$(git -C "$REPO" rev-parse --abbrev-ref HEAD)"

# claude stub: read the piped prompt, emit one success result event, exit 0.
CLAUDE_STUB_DIR="$WORKDIR/claude-stub"
mkdir -p "$CLAUDE_STUB_DIR"
cat > "$CLAUDE_STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"type":"result","subtype":"success","result":"ok"}'
exit 0
EOF
chmod +x "$CLAUDE_STUB_DIR/claude"
STUB_OK=0; [[ -x "$CLAUDE_STUB_DIR/claude" ]] && STUB_OK=1
STUB_PATH="$CLAUDE_STUB_DIR:$PATH"

seed_review_state() {  # $1 = last_findings path
  mkdir -p "$RSTATE"
  jq -n --arg repo "$(git -C "$REPO" rev-parse --show-toplevel)" \
        --arg branch "$BRANCH" --arg sha "$(git -C "$REPO" rev-parse HEAD)" \
        --arg findings "$1" --arg ts "2026-01-01T00:00:00Z" \
        '{repo:$repo, branch:$branch, last_reviewed_sha:$sha, last_findings:$findings, ts:$ts}' \
        > "$RSTATE/$RKEY.json"
}

# --- 93. apply-review with no findings defaults to last review's findings ---
if (( STUB_OK )); then
  printf 'review findings here\n' > "$CHILDREN/codex-TEST.md"
  seed_review_state "$CHILDREN/codex-TEST.md"
  STDERR_CONTAINS="defaulting to last review findings" \
  run_case 93 "apply-review defaults to last review findings" 0 -- \
    env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO"
else
  printf 'SKIP  93  apply-review default findings (claude stub unavailable)\n'
fi

# --- 94. apply-review, no findings + no prior review -> clear error ---
rm -f "$RSTATE/$RKEY.json"
STDERR_CONTAINS="no prior review for this repo+branch" \
run_case 94 "apply-review no findings, no prior review errors" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO"

# --- 95. nonexistent explicit findings names the correct last-review path ---
seed_review_state "$CHILDREN/codex-TEST.md"
STDERR_CONTAINS="the last review for this repo+branch is:" \
run_case 95 "apply-review bad explicit findings names latest" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" /no/such/findings.md

# --- 96. stale (older) findings warns non-fatally but still applies ---
if (( STUB_OK )); then
  printf 'older findings\n' > "$WORKDIR/older.md"
  seed_review_state "$CHILDREN/codex-TEST.md"   # newest != older.md
  STDERR_CONTAINS="not the latest review" \
  run_case 96 "apply-review stale findings warns, applies" 0 -- \
    env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO" "$WORKDIR/older.md"
else
  printf 'SKIP  96  apply-review stale findings (claude stub unavailable)\n'
fi

# --- 99. regression: --notes with --prompt still rejected ---
STDERR_CONTAINS="only meaningful with a findings file" \
run_case 99 "apply-review --notes + --prompt still errors" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt "x" --notes "y"

# --- 100. --prompt with NO operand is a usage error, never a findings fallback.
# Seed a valid last review so a buggy fallback WOULD succeed; the guard must
# still reject the empty --prompt rather than silently apply those findings.
printf 'seeded findings\n' > "$CHILDREN/codex-TEST.md"
seed_review_state "$CHILDREN/codex-TEST.md"
STDERR_CONTAINS="--prompt requires a non-empty value" \
run_case 100 "apply-review --prompt (no value) errors, no findings fallback" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt

# --- 100b. --prompt "" (explicit empty operand) is likewise a usage error. ---
seed_review_state "$CHILDREN/codex-TEST.md"
STDERR_CONTAINS="--prompt requires a non-empty value" \
run_case 100b "apply-review --prompt '' errors, no findings fallback" 1 -- \
  "$CEREBRO_BIN" apply-review "$REPO" --prompt ""

# --- 102. explicit-findings staleness check must NOT cross branches. ---
# Seed review state on the current branch naming codex-TEST.md, then switch
# to a new branch and apply a DIFFERENT (older) findings file. The stored
# state belongs to the other branch, so cerebro must not name codex-TEST.md
# as "latest for this repo+branch".
if (( STUB_OK )); then
  printf 'older findings\n' > "$WORKDIR/older2.md"
  seed_review_state "$CHILDREN/codex-TEST.md"   # state recorded for $BRANCH
  git -C "$REPO" checkout -q -b other-branch
  out="$(env PATH="$STUB_PATH" "$CEREBRO_BIN" apply-review "$REPO" "$WORKDIR/older2.md" 2>"$WORKDIR/stderr")"
  rc=$?
  err="$(cat "$WORKDIR/stderr")"
  git -C "$REPO" checkout -q "$BRANCH"
  if [[ $rc -eq 0 && "$err" != *"not the latest review"* && "$err" != *"codex-TEST.md"* ]]; then
    printf 'PASS  102  staleness naming does not cross branches\n'; pass=$((pass + 1))
  else
    printf 'FAIL  102  staleness check crossed branches [rc=%d err=%s]\n' "$rc" "$err"
    fail=$((fail + 1))
    failures+=("102 branch-cross staleness :: rc=$rc err=$err")
  fi
else
  printf 'SKIP  102  apply-review branch-switch staleness (claude stub unavailable)\n'
fi

# ========================================================================
# 103. Concurrent mutating runs must write to DISTINCT child-log files.
# After dropping the per-repo lock, two same-session mutating ops can start
# within the same second. A bare <subcmd>-<ts> child-log name would let both
# tee into ONE file -> truncated/interleaved logs and an ambiguous echoed
# path. The child-log name is now collision-resistant (PID + random token),
# so each run gets its own file. We launch two apply-review ops concurrently
# (a stub that sleeps to force overlapping writes, tagging each emitted line
# with a per-run token), then assert the two echoed paths differ and that
# neither log shows the other run's token (no interleave/truncation).
# ========================================================================
if (( STUB_OK )); then
  CONC_STUB_DIR="$WORKDIR/conc-stub"
  mkdir -p "$CONC_STUB_DIR"
  cat > "$CONC_STUB_DIR/claude" <<'EOF'
#!/usr/bin/env bash
# Echo back the per-run token carried in the prompt, many times over, so a
# shared child log would visibly interleave the two runs' output.
body="$(cat)"
tok="$(printf '%s\n' "$body" | grep -o 'TOKEN=[A-Z]*' | head -1)"
tok="${tok#TOKEN=}"
sleep 0.4   # widen the window so both runs write concurrently
for i in $(seq 1 300); do
  printf '{"type":"assistant","tok":"%s","i":%d}\n' "$tok" "$i"
done
printf '%s\n' '{"type":"result","subtype":"success","result":"ok"}'
exit 0
EOF
  chmod +x "$CONC_STUB_DIR/claude"
  CONC_PATH="$CONC_STUB_DIR:$PATH"

  env PATH="$CONC_PATH" "$CEREBRO_BIN" apply-review "$REPO" \
    --prompt "do work TOKEN=AAAA" >"$WORKDIR/conc1.out" 2>/dev/null &
  c1=$!
  env PATH="$CONC_PATH" "$CEREBRO_BIN" apply-review "$REPO" \
    --prompt "do work TOKEN=BBBB" >"$WORKDIR/conc2.out" 2>/dev/null &
  c2=$!
  wait "$c1"; r1=$?
  wait "$c2"; r2=$?

  # The echoed child-log path is the final stdout line of each run.
  clog1="$(tail -1 "$WORKDIR/conc1.out")"
  clog2="$(tail -1 "$WORKDIR/conc2.out")"

  conc_ok=1; conc_why=""
  if (( r1 != 0 || r2 != 0 )); then
    conc_ok=0; conc_why="nonzero rc (r1=$r1 r2=$r2)"
  fi
  if [[ -z "$clog1" || -z "$clog2" || "$clog1" == "$clog2" ]]; then
    conc_ok=0; conc_why="${conc_why:+$conc_why; }child logs not distinct: '$clog1' vs '$clog2'"
  fi
  if [[ ! -f "$clog1" || ! -f "$clog2" ]]; then
    conc_ok=0; conc_why="${conc_why:+$conc_why; }child log file(s) missing"
  else
    a1="$(grep -c 'AAAA' "$clog1")"; b1="$(grep -c 'BBBB' "$clog1")"
    a2="$(grep -c 'AAAA' "$clog2")"; b2="$(grep -c 'BBBB' "$clog2")"
    if (( a1 != 300 || b1 != 0 || b2 != 300 || a2 != 0 )); then
      conc_ok=0
      conc_why="${conc_why:+$conc_why; }interleave/truncation (A1=$a1 B1=$b1 A2=$a2 B2=$b2)"
    fi
  fi

  if (( conc_ok )); then
    printf 'PASS  103  concurrent mutating runs use distinct child logs\n'
    pass=$((pass + 1))
  else
    printf 'FAIL  103  concurrent mutating runs collided [%s]\n' "$conc_why"
    fail=$((fail + 1))
    failures+=("103 concurrent child-log collision :: $conc_why")
  fi
else
  printf 'SKIP  103  concurrent child-log distinctness (claude stub unavailable)\n'
fi

# ========================================================================
# 104-110. Preference learning: learn-note (pending journal), learn-set
# (active learnings, size-capped), and learnings (inspection). These files
# are global under $CEREBRO_HOME and persist across sessions.
# ========================================================================
LEARN_ACTIVE="$CEREBRO_HOME/learnings.md"
LEARN_PENDING="$CEREBRO_HOME/pending-learnings.md"

# --- 104. learnings on a clean home reports none ---
STDOUT_CONTAINS="(none yet)" \
run_case 104 "learnings empty reports none" 0 -- "$CEREBRO_BIN" learnings

# --- 105. learn-note appends to the pending journal ---
run_case 105 "learn-note records a signal" 0 -- \
  "$CEREBRO_BIN" learn-note "user repeatedly asks to simplify"
if [[ -s "$LEARN_PENDING" ]] && grep -q "user repeatedly asks to simplify" "$LEARN_PENDING"; then
  printf 'PASS  105b  learn-note wrote pending journal\n'; pass=$((pass + 1))
else
  printf 'FAIL  105b  learn-note did not write pending journal\n'; fail=$((fail + 1))
  failures+=("105b learn-note pending journal missing entry")
fi

# --- 106. learn-note with blank text errors ---
STDERR_CONTAINS="usage: cerebro learn-note" \
run_case 106 "learn-note blank errors" 1 -- "$CEREBRO_BIN" learn-note "   "

# --- 107. learn-set writes the active learnings ---
run_case 107 "learn-set writes active learnings" 0 -- \
  "$CEREBRO_BIN" learn-set "- Keep diffs small; avoid over-engineering."
if [[ -s "$LEARN_ACTIVE" ]] && grep -q "avoid over-engineering" "$LEARN_ACTIVE"; then
  printf 'PASS  107b  learn-set wrote active learnings\n'; pass=$((pass + 1))
else
  printf 'FAIL  107b  learn-set did not write active learnings\n'; fail=$((fail + 1))
  failures+=("107b learn-set active learnings missing")
fi

# --- 108. learnings now shows the active set ---
STDOUT_CONTAINS="avoid over-engineering" \
run_case 108 "learnings shows active set" 0 -- "$CEREBRO_BIN" learnings

# --- 109. learn-set rejects oversized payloads (system-message budget) ---
BIG="$(head -c 1700 < /dev/zero | tr '\0' 'x')"
STDERR_CONTAINS="too large" \
run_case 109 "learn-set oversized rejected" 1 -- "$CEREBRO_BIN" learn-set "$BIG"
# The prior (valid) active learnings must survive a rejected overwrite.
if grep -q "avoid over-engineering" "$LEARN_ACTIVE"; then
  printf 'PASS  109b  rejected learn-set left active learnings intact\n'; pass=$((pass + 1))
else
  printf 'FAIL  109b  rejected learn-set clobbered active learnings\n'; fail=$((fail + 1))
  failures+=("109b oversized learn-set clobbered active learnings")
fi

# --- 110. learn-set with blank text errors ---
STDERR_CONTAINS="usage: cerebro learn-set" \
run_case 110 "learn-set blank errors" 1 -- "$CEREBRO_BIN" learn-set ""

# --- 111. execute: unknown arg still rejected (stacked-branch flags added) ---
STDERR_CONTAINS="unknown arg" \
run_case 111 "execute unknown arg rejected" 1 -- "$CEREBRO_BIN" execute "$REPO" --frob

# --- 112. execute: --base/--branch without a plan or --prompt still errors ---
# Confirms the new flags parse but don't bypass the plan/prompt requirement,
# and fire before any child claude is spawned.
STDERR_CONTAINS="requires <plan-path> or --prompt" \
run_case 112 "execute --base/--branch needs plan or prompt" 1 -- \
  "$CEREBRO_BIN" execute "$REPO" --base feat/step-1 --branch feat/step-2

# --- 113. review: --criteria-file missing path fails fast (before codex) ---
STDERR_CONTAINS="cannot read --criteria-file" \
run_case 113 "review --criteria-file missing path" 1 -- \
  "$CEREBRO_BIN" review "$REPO" --criteria-file "$WORKDIR/no-such-plan.md"

# --- 113b. review: --criteria-file empty file also fails fast ---
: > "$WORKDIR/empty-plan.md"
STDERR_CONTAINS="cannot read --criteria-file" \
run_case 113b "review --criteria-file empty file" 1 -- \
  "$CEREBRO_BIN" review "$REPO" --criteria-file "$WORKDIR/empty-plan.md"

# --- 114. review: unknown arg rejected ---
STDERR_CONTAINS="unknown arg" \
run_case 114 "review unknown arg rejected" 1 -- "$CEREBRO_BIN" review "$REPO" --frob

printf '\n%d passed, %d failed\n' "$pass" "$fail"
if (( fail > 0 )); then
  printf '\nFailures:\n'
  for f in "${failures[@]}"; do printf '  %s\n' "$f"; done
  exit 1
fi
exit 0
