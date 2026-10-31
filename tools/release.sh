#!/usr/bin/env bash
# Publish the library from `dev` to `main`.
#
#   tools/release.sh [version]     e.g. tools/release.sh 0.3.0
#
# `main` holds exactly the package: the paths below, which match `.paths` in
# build.zig.zon plus .gitignore. Everything else (tools, audits, docs) stays
# on `dev`. The script runs the unit-test gates, replaces those paths on main
# with dev's copies, commits, optionally tags v<version>, and returns to dev.
# It never pushes.
set -euo pipefail

paths=(build.zig build.zig.zon src README.md LICENSE .gitignore)

die() { echo "release: $*" >&2; exit 1; }

cd "$(git rev-parse --show-toplevel)"
[ "$(git branch --show-current)" = dev ] || die "run from the dev branch"
git diff --quiet && git diff --cached --quiet || die "commit or stash your changes first"

version=${1:-}
if [ -n "$version" ]; then
    grep -q "\.version = \"$version\"" build.zig.zon || die "build.zig.zon .version is not $version"
    git rev-parse -q --verify "refs/tags/v$version" >/dev/null && die "tag v$version already exists"
fi

zig build test
zig build test -Dserde=true

rev=$(git rev-parse --short HEAD)
git switch -q main
trap 'git switch -q dev' EXIT

git rm -rq --ignore-unmatch -- "${paths[@]}"
git checkout dev -- "${paths[@]}"

extra=$(git ls-files | grep -vE '^(build\.zig|build\.zig\.zon|README\.md|LICENSE|\.gitignore|src/.*)$' || true)
[ -z "$extra" ] || die "main tracks files outside the package: $extra"

if git diff --cached --quiet; then
    echo "release: main already matches dev@$rev"
else
    git commit -q -m "${version:+zafi $version: }release from dev@$rev"
    echo "release: committed $(git rev-parse --short HEAD) on main"
fi
if [ -n "$version" ]; then
    git tag -a "v$version" -m "zafi $version"
    echo "release: tagged v$version"
fi
