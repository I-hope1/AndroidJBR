import sys
p = sys.argv[1]
s = open(p).read()
anchor = '        int tickCount = 0;'
add = '''        // bench: 2,000,000 live PlayerService instances -> every structural
        // redefine exercises the DCEVM instance walk/full GC and Remold's
        // getInstances/InitFix instance patch at scale.
        final java.util.List<PlayerService> live = new java.util.ArrayList<>(2_000_000);
        for (int i = 0; i < 2_000_000; i++) {
            live.add(new PlayerService(null));
        }
        System.out.println("[BENCH] live instances=" + live.size());
        final java.util.concurrent.atomic.AtomicLong calls = new java.util.concurrent.atomic.AtomicLong();
        if (System.getenv("GC_PULSE") != null) {
            Thread gc = new Thread(() -> { while (true) { try { Thread.sleep(700); } catch (InterruptedException e) { return; } System.gc(); } }, "bench-gc-pulse");
            gc.setDaemon(true);
            gc.start();
        }
        Thread stats = new Thread(() -> {
            long last = 0, lastT = System.currentTimeMillis();
            while (true) {
                try { Thread.sleep(2000); } catch (InterruptedException e) { return; }
                long c = calls.get(); long t = System.currentTimeMillis();
                System.out.println("[THROUGHPUT] calls=" + c + " delta=" + (c - last) + " dt_ms=" + (t - lastT));
                last = c; lastT = t;
            }
        }, "bench-stats");
        stats.setDaemon(true);
        stats.start();
        for (int w = 0; w < 4; w++) {
            Thread t = new Thread(() -> { long i = 0; while (true) { player.work(++i); calls.incrementAndGet(); } }, "bench-worker-" + w);
            t.setDaemon(true);
            t.start();
        }
'''
assert anchor in s and 'bench-worker' not in s
open(p, 'w').write(s.replace(anchor, add + anchor))
