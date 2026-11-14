#!/usr/bin/env bash
# Install the Jac version jac.toml pins (`[project] jac-version = "==X.Y.Z"`) as
# $JAC_INSTALL_DIR/jac (default ~/.local/bin/jac), after checking the release's
# SHA-256. Does nothing when that version is already there. CI runs this too, so
# moving the pin in jac.toml moves every machine that runs it.
#
#   scripts/install_jac.sh
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's/^jac-version = "==\([0-9][0-9.]*\)"$/\1/p' "$REPO/jac.toml")"
if [ -z "$version" ]; then
    echo "install_jac.sh: jac.toml has no exact jac-version pin (jac-version = \"==X.Y.Z\")" >&2
    exit 1
fi
dir="${JAC_INSTALL_DIR:-$HOME/.local/bin}"

if [ -x "$dir/jac" ] && "$dir/jac" --version 2>/dev/null | grep -q "^jac $version "; then
    echo "jac $version is already installed at $dir/jac"
    exit 0
fi

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) platform=linux-x86_64 ;;
    Linux-aarch64 | Linux-arm64) platform=linux-aarch64 ;;
    Darwin-arm64) platform=macos-aarch64 ;;
    *)
        echo "install_jac.sh: Jac publishes no binary for $(uname -s) $(uname -m)" >&2
        exit 1
        ;;
esac

asset="jac-$version-$platform"
url="https://github.com/jaseci-labs/jaseci/releases/download/v$version/$asset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
curl -fsSL -o "$tmp/$asset" "$url"
curl -fsSL -o "$tmp/$asset.sha256" "$url.sha256"
if command -v sha256sum >/dev/null; then
    (cd "$tmp" && sha256sum -c "$asset.sha256")
else
    (cd "$tmp" && shasum -a 256 -c "$asset.sha256")
fi
mkdir -p "$dir"
install -m 755 "$tmp/$asset" "$dir/jac"
"$dir/jac" --version
