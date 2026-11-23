#!/bin/bash
set -euo pipefail

cd "${CI_PRIMARY_REPOSITORY_PATH:?}"
git submodule update --init -- vendor/scrctl

export PATH="$HOME/.cargo/bin:$PATH"
if ! command -v rustup >/dev/null 2>&1; then
  brew install rustup
  export PATH="$(brew --prefix rustup)/bin:$PATH"
fi
if ! rustup show active-toolchain >/dev/null 2>&1; then
  rustup default stable
fi
exec ./scripts/build-apple-core.sh
