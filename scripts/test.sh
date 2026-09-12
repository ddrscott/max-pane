#!/usr/bin/env bash
# Run everything: laned-core's Rust tests and the Swift app's.
#
# The Swift half needs the framework dance below because there is no Xcode here.
# swift-testing ships inside Command Line Tools, but SwiftPM does not look for it
# there — it needs the framework search path at compile time and two rpaths at
# run time (Testing.framework, and lib_TestingInterop.dylib which lives
# somewhere else entirely). Without them `swift test` fails at dlopen with a
# message that names neither.
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "$REPO_ROOT"

CLT_FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
CLT_LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib

echo "==> laned-core"
cargo test --workspace

echo
echo "==> MaxPane"
(cd swift/MaxPane && swift test \
  -Xswiftc -F -Xswiftc "$CLT_FW" \
  -Xlinker -F -Xlinker "$CLT_FW" \
  -Xlinker -rpath -Xlinker "$CLT_FW" \
  -Xlinker -rpath -Xlinker "$CLT_LIB")
