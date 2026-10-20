#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
# Requiere `swift build -c release` previo: usa el módulo SwiftTerm que deja compilado.
PRODUCTS=.build/out/Products/Release
mkdir -p .build
swiftc -module-cache-path .build/TestModuleCache -I "$PRODUCTS" \
  Sources/MiNotch/AI/ShellIntegration.swift \
  Sources/MiNotch/AI/ShellStream.swift \
  Sources/MiNotch/AI/TerminalBlocks.swift \
  Tests/MiNotchTests/BlockTests.swift \
  "$PRODUCTS/SwiftTerm.o" \
  -o .build/block-tests
.build/block-tests
