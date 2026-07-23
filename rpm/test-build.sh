#!/usr/bin/env bash
# rpm/test-build.sh - Validate that all patches in httpd.spec.rpmlocal still
# apply cleanly against the currently checked-out source tree.
#
# This is the check build.sh was missing: cherry-picking packaging forward
# from the previous build/* branch says nothing about whether those patches
# still apply to the new upstream version. New releases routinely backport
# fixes we already carry as local patches (patch becomes redundant) or shift
# context around fixes we still need (patch needs a rebase).
#
# Patches are re-applied one at a time, in spec order, on top of each other -
# same as rpm's own %prep - because later patches in this series (the
# systemd-integration group especially) depend on earlier ones having already
# touched the same files. Testing each patch in isolation against pristine
# source gives false conflicts for exactly that reason.
#
# Usage: rpm/test-build.sh [version]
#   Run from a build/<version> branch, after rpm/gen-rpmlocal.sh has been run.

set -euo pipefail

REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

VERSION="${1:-$(git rev-parse --abbrev-ref HEAD | sed 's|^build/||')}"
SPEC="httpd.spec.rpmlocal"

if [[ ! -f "$SPEC" ]]; then
    echo "Error: $SPEC not found - run rpm/gen-rpmlocal.sh first" >&2
    exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

TOPDIR="$WORK/rpmbuild"
mkdir -p "$TOPDIR"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}

echo "==> Building source tarball from current worktree (HEAD)..."
# build.sh runs this BEFORE committing, so staged-but-uncommitted packaging
# imports (a fresh version's SOURCES/, the version/release bump, the
# regenerated rpmlocal spec) exist in the working tree and index but not in
# HEAD yet. `git archive HEAD` would silently build a stale tarball missing
# all of that. `git stash create` snapshots the current index+worktree state
# of tracked files into a commit-ish without touching the working tree or
# stash list, which is what we actually want to archive.
SNAPSHOT=$(git stash create)
SNAPSHOT="${SNAPSHOT:-HEAD}"    # nothing to stash means worktree == HEAD already
git archive --format=tar.gz --prefix="httpd-${VERSION}/" -o "$TOPDIR/SOURCES/httpd-${VERSION}.tar.gz" "$SNAPSHOT"

echo "==> Staging local patches..."
cp SOURCES/*.patch "$TOPDIR/SOURCES/" 2>/dev/null || true

echo "==> Running rpmbuild -bp (prep only: unpack + apply patches)..."
set +e
BUILD_LOG="$WORK/build.log"
rpmbuild --define "_topdir $TOPDIR" --nodeps -bp "$SPEC" >"$BUILD_LOG" 2>&1
STATUS=$?
set -e

# rpmbuild -bp exercises more of %prep than just patch application (sed
# rewrites, xmlto man-page generation, etc). A nonzero exit doesn't
# necessarily mean a patch failed - so the sequential re-simulation below is
# the actual source of truth, not $STATUS.
echo ""
echo "==> Independently re-applying patches in spec order to verify..."
echo ""

ACTIVE_PATCHES=$(grep -oP '^Patch[0-9]+:\s*\K.*' "$SPEC" | xargs -n1 basename)

TREE="$WORK/sequential"
tar -xzf "$TOPDIR/SOURCES/httpd-${VERSION}.tar.gz" -C "$WORK"
mv "$WORK/httpd-${VERSION}" "$TREE"

FAILED=0
for name in $ACTIVE_PATCHES; do
    patchfile="SOURCES/$name"
    if [[ ! -f "$patchfile" ]]; then
        echo "  MISSING     $name - referenced by $SPEC but not present in SOURCES/"
        FAILED=1
        break
    fi

    # Snapshot state immediately before this patch, so a failure can be
    # diagnosed (forward vs reverse) against the correct point in the
    # sequence, not pristine upstream source.
    PRE="$WORK/pre-$name"
    cp -r "$TREE" "$PRE"

    if patch -p1 -f --no-backup-if-mismatch --fuzz=0 -d "$TREE" < "$patchfile" >/dev/null 2>&1; then
        rm -rf "$PRE"
        continue
    fi

    FAILED=1
    echo "  FAILS to apply here (after all prior patches in sequence): $name"
    if patch -p1 -R --dry-run -d "$PRE" < "$patchfile" >/dev/null 2>&1; then
        echo "  REDUNDANT?  forward apply fails, but reverse apply succeeds against the"
        echo "              tree state right before this patch - its change already"
        echo "              appears to be present in ${VERSION}. Consider dropping it."
    else
        echo "  CONFLICT    neither forward nor reverse apply cleanly here - context has"
        echo "              drifted. Needs a rebase against ${VERSION} source."
    fi
    echo ""
    rm -rf "$PRE"
    break   # rpm's own %prep also stops at the first failing %patch
done

# Bonus signal: patch files sitting in SOURCES/ that nothing in the spec
# references anymore - dead weight, harmless, but worth a periodic sweep.
ORPHANS=$(comm -23 <(ls SOURCES/*.patch | xargs -n1 basename | sort) <(echo "$ACTIVE_PATCHES" | sort))
if [[ -n "$ORPHANS" ]]; then
    echo "Note: patches in SOURCES/ not referenced by any active Patch tag (informational only):"
    echo "$ORPHANS" | sed 's/^/  - /'
    echo ""
fi

if [[ $FAILED -eq 1 ]]; then
    exit 1
fi

echo "All active patches apply cleanly, in sequence, against ${VERSION}."

if [[ $STATUS -ne 0 ]]; then
    echo ""
    echo "Note: rpmbuild -bp still exited nonzero ($STATUS) for a NON-patch reason"
    echo "(missing build tool, sed/setup step, etc). Raw tail:"
    echo ""
    tail -30 "$BUILD_LOG"
    exit 1
fi

exit 0
