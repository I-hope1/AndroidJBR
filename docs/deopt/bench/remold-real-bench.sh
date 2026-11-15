#!/usr/bin/env bash
# Real-Remold hot-reload benchmark (Remold example app + Remold agent).
#
#   AGENT=/path/to/remold-agent.jar ./remold-real-bench.sh <jdk> <tag> [rounds]
#
# Requires: Remold sources (REMOLD_SRC, default /tmp/Remold) and an agent jar
# from a Remold release or from Remold's CI "remold-dist" artifact. Each round
# rewrites PlayerService (new field + big hot method body), recompiles it with
# javac and lets Remold perform a two-phase enhanced redefinition. Reports
# Remold's per-batch total/patch times; for patched JBR builds also counts
# drain/cancel/ForceSafepoint events from the VM logs.
set -uo pipefail
JDK=$1; TAG=$2; ROUNDS=${3:-12}
D=${WORKDIR:-/tmp/remold-test}
REMOLD_SRC=${REMOLD_SRC:-/tmp/Remold}
AGENT=${AGENT:?set AGENT=/path/to/remold-agent.jar}
API=${API_JAR:-$D/remold-api-0.2.8.jar}
W=$D/work-$TAG
mkdir -p "$D"
rm -rf "$W" "$D/classes-$TAG" "$D/$TAG-app.log" "$D/$TAG-xlog.log" "$D/$TAG-sp.log"
mkdir -p "$W" "$D/classes-$TAG"
cp -r "$REMOLD_SRC"/example/src/main/java/example/*.java "$W"/
python3 - "$W/Main.java" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
anchor = '        int tickCount = 0;'
add = '''        // keep PlayerService.work hot so C2 compiles overlap redefines
        for (int w = 0; w < 4; w++) {
            Thread t = new Thread(() -> { long i = 0; while (true) { player.work(++i); } }, "bench-worker-" + w);
            t.setDaemon(true);
            t.start();
        }
'''
assert anchor in s
open(p, 'w').write(s.replace(anchor, add + anchor))
PY
export TAG
gen_player() { python3 "$D/gen_player.py" "$1"; }
cat > "$D/gen_player.py" <<'PY2'
import sys, os
r = int(sys.argv[1]); tag = os.environ['TAG']
stmts = []
for i in range(300):
    if i % 3 == 0:
        stmts.append("        acc = acc * 1664525 + %d + (acc >>> 13); if ((acc & 7) == 0) acc += %d; else acc -= %d;" % (i + r, r % 5, r % 3))
    else:
        stmts.append("        acc = acc * 1664525 + %d + (acc >>> 13);" % (i + r))
body = "\n".join(stmts)
src = """package example;

import remold.annotation.OnReload;
import remold.annotation.RemoldReinit;
import java.time.LocalTime;
import java.time.format.DateTimeFormatter;

public class PlayerService {
    private static final DateTimeFormatter TIME_FORMAT = DateTimeFormatter.ofPattern("HH:mm:ss");
    private final String name;
    private int score;
    private int level = 1;
    private String guild%d = "Remold Testers";
    private static volatile long sink;

    @RemoldReinit(mode = RemoldReinit.Mode.OVERWRITE)
    private String statusTitle = "Novice Adventurer";

    public PlayerService(String name) { this.name = name; this.score = 100; }

    public long work(long x) {
        long acc = x + %d;
%s
        sink = acc;
        return acc;
    }

    public void tick() {
        this.score += 10;
        System.out.printf("[%%s] [PlayerService] Name: %%s | Title: %%s | Level: %%d | Score: %%d%%n",
                LocalTime.now().format(TIME_FORMAT), name, statusTitle, level, score);
    }

    @OnReload
    private void onReload() { System.out.println(">>> [HOTSWAP] @OnReload round=%d <<<"); }
}
""" % (r, r % 7, body, r)
open('/tmp/remold-test/work-' + tag + '/PlayerService.java', 'w').write(src)
PY2
gen_player 0
"$JDK/bin/javac" -cp "$API" -d "$D/classes-$TAG" "$W"/*.java || exit 1
"$JDK/bin/java" --enable-native-access=ALL-UNNAMED \
  -XX:+AllowEnhancedClassRedefinition -javaagent:"$AGENT=$D/classes-$TAG" \
  -Dremold.agent.file_shake_ms=200 ${JAVA_OPTS:-} \
  -Xlog:redefine+class=info:file="$D/$TAG-xlog.log" \
  -Xlog:safepoint=info:file="$D/$TAG-sp.log" \
  -cp "$D/classes-$TAG" example.Main > "$D/$TAG-app.log" 2>&1 &
APP=$!
for i in $(seq 1 150); do grep -q 'Remold Example Application Started' "$D/$TAG-app.log" && break; sleep 0.2; done
sleep 3
for r in $(seq 1 "$ROUNDS"); do
  gen_player "$r"
  "$JDK/bin/javac" -cp "$API" -d "$D/classes-$TAG" "$W"/*.java >/dev/null 2>&1
  sleep 3
done
kill $APP 2>/dev/null; wait $APP 2>/dev/null
echo "run done: $TAG"
