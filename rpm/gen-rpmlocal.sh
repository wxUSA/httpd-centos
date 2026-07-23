#!/usr/bin/env bash
# rpm/gen-rpmlocal.sh - Regenerate httpd.spec.rpmlocal from httpd.spec
#
# httpd.spec uses rpkg/COPR SCM macros ({{{ git_dir_pack }}}, etc.) that only
# expand server-side during a COPR webhook build. httpd.spec.rpmlocal is the
# de-macroed stand-in used for local rpmbuild -bp/-bc testing.
#
# These two files must never be hand-maintained independently - that's how
# rpmlocal's Patch/%prep block silently drifted out of sync with the real
# spec. This script derives rpmlocal from spec mechanically every time, so
# the only thing that can differ between them is the handful of substitutions
# below.
#
# Dead "#Patch/#%patch" lines (commented out, but RPM's macro expander isn't
# comment-aware and still expands them, e.g. "error: No patch number 26") are
# stripped from rpmlocal only. They build fine on COPR's rpm - only local
# rpmbuild here chokes on them - so httpd.spec itself is left untouched.
#
# Usage: rpm/gen-rpmlocal.sh [spec] [rpmlocal-out]

set -euo pipefail

SPEC="${1:-httpd.spec}"
OUT="${2:-httpd.spec.rpmlocal}"

if [[ ! -f "$SPEC" ]]; then
    echo "Error: $SPEC not found" >&2
    exit 1
fi

sed \
    -e 's/^%define vstring %(source \/etc\/os-release; echo \${NAME})$/%define vstring %(source \/etc\/os-release; echo \${REDHAT_SUPPORT_PRODUCT})/' \
    -e 's/^Name: {{{ git_name name=httpd }}}$/Name: httpd/' \
    -e '/^VCS: {{{ git_dir_vcs }}}$/d' \
    -e 's|^Source0: {{{ git_dir_pack }}}$|Source0: https://github.com/wxUSA/%{gitrepo}/archive/%{gitbranch}.tar.gz#/%{name}-%{version}.tar.gz|' \
    -e 's/^{{{ git_dir_setup_macro }}}$/%setup -q/' \
    -e '/^#Patch[0-9]\+:/d' \
    -e '/^#%patch\b/d' \
    "$SPEC" > "$OUT"

# Sanity check: no unexpanded rpkg/COPR macros should remain
if grep -q '{{{' "$OUT"; then
    echo "Error: $OUT still contains unexpanded {{{ ... }}} macros:" >&2
    grep -n '{{{' "$OUT" >&2
    exit 1
fi

echo "Generated $OUT from $SPEC"
