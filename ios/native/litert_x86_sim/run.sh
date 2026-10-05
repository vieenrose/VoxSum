#!/bin/bash
# Builds libLiteRt for the iOS x86_64 simulator (LiteRT v2.1.6, Bazel). Detached: survives the SSH/Claude session.
#   status: ~/work/litert-build/STATUS    log: ~/work/litert-build/build.log    result: ~/work/litert-build/out-lib/libLiteRt.so
cd ~/work/litert-build/LiteRT || exit 1
D=~/work/litert-build; export PATH=$HOME/tools:$PATH
echo "running since $(date)" > $D/STATUS
( while sleep 60; do
    free=$(df -k ~ | awk "NR==2{print int(\$4/1024)}")
    if [ "$free" -lt 2500 ]; then echo "aborted: disk free ${free} MB < 2500 ($(date))" > $D/STATUS; bazelisk --output_base=$D/out shutdown; pkill -f bazel; exit; fi
  done ) &
WD=$!
caffeinate -i bazelisk --output_base=$D/out build -c opt --config=ios_x86_64 --jobs=3 --local_ram_resources=4500 \
  --disk_cache=$D/cache --verbose_failures //litert/c:litert_runtime_c_api_so > $D/build.log 2>&1
rc=$?
kill $WD 2>/dev/null
if [ $rc -eq 0 ]; then
  mkdir -p $D/out-lib && cp -L bazel-bin/litert/c/libLiteRt.so $D/out-lib/ && echo "done $(date)" > $D/STATUS
else echo "failed rc=$rc $(date) — see build.log" > $D/STATUS; fi
