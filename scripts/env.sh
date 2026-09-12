# Shared build environment.
#
# Homebrew's `rust` formula (1.86) shadows rustup in PATH and is too old for
# uniffi 0.32, so put rustup's shims first. There is no Xcode on this machine —
# only Command Line Tools — so everything here uses SwiftPM and hand-assembled
# .app bundles, never xcodebuild.
export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
