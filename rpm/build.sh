#!/usr/bin/env bash
# rpm/build.sh - Build and push a packaging release for httpd to COPR via ghbuild
#
# Usage: ./rpm/build.sh <version> [release] [--skip-validate]
#   e.g: ./rpm/build.sh 2.4.66        # builds 2.4.66-1
#        ./rpm/build.sh 2.4.66 2       # rebuilds 2.4.66 as release 2
#        ./rpm/build.sh 2.4.67         # new upstream version
#
# Before committing, this regenerates httpd.spec.rpmlocal from httpd.spec
# (rpm/gen-rpmlocal.sh) and re-applies every patch in spec order against the
# new source (rpm/test-build.sh). A patch that no longer applies - because
# upstream backported the fix, or shifted the surrounding context - fails
# the script here, before anything is committed, tagged, or pushed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
VERSION="${1:-}"
RELEASE="${2:-1}"
SKIP_VALIDATE=0
for arg in "$@"; do
    [[ "$arg" == "--skip-validate" ]] && SKIP_VALIDATE=1
done

if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <version> [release] [--skip-validate]"
    echo "  e.g.: $0 2.4.66 1"
    exit 1
fi

TAG="httpd-${VERSION}-${RELEASE}"
BRANCH="build/${VERSION}"
REMOTE_BRANCH="2.4.x"
REMOTE="ghbuild"

# ---------------------------------------------------------------------------
# Ensure we run from repo root regardless of where the script is invoked
# ---------------------------------------------------------------------------
REPO_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
cd "$REPO_ROOT"

if [[ ! -f "httpd.spec" ]]; then
    echo "Error: httpd.spec not found - is this the right repo?"
    exit 1
fi

# Warn on dirty working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Error: working tree has uncommitted changes - stash or commit first"
    exit 1
fi

# ---------------------------------------------------------------------------
# Re-release: branch already exists, just bump the Release number
# ---------------------------------------------------------------------------
if git show-ref --verify --quiet "refs/heads/${BRANCH}"; then
    echo "Branch ${BRANCH} already exists - bumping to Release ${RELEASE}"
    git checkout "${BRANCH}"

    sed -i "s/^Release: .*/Release: ${RELEASE}%{?dist}/" httpd.spec
    "${REPO_ROOT}/rpm/gen-rpmlocal.sh"

    if [[ "$SKIP_VALIDATE" -eq 1 ]]; then
        echo "Skipping patch validation (--skip-validate)"
    else
        "${REPO_ROOT}/rpm/test-build.sh" "${VERSION}"
    fi

    git add httpd.spec httpd.spec.rpmlocal
    git commit -m "Bump release to ${VERSION}-${RELEASE}"

# ---------------------------------------------------------------------------
# New version: branch from upstream tag, copy packaging layer
# ---------------------------------------------------------------------------
else
    echo "Fetching upstream tags..."
    git fetch origin --tags

    if ! git rev-parse --verify "${VERSION}" >/dev/null 2>&1; then
        echo "Error: upstream tag '${VERSION}' not found after fetch"
        exit 1
    fi

    # Find the most recent previous build/* branch to copy packaging from
    PREV_BRANCH=$(git branch --list 'build/*' | tr -d ' *' | sort -V | tail -1)
    if [[ -z "$PREV_BRANCH" ]]; then
        echo "Error: no previous build/* branch found to copy packaging from"
        exit 1
    fi
    echo "Basing packaging on ${PREV_BRANCH}"

    git checkout -b "${BRANCH}" "${VERSION}"

    # httpd.spec.rpmlocal is deliberately NOT copied here - it's regenerated
    # from httpd.spec below (rpm/gen-rpmlocal.sh), never carried forward, so
    # the two specs can no longer drift out of sync with each other.
    git checkout "${PREV_BRANCH}" -- \
        SOURCES/ \
        httpd.spec \
        htcacheclean.service.xml \
        httpd.conf.xml \
        httpd.service.xml \
        README.md \
        rpm/

    # Remove /httpd.spec from .gitignore so the spec file is tracked
    sed -i '/^\/httpd\.spec$/d' .gitignore

    sed -i "s/^Version: .*/Version: ${VERSION}/" httpd.spec
    sed -i "s/^Release: .*/Release: ${RELEASE}%{?dist}/" httpd.spec
    "${REPO_ROOT}/rpm/gen-rpmlocal.sh"

    if [[ "$SKIP_VALIDATE" -eq 1 ]]; then
        echo "Skipping patch validation (--skip-validate)"
    else
        "${REPO_ROOT}/rpm/test-build.sh" "${VERSION}"
    fi

    git add -A
    git commit -m "Packaging for httpd ${VERSION}-${RELEASE}"
fi

# ---------------------------------------------------------------------------
# Tag (annotated, required for push.followTags)
# ---------------------------------------------------------------------------
if git rev-parse --verify "${TAG}" >/dev/null 2>&1; then
    echo "Warning: tag ${TAG} already exists locally - skipping tag creation"
else
    git tag -a "${TAG}" -m "httpd ${VERSION} packaging release ${RELEASE}"
fi

# ---------------------------------------------------------------------------
# Push
# ---------------------------------------------------------------------------
echo "Pushing ${BRANCH} -> ${REMOTE}/${REMOTE_BRANCH}..."
git push "${REMOTE}" "${BRANCH}:${REMOTE_BRANCH}" --force-with-lease

echo "Pushing tag ${TAG}..."
git push "${REMOTE}" "${TAG}"

echo ""
echo "Done: httpd ${VERSION}-${RELEASE} pushed to ${REMOTE}/${REMOTE_BRANCH}"
