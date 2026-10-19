#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -module-cache-path .build/TestModuleCache \
  Sources/MiNotch/AI/InputPredictions.swift \
  Tests/MiNotchTests/InputPredictionsTests.swift \
  -o .build/input-prediction-tests
.build/input-prediction-tests
