#!/usr/bin/env bash
# rpm/add-changelog.sh - Insert a new top %changelog entry into httpd.spec
#
# rpm derives SOURCE_DATE_EPOCH from the newest %changelog entry by default
# (source_date_epoch_from_changelog is on in rpm's own macro set). The top
# entry hadn't been touched since a Dec 27 2020 RHEL7 rebuild, which is why
# every build since - across a dozen versions - has stamped that same frozen
# date into `httpd -v`'s "Server built" line. Keeping this current fixes
# both the changelog and the build-date stamp with one change.
#
# rpmdev-bumpspec was tried and rejected: it can't parse httpd.spec's COPR
# SCM macros ({{{ git_name name=httpd }}} etc) and silently falls back to a
# broken partial edit (drops the "- version-release" suffix, double-bumps
# Release on top of what build.sh's own sed already does).
#
# Usage: rpm/add-changelog.sh <spec-file> <version> <release> <comment>
#   e.g.: rpm/add-changelog.sh httpd.spec 2.4.68 1 "new version 2.4.68"

set -euo pipefail

SPEC="${1:?Usage: $0 <spec-file> <version> <release> <comment>}"
VERSION="${2:?}"
RELEASE="${3:?}"
COMMENT="${4:?}"

if [[ ! -f "$SPEC" ]]; then
    echo "Error: $SPEC not found" >&2
    exit 1
fi

if ! grep -q '^%changelog$' "$SPEC"; then
    echo "Error: no %changelog section found in $SPEC" >&2
    exit 1
fi

NAME="$(git config user.name 2>/dev/null || echo 'Wesley Haines')"
EMAIL="$(git config user.email 2>/dev/null || echo 'wes@weshaines.com')"
DATE="$(LC_ALL=C date +'%a %b %e %Y')"

TMP=$(mktemp)
awk -v date="$DATE" -v name="$NAME" -v email="$EMAIL" \
    -v version="$VERSION" -v release="$RELEASE" -v comment="$COMMENT" '
    /^%changelog$/ && !done {
        print
        print "* " date " " name " <" email "> - " version "-" release
        print "- " comment
        print ""
        done = 1
        next
    }
    { print }
' "$SPEC" > "$TMP"
mv "$TMP" "$SPEC"

echo "Added changelog entry: ${VERSION}-${RELEASE} (${DATE})"
