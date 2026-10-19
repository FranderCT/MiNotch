#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
swiftc -module-cache-path .build/TestModuleCache \
  Sources/MiNotch/AI/DeepSeekBilling.swift \
  Sources/MiNotch/AI/DeepSeekClient.swift \
  Tests/MiNotchTests/DeepSeekBillingTests.swift \
  -o .build/deepseek-billing-tests
.build/deepseek-billing-tests
