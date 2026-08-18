#!/usr/bin/env bash
#
# Bump version, regenerate lockfile, commit, and tag.
#
# Usage:
#   scripts/release.sh 1.8.1 --push   # stable release from main
#   scripts/release.sh 1.9.0a1 --push # pre-release from dev
#   scripts/release.sh 1.8.2 --push   # prior-line patch from stable/1.8
#
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh VERSION [--push]}"
PUSH="${2:-}"

# Validate PEP 440 version
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(a[0-9]+|b[0-9]+|rc[0-9]+)?$'; then
    echo "error: invalid PEP 440 version: $VERSION" >&2
    echo "  examples: 1.0.0, 1.1.0a1, 1.0.1rc2" >&2
    exit 1
fi

TAG="v${VERSION}"

# Enforce the release topology before changing any files. main is the current
# stable line, dev is the next-release line, and stable/X.Y is a maintained
# prior line whose branch name must match the version being released.
BRANCH=$(git symbolic-ref --quiet --short HEAD || true)
if [ -z "$BRANCH" ]; then
    echo "error: releases must be cut from a branch, not detached HEAD" >&2
    exit 1
fi

if echo "$VERSION" | grep -qE '(a|b|rc)[0-9]+$'; then
    if [ "$BRANCH" != "dev" ]; then
        echo "error: pre-releases must be cut from dev (current branch: $BRANCH)" >&2
        exit 1
    fi
else
    case "$BRANCH" in
        main)
            ;;
        stable/*)
            RELEASE_LINE="${VERSION%.*}"
            if [ "$BRANCH" != "stable/$RELEASE_LINE" ]; then
                echo "error: $VERSION belongs on stable/$RELEASE_LINE, not $BRANCH" >&2
                exit 1
            fi
            ;;
        dev)
            echo "error: stable releases must be cut from main or matching stable/X.Y" >&2
            exit 1
            ;;
        *)
            echo "error: releases must be cut from main, dev, or stable/X.Y" >&2
            echo "  current branch: $BRANCH" >&2
            exit 1
            ;;
    esac
fi

# Check for clean working tree
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "error: working tree is dirty — commit or stash first" >&2
    exit 1
fi

# Check tag doesn't already exist
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "error: tag $TAG already exists" >&2
    exit 1
fi

# Detect current version
CURRENT=$(grep -oP '(?<=^version = ")[^"]+' pyproject.toml)
echo "Bumping $CURRENT → $VERSION"

# Update version in both files
sed -i "s/^version = \".*\"/version = \"$VERSION\"/" pyproject.toml
sed -i "s/^__version__ = \".*\"/__version__ = \"$VERSION\"/" turnstone/__init__.py

# Regenerate lockfile
echo "Regenerating uv.lock..."
uv lock

# Commit and tag
git add pyproject.toml turnstone/__init__.py uv.lock
git commit -m "chore: bump version to $VERSION"
git tag "$TAG"

echo ""
echo "Created commit and tag $TAG"

if [ "$PUSH" = "--push" ]; then
    echo "Pushing $BRANCH + $TAG to origin..."
    git push --atomic origin "$BRANCH" "$TAG"
else
    echo "Run 'git push --atomic origin $BRANCH $TAG' to publish"
fi
