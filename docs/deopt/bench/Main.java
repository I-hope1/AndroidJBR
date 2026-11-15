package bench;

import java.lang.instrument.ClassDefinition;
import java.lang.reflect.Field;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

/**
 * Synthetic DCEVM redefinition benchmark.
 *   java -javaagent:agent.jar -cp ... bench.Main <dirA> <dirB> <rounds> <intervalMs> [mode]
 * Alternates Target.class bytes from dirA/dirB ("<dir>" contains bench/Target.class).
 */
public final class Main {
    static final int NINST = 200;
    static volatile boolean stop = false;

    static void setInt(Object o, String f, int v) throws Exception {
        Field fd = o.getClass().getField(f); fd.setInt(o, v);
    }
    static int getInt(Object o, String f) throws Exception {
        return o.getClass().getField(f).getInt(o);
    }

    public static void main(String[] args) throws Exception {
        Path[] dirs = java.util.Arrays.stream(args[0].split(",")).map(Paths::get).toArray(Path[]::new);
        String[] markerArg = args.length > 4 ? args[4].split(",") : new String[0];
        int rounds = Integer.parseInt(args[1]);
        long intervalMs = Long.parseLong(args[2]);
        int workers = args.length > 3 ? Integer.parseInt(args[3]) : 8;
        // Optional 6th arg: keep the workers running after the last redefine for
        // this many ms, so that methods cancelled by P1 can be observed being
        // re-enqueued and recompiled (recovery check).
        int recoveryMs = args.length > 5 ? Integer.parseInt(args[5]) : 0;

        Class<?> tc = Class.forName("bench.Target");
        Object[] insts = new Object[NINST];
        for (int i = 0; i < NINST; i++) {
            insts[i] = tc.getDeclaredConstructor().newInstance();
            setInt(insts[i], "a", 1000 + i);
        }

        Thread[] ts = new Thread[workers];
        for (int w = 0; w < workers; w++) {
            final int wi = w;
            ts[w] = new Thread(() -> {
                Target t = (Target) insts[wi % NINST]; // direct typed access
                int i = wi;
                while (!stop) {
                    i++;
                    int acc = t.work(i) + t.m0(i) + t.m1(i) + t.m2(i) + t.m3(i)
                            + t.m4(i) + t.m5(i) + t.m6(i) + t.m7(i);
                    if ((i & 7) == 0) {
                        acc += Heavy.h0(i) + Heavy.h1(i) + Heavy.h2(i) + Heavy.h3(i);
                        acc += Med.m0(i) + Med.m1(i) + Med.m2(i) + Med.m3(i);
                    }
                    if ((i & 1023) == 0) {
                        acc += Heavy.huge0(i) + Heavy.huge1(i) + Heavy.huge2(i) + Heavy.huge3(i);
                    }
                    blackhole += acc;
                }
            }, "bench-worker-" + w);
            ts[w].setDaemon(true);
            ts[w].start();
        }

        long t0 = System.nanoTime();
        int redefines = 0;
        for (int r = 1; r <= rounds; r++) {
            Thread.sleep(intervalMs);
            Path dir = dirs[(r - 1) % dirs.length];
            byte[] bytes = Files.readAllBytes(dir.resolve("bench/Target.class"));
            Section: {
                System.out.println("ROUND_START " + r + " dir=" + dir + " t_ms=" + (System.nanoTime()-t0)/1_000_000);
                long s = System.nanoTime();
                Agent.inst.redefineClasses(new ClassDefinition(tc, bytes));
                long ms = (System.nanoTime() - s) / 1_000_000;
                redefines++;
                System.out.println("ROUND_END " + r + " redefine_ms=" + ms);
            }
            // correctness 1: field a of every pre-created instance must survive migration
            int bad = 0;
            for (int i = 0; i < NINST; i++) {
                if (getInt(insts[i], "a") != 1000 + i) bad++;
            }
            // correctness 2: compiled code must not be stale after redefinition
            int stale = 0;
            if (markerArg.length > 0) {
                int marker = Integer.parseInt(markerArg[(r - 1) % markerArg.length]);
                for (int i = 0; i < 16; i++) {
                    int expected = Expect.work(1000 + i, 7, marker);
                    int actual = ((Target) insts[i]).work(7);
                    if (actual != expected) stale++;
                }
            }
            System.out.println("VERIFY round=" + r + " bad=" + bad + " stale=" + stale);
        }
        if (recoveryMs > 0) {
            System.out.println("RECOVERY_START ms=" + recoveryMs);
            Thread.sleep(recoveryMs);
            System.out.println("RECOVERY_END");
        }
        stop = true;
        System.out.println("DONE redefines=" + redefines + " total_ms=" + (System.nanoTime()-t0)/1_000_000);
    }

    static volatile long blackhole;
}
