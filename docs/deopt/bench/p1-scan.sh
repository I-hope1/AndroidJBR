#!/usr/bin/env bash
# P1 long-tail scan: run the redefinition storm on an instrumented JBR build and
# aggregate where in-flight C2 compilations are when the drain waits.
#
#   ./p1-scan.sh [path-to-instrumented-java]
set -uo pipefail
cd "$(dirname "$0")"
JAVA=${1:-/home/ubuntu/jbr25-port/JBR25/build/linux-aarch64-server-fastdebug/images/jdk/bin/java}
LOG=logs-p1
mkdir -p "$LOG"

# Long-C2 flags: HugeMethodLimit lets the 13 KB bench.Med.m* methods reach C2;
# the aggressive thresholds make them recompile continuously, so a redefine
# usually overlaps a multi-hundred-ms C2 compile (fastdebug).
LONGC2=(-XX:HugeMethodLimit=65535 -XX:CompileThreshold=100 -XX:Tier4InvocationThreshold=100)

run() { # name dirs rounds interval workers markers
  local name=$1 dirs=$2 rounds=$3 iv=$4 wk=$5 mk=$6
  local extra=("${@:7}")
  echo "=== $name (interval=${iv}ms workers=${wk}) ==="
  timeout 600 "$JAVA" -javaagent:out/bench-agent.jar -cp out/v1:out/bench \
    -XX:+AllowEnhancedClassRedefinition "${extra[@]}" \
    -Xlog:redefine+class=info:file="$LOG/$name.log" \
    bench.Main "$dirs" "$rounds" "$iv" "$wk" "$mk" > "$LOG/$name.out" 2>&1
  echo "rc=$? $(grep 'DONE' "$LOG/$name.out" | tail -1)"
}

# body-only full-storm variant (deopt-all) with long C2 compiles in flight
run body-storm out/v1,out/v1b 20 500 8 "100,200" "${LONGC2[@]}"
run body-storm-dense out/v1,out/v1b 20 20 16 "100,200" "${LONGC2[@]}"
# structural variants (deopt-all), same storm
run schema-storm out/v2,out/v3 20 300 8 "300,400" "${LONGC2[@]}"

python3 - "$LOG" <<'PY'
import re, sys, glob, collections, os
logdir = sys.argv[1]
print()
for f in sorted(glob.glob(os.path.join(logdir, "*.log"))):
    text = open(f, errors="replace").read()
    dumps = re.findall(r"in-flight compilation: thread='([^']*)' method='([^']*)' level=(\d+) osr_bci=(-?\d+) phase='([^']*)' phase_ms=(-?\d+)", text)
    drains = [int(m) for m in re.findall(r"compilation drain finished after (\d+) ms", text)]
    print(f"--- {os.path.basename(f)}: dumps={len(dumps)} drains={len(drains)}")
    if drains:
        print(f"    drain count={len(drains)} max={max(drains)}ms p50={sorted(drains)[len(drains)//2]}ms")
    if dumps:
        by_phase = collections.Counter(d[4] for d in dumps)
        worst = collections.defaultdict(int)
        for d in dumps:
            worst[d[4]] = max(worst[d[4]], int(d[5]))
        print("    phases observed:")
        for p, n in by_phase.most_common():
            print(f"      {p:<24} n={n:<5} max_phase_ms={worst[p]}")
        worst_all = max(dumps, key=lambda d: int(d[5]))
        print(f"    worst: method='{worst_all[1]}' level={worst_all[2]} phase='{worst_all[4]}' phase_ms={worst_all[5]}")
PY
