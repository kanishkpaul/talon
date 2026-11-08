#!/bin/bash
# Build all phase-0 spikes.
set -euo pipefail
cd "$(dirname "$0")"
swiftc -O 1-sampler/sampler.swift -o 1-sampler/sampler
clang -O2 -Wall -o 2-memcap/memcap 2-memcap/memcap.c
clang -fobjc-arc -O2 -framework Foundation -framework IOKit -lIOReport -o 3-thermal/thermal 3-thermal/thermal.m
clang -fobjc-arc -O2 -framework Foundation -framework IOKit -o 4-health/health 4-health/health.m
swiftc -O -parse-as-library 5-helper/Shared.swift 5-helper/Daemon.swift -o 5-helper/talond
swiftc -O -parse-as-library 5-helper/Shared.swift 5-helper/Client.swift -o 5-helper/helper-client
echo "built ✓"
