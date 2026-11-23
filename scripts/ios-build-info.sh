#!/usr/bin/env bash
set -euo pipefail

source_plist="$1"
output_plist="$2"

git_version() {
  git -C "$SRCROOT" "$@" 2>/dev/null || true
}

version_tag="$(git_version describe --tags --match 'v[0-9]*' --abbrev=0)"
description="$(git_version describe --tags --match 'v[0-9]*' --always)"
commit_count="$(git_version rev-list --count HEAD)"
base_version="${SCRCTL_BASE_VERSION:-2.0.0}"
version="${MARKETING_VERSION:-$base_version}"
build="${CURRENT_PROJECT_VERSION:-1}"
label="${OPENSCREENS_BUILD_VERSION:-dev}"

if [[ "$version" == "$base_version" && -n "$version_tag" ]]; then
  version="${version_tag#v}"
  version="${version%%-*}"
fi
if [[ -n "${CI_BUILD_NUMBER:-}" && "${CI_XCODE_CLOUD:-}" == TRUE ]]; then
  build="$CI_BUILD_NUMBER"
elif [[ "$build" == 1 && -n "$commit_count" ]]; then
  build="$commit_count"
fi
if [[ "$label" == dev ]]; then
  label="${description:-$version}"
fi

cp "$source_plist" "$output_plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" \
  -c "Set :CFBundleVersion $build" \
  -c "Set :OpenScreensBuildVersion $label" "$output_plist"
