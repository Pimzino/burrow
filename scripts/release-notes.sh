#!/bin/bash
# Writes the "Commits" section of a GitHub Release body as Markdown to stdout: every commit in
# <previous v* tag>..<tag>, newest first, each with its short SHA linked to the commit on GitHub.
# For the first release (no earlier v* tag) it lists every commit reachable from the tag.
#
#   scripts/release-notes.sh <tag> [repo]
#
# repo           owner/name used for the commit links; defaults to $GITHUB_REPOSITORY, then to the
#                origin remote.
# Needs the full history and tags (actions/checkout with fetch-depth: 0).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release-notes.sh <tag> [repo]}"
REPO="${2:-${GITHUB_REPOSITORY:-}}"
if [[ -z "$REPO" ]]; then
  REPO="$(git remote get-url origin | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
fi

git rev-parse --verify --quiet "$TAG^{commit}" >/dev/null || { echo "Unknown tag: $TAG" >&2; exit 1; }

PREV="$(git describe --tags --abbrev=0 --match 'v*' "$TAG^" 2>/dev/null || true)"
if [[ -n "$PREV" ]]; then
  RANGE="$PREV..$TAG"
  SINCE=" since [$PREV](https://github.com/$REPO/releases/tag/$PREV)"
else
  RANGE="$TAG"
  SINCE=""
fi

COUNT="$(git rev-list --no-merges --count "$RANGE")"
echo "## Commits"
echo
echo "$COUNT commit$([[ "$COUNT" == 1 ]] || echo s)$SINCE:"
echo
git log --no-merges --format="- [\`%h\`](https://github.com/$REPO/commit/%H) %s (%an)" "$RANGE"
