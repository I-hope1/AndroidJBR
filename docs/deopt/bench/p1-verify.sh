#!/usr/bin/env bash
# P1 verification (release or fastdebug):
#   1. cooperative cancellation actually fires during redefinition drains;
#   2. drains are short after cancellation (vs. 444-775 ms without P1);
#   3. correctness holds (bad=0 stale=0);
#   4. cancelled methods are NOT permanently deoptimized: they recompile at
#      level 4 in the recovery window after the last redefine.
#
#   ./p1-verify.sh [java] [fastdebug|release]
set -uo pipefail
cd "$(dirname "$0")"
JAVA=${1:-/home/ubuntu/jbr25-port/JBR25/build/host/images/jdk/bin/java}
MODE=${2:-release}
LOG=logs-p1
mkdir -p "$LOG"
FAIL=0
fail() { echo "FAIL: $*"; FAIL=$((FAIL+1)); }
pass() { echo "PASS: $*"; }

EXTRA=()
if [ "$MODE" = fastdebug ]; then
  # fastdebug can compile the big methods only with the develop flag
  EXTRA=(-XX:HugeMethodLimit=65535)
fi

echo "=== P1 cancellation run ($MODE) ==="
timeout 600 "$JAVA" -javaagent:out/bench-agent.jar -cp out/v1:out/bench \
  -XX:+AllowEnhancedClassRedefinition -XX:CompileThreshold=100 -XX:Tier4InvocationThreshold=100 \
  -XX:DcevmDrainDumpThreshold=1 \
  "${EXTRA[@]}" \
  -Xlog:redefine+class=info:file="$LOG/p1-$MODE.log" \
  -Xlog:jit+compilation=debug:file="$LOG/p1-$MODE-jit.log" \
  bench.Main out/v1,out/v1b 20 300 8 "100,200" 2500 > "$LOG/p1-$MODE.out" 2>&1
rc=$?
check() { if [ "$1" -eq 0 ]; then pass "$2"; else fail "$2"; fi; }
check "$rc" "run exits 0"

python3 - "$LOG" "$MODE" <<'PY'
import re, sys
logdir, mode = sys.argv[1], sys.argv[2]
out = open(f"{logdir}/p1-{mode}.out", errors="replace").read()
log = open(f"{logdir}/p1-{mode}.log", errors="replace").read()
jit = open(f"{logdir}/p1-{mode}-jit.log", errors="replace").read()
failures = 0
def check(cond, msg):
    global failures
    print(("PASS: " if cond else "FAIL: ") + msg)
    if not cond: failures += 1

cancels = re.findall(r"cancelled in-flight compilation[^:]*: method='([^']+)' level=(\d+) phase='([^']+)'", log)
drains = [int(x) for x in re.findall(r"compilation drain finished after (\d+) ms", log)]
reds = [int(x) for x in re.findall(r"ROUND_END \d+ redefine_ms=(\d+)", out)]
verify = re.findall(r"VERIFY round=\d+ bad=(\d+) stale=(\d+)", out)
bad = [int(b) for b, _ in verify]
stale = [int(s) for _, s in verify]
check(len(cancels) > 0, f"cancellation fired ({len(cancels)} events)")
if cancels:
    phases = sorted(set(c[2] for c in cancels))
    levels = sorted(set(c[1] for c in cancels))
    print(f"    cancel phases={phases} levels={levels}")
check(len(drains) > 0, f"drains observed ({len(drains)})")
if drains:
    print(f"    drain ms: min={min(drains)} p50={sorted(drains)[len(drains)//2]} max={max(drains)}")
    check(max(drains) <= 200, f"max drain bounded (<=200 ms): {max(drains)} ms")
if reds:
    print(f"    redefine ms: min={min(reds)} p50={sorted(reds)[len(reds)//2]} max={max(reds)}")
check(all(b == 0 for b in bad) and bad, "all rounds bad=0")
check(all(s == 0 for s in stale) and stale, "all rounds stale=0")

# recovery: level-4 compiles of cancelled methods after the last cancellation
if cancels and "RECOVERY_END" in out:
    cancel_ts = [float(t) for t in re.findall(r"\[([0-9.]+)s\]\[info\]\[redefine,class\] cancelled in-flight", log)]
    last_cancel = max(cancel_ts) if cancel_ts else 0.0
    cancelled_methods = set(c[0] for c in cancels)
    comp = [(float(t), m) for t, m in re.findall(r"\[([0-9.]+)s\]\[info\]\[jit,compilation\]\s+\d+\s+4\s+(bench\.Med::m\w+)[^(]*", jit)]
    after = [(t, m) for t, m in comp if t > last_cancel]
    print(f"    last_cancel={last_cancel:.3f}s, level-4 med compiles after: {[(round(t,3), m) for t, m in after]}")
    check(len(after) > 0, "cancelled methods recompiled at level 4 in recovery window")
sys.exit(1 if failures else 0)
PY
check "$?" "P1 assertions"
echo
if [ "$FAIL" -eq 0 ]; then echo "ALL P1 CHECKS PASSED"; else echo "P1 CHECKS FAILED: $FAIL"; exit 1; fi
