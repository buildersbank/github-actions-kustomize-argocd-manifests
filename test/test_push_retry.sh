#!/usr/bin/env bash
# Unit tests for git_push_with_retry / commit_and_push in ../entrypoint.sh.
# Pure bash + git against local bare repos; touches NO remote / prod.
# Run:  bash test/test_push_retry.sh   (expected tail: "ALL TESTS PASSED")
set -u

HERE="$(cd "$(dirname "$0")/.." && pwd)"
export ENTRYPOINT_TEST_SOURCE=1
# shellcheck disable=SC1091
source "$HERE/entrypoint.sh"
set +e   # tests deliberately trigger push failures; we manage exit codes

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass(){ printf '  [PASS] %s\n' "$1"; }
fail(){ printf '  [FAIL] %s\n' "$1"; exit 1; }

setup_remote(){ # $1=bare path
  git init --bare -b main "$1" >/dev/null 2>&1
  rm -rf "$TMP/seed"; git clone "$1" "$TMP/seed" >/dev/null 2>&1
  ( cd "$TMP/seed" && git config user.email t@t && git config user.name t \
    && echo init > README && git add . && git commit -m init >/dev/null 2>&1 \
    && git push origin main >/dev/null 2>&1 )
}
mkclone(){ # $1=bare $2=dir
  git clone "$1" "$2" >/dev/null 2>&1
  ( cd "$2" && git config user.email t@t && git config user.name t )
}

echo "=== TEST 1: race, disjoint files -> rebase+push returns 0 ==="
B="$TMP/r1.git"; setup_remote "$B"; mkclone "$B" "$TMP/a"; mkclone "$B" "$TMP/b"
( cd "$TMP/a" && mkdir -p k8s/a && echo "tag: v1" > k8s/a/kustomization.yaml && git add . && git commit -m a >/dev/null 2>&1 )
( cd "$TMP/b" && mkdir -p k8s/b && echo "tag: v2" > k8s/b/kustomization.yaml && git add . && git commit -m b >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 )
( cd "$TMP/a"; git_push_with_retry main >/dev/null 2>&1 ) && pass "T1 returns 0" || fail "T1 should return 0"

echo "=== TEST 2: race, SAME file conflict -> -X theirs auto-resolves, returns 0 (no livelock) ==="
B="$TMP/r2.git"; setup_remote "$B"; mkclone "$B" "$TMP/c"; mkclone "$B" "$TMP/d"
( cd "$TMP/c" && mkdir -p k8s/s && echo "newTag: vA" > k8s/s/kustomization.yaml && git add . && git commit -m c >/dev/null 2>&1 )
( cd "$TMP/d" && mkdir -p k8s/s && echo "newTag: vB" > k8s/s/kustomization.yaml && git add . && git commit -m d >/dev/null 2>&1 && git push origin main >/dev/null 2>&1 )
( cd "$TMP/c"; git_push_with_retry main >/dev/null 2>&1 ) && pass "T2 returns 0" || fail "T2 should return 0 (conflict must auto-resolve)"

echo "=== TEST 3: unreachable remote, GIT_PUSH_MAX_ATTEMPTS=2 -> returns 1, shell survives ==="
B="$TMP/r3.git"; setup_remote "$B"; mkclone "$B" "$TMP/e"
( cd "$TMP/e" && echo x > f && git add . && git commit -m e >/dev/null 2>&1 && git remote set-url origin /nonexistent/x.git )
( cd "$TMP/e"; GIT_PUSH_MAX_ATTEMPTS=2 git_push_with_retry main >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 1 ] && pass "T3 returns 1" || fail "T3 expected 1 got $rc"
pass "T3 shell still alive (set -e did not abort)"

echo "=== TEST 4: commit_and_push no-change -> 0 (idempotent rerun) ==="
B="$TMP/r4.git"; setup_remote "$B"; mkclone "$B" "$TMP/g"
( cd "$TMP/g" && git pull origin main >/dev/null 2>&1; commit_and_push main "noop" >/dev/null 2>&1 ) && pass "T4 returns 0" || fail "T4 should return 0"

echo "=== TEST 5: a failed push RETURNS (does not exit) the caller ==="
B="$TMP/r5.git"; setup_remote "$B"; mkclone "$B" "$TMP/h"
( cd "$TMP/h" && echo x > f && git add . && git commit -m h >/dev/null 2>&1 && git remote set-url origin /nonexistent/x.git )
# Call in THIS script's own process (no subshell wrapping the call): if
# git_push_with_retry used 'exit 1', the script would terminate here and never
# print the sentinel or "ALL TESTS PASSED". 'return 1' lets execution continue.
_prev="$PWD"; cd "$TMP/h" || exit 1
GIT_PUSH_MAX_ATTEMPTS=1 git_push_with_retry main >/dev/null 2>&1; t5_rc=$?
cd "$_prev" || exit 1
echo "  [sentinel] reached line after git_push_with_retry (proves return, not exit)"
[ "$t5_rc" -eq 1 ] && pass "T5 returned 1 (caller survived)" || fail "T5 expected rc 1 got $t5_rc"

echo ""
echo "ALL TESTS PASSED"
