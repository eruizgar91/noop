#!/usr/bin/env bash
#
# update-homebrew-cask.sh <version>  —  refresh the Homebrew cask after a macOS release.
#
# Run this as the last step of cutting a macOS release (after the release zip is built and
# uploaded). It computes the zip's SHA256, regenerates Casks/noop.rb in NoopApp/homebrew-noop,
# and pushes it — so `brew upgrade --cask noop` picks up the new version. Users install/update with:
#     brew tap noopapp/noop && brew trust noopapp/noop && brew install --cask noop
#     brew upgrade --cask noop
# (brew trust is a one-time per-machine step required since Homebrew 6.0.0 for non-official taps.)
#
# Anonymity-safe: commits as NoopApp; the token (NoopApp PAT at ~/.config/noop/gh_token) is read
# from the file and supplied through a transient git credential helper, so it is NEVER placed on a
# command line, in a remote URL, or in any output. The PAT must have Contents:write on homebrew-noop.
#
# Usage:  Tools/update-homebrew-cask.sh 1.94   [optional: path to the zip]
set -euo pipefail

VER="${1:?usage: $0 <version e.g. 1.94> [zip path]}"
ZIP="${2:-$HOME/Downloads/NOOP-v${VER}-macos.zip}"
TOKEN_FILE="$HOME/.config/noop/gh_token"

[ -f "$ZIP" ]        || { echo "missing release zip: $ZIP — build the macOS release first" >&2; exit 1; }
[ -f "$TOKEN_FILE" ] || { echo "missing token: $TOKEN_FILE" >&2; exit 1; }

export TOKEN; TOKEN="$(cat "$TOKEN_FILE")"
SHA="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# Clean (token-free) URL for clone + push; auth comes from the credential helper below.
git clone --quiet "https://github.com/NoopApp/homebrew-noop.git" "$TMP/tap"

mkdir -p "$TMP/tap/Casks"
cat > "$TMP/tap/Casks/noop.rb" <<EOF
cask "noop" do
  version "${VER}"
  sha256 "${SHA}"

  url "https://github.com/NoopApp/noop/releases/download/v#{version}/NOOP-v#{version}-macos.zip"
  name "NOOP"
  desc "Standalone, fully offline companion app for WHOOP straps"
  homepage "https://github.com/NoopApp/noop"

  app "NOOP.app"

  caveats "NOOP ships anonymously and is unsigned (no Apple Developer ID), so on first launch macOS Gatekeeper will block it: right-click NOOP in /Applications and choose Open, then Open again. Update later with: brew upgrade --cask noop."
end
EOF

cd "$TMP/tap"
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com add Casks/noop.rb
if git diff --cached --quiet; then
  echo "Homebrew cask already current for ${VER} — nothing to push."
  exit 0
fi
git -c user.name=NoopApp -c user.email=thenoopapp@gmail.com commit --quiet -m "noop ${VER}"
# The '!f' helper supplies the PAT (inherited via the exported $TOKEN) with a clean remote URL,
# so neither the command line nor git's "To <url>" output ever contains the token.
git -c credential.helper='!f() { echo username=NoopApp; echo "password=$TOKEN"; }; f' \
    push --quiet origin HEAD:main
echo "✓ Homebrew cask updated to ${VER} (sha256 ${SHA:0:12}…)"
