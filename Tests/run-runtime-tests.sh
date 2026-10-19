#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build
swiftc -module-cache-path .build/TestModuleCache \
  Sources/MiNotch/AI/ShellIntegration.swift \
  Sources/MiNotch/AI/AgentEvents.swift \
  Sources/MiNotch/AI/ExternalAgents.swift \
  Sources/MiNotch/AI/ProcessOutput.swift \
  Sources/MiNotch/LocalDiagnostics.swift \
  Sources/MiNotch/ProjectLink.swift \
  Tests/MiNotchTests/RuntimeTests.swift \
  -o .build/runtime-tests
.build/runtime-tests
