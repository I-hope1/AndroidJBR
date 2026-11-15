import sys, os
r = int(sys.argv[1]); tag = os.environ['TAG']
fields = "".join('    private String guild%d = "Remold Testers";\n' % i for i in range(r + 1))
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
%s    private static volatile long sink;

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
    private void onReload() { sink += 1; }
}
""" % (fields, r % 7, body)
open('/tmp/remold-test/work-' + tag + '/PlayerService.java', 'w').write(src)
