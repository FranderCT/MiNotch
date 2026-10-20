#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -module-cache-path .build/TestModuleCache \
  Sources/MiNotch/AI/InputPredictions.swift \
  Sources/MiNotch/AI/CompletionEngine.swift \
  Tests/MiNotchTests/CompletionTests.swift \
  -o .build/completion-tests
.build/completion-tests
