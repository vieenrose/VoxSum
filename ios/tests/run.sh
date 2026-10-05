#!/bin/bash
# Reader parity on a macOS host (Swift toolchain only): ios/tests/run.sh
set -e
D=$(cd "$(dirname "$0")" && pwd); O=${TMPDIR:-/tmp}/vox-reader-tests; mkdir -p $O
swiftc -parse-as-library -O $D/../App/Reader/*.swift $D/ReaderParityTests.swift -o $O/reader-tests
$O/reader-tests $D/golden
