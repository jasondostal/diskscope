# DiskScope — Parallel Scan Tuning Research

**Target:** Whole-volume filesystem metadata scan via `getattrlistbulk(2)`, recursive, on a MacBook M5 Pro (Apple Silicon, 18 cores split into performance + efficiency clusters).

**Baseline (measured, real):**
- Serial recursive `getattrlistbulk` walk: 1.71M entries / 20.9s (~82k entries/s), warm cache. **Syscall/kernel-bound** — stripping ~1.5M `String` allocations moved the needle ~2%.
- Shared-queue worker pool (one `NSCondition` guarding a directory-path queue, `broadcast()` after every dir): 2w=2.1×, 4w=3.3×, **8w=5.0× (4.2s, the sweet spot)**, then *degrades*: 12w=6.9s, 18w=8.3s.
- Diagnosed collapse: thundering-herd `broadcast()` on every one of ~184k directory completions, compounded by P/E asymmetry (peak ≈ P-core count).

This report is deliberately skeptical: most of the wins are **scheduling/contention** wins, not syscall wins. The syscall floor is real and several "obvious" optimizations below are marginal.

---

## Executive Summary — Ranked Optimizations

| # | Optimization | Expected payoff | Effort | Risk | Verdict |
|---|---|---|---|---|---|
| 1 | **Cap worker count at P-core count + set QoS so workers land on P-cores** (`hw.perflevel0.logicalcpu`, `QOS_CLASS_USER_INITIATED`) | High — *recovers the 8→18 worker collapse entirely*; likely your single biggest lever | Low | Low | **Load-bearing.** Do this first. |
| 2 | **Replace `broadcast()` with `signal()` + eliminate per-completion wakeups** (or move to a sharded / work-stealing design) | High — kills the thundering herd that *causes* the collapse | Low–Med | Low | **Load-bearing.** Pairs with #1. |
| 3 | **Per-worker work-stealing deques (Chase-Lev) or sharded queues** instead of one global lock | Med–High — removes the central mutex as the scaling ceiling; lets you safely use all P-cores | Med–High | Med | Load-bearing *if* #1+#2 don't get you to ~P-core-linear scaling. |
| 4 | **Per-worker reused attr buffer** (drop the per-directory 256 KiB malloc/free; ~184k allocs) | Low–Med | Low | Low | Cheap; do it. Marginal on warm cache but trivially correct. |
| 5 | **`getattrlistbulk` attr-set minimization + `FSOPT_PACK_INVAL_ATTRS`** (request only name/size/type/dates, simplify parsing) | Low–Med | Low | Low | Modest. The syscall cost is dominated by traversal, not attr count, but trimming the request and the parse branch is free. |
| 6 | **Larger / tuned buffer (512 KiB–1 MiB) to cut syscall count per dir** | Low | Low | Low | Marginal — most dirs are small; only helps huge dirs. Measure, don't assume. |
| 7 | **Swift structured concurrency (`TaskGroup` + actor accumulator)** as the orchestration layer | Neutral/Low (perf); High (maintainability) | Med | Med | *Not* a perf win for this workload; the cooperative pool caps at core count and an actor accumulator serializes merges. Use GCD/raw threads for the hot loop. |
| 7 | **`os_workgroup` / parallel workgroups** | ~Zero here | Med | Med | Not applicable — that API is for real-time (audio) deadline coordination, not throughput fan-out. Skip. |
| 8 | **String interning of path components** | Low | Med | Med | Mostly a *memory*/index win, not a scan-speed win (already proven: strings are ~2%). Defer to the index layer. |

**TL;DR:** Items **1 and 2 are the fix.** Your collapse is a scheduling + contention pathology, not a syscall-throughput problem. Cap at P-cores, raise QoS, stop broadcasting. Everything below #3 is polish.

---

## 1. Kill the thundering herd / queue contention

### Diagnosis
Your pool funnels every worker through one `NSCondition`. After *each* of ~184k directory completions you `broadcast()`, waking all N waiters to contend for one mutex; N−1 immediately re-block. At 8 workers this is tolerable; at 18 the wakeup storm + lock convoy + cross-cluster cache-line bouncing on the lock word dominates. This is a textbook lock convoy / thundering herd.

### The cheap, high-leverage fixes (do these first)

**(a) `signal()` not `broadcast()`.** When a worker pushes child directories onto the queue, it should wake at most as many sleepers as items added — usually one. `broadcast()` is only correct/necessary when you change a *global* condition all waiters care about (e.g. "scan finished"). For "one new item available," `signal()` wakes exactly one waiter. This alone removes the herd.

```swift
// On producing K child dirs while holding the lock:
for _ in 0..<min(K, sleepingWorkers) { cond.signal() }   // not cond.broadcast()
// broadcast() ONLY for the terminal "all work done" condition.
```

**(b) Batch the enqueue.** A worker that reads a directory typically discovers several subdirectories. Push them as one locked critical section (one lock acquire, one or few `signal()`s), not one lock acquire per child.

**(c) Track an explicit "active work" counter** for termination instead of relying on broadcast-to-check-empty. Pattern: a shared `outstanding` count (atomically incremented when dirs are enqueued, decremented when a dir is fully processed). When `queue.isEmpty && outstanding == 0`, signal completion once. This avoids the "wake everyone to let them re-check and re-sleep" loop.

### The structural fix (if 1a–1c don't reach near-P-core-linear scaling)

This is a **tree-shaped, dynamically-discovered, recursively-fanning** workload: each unit of work (read a dir) *produces more units* (its subdirs). That is the canonical shape for **work-stealing**, which is exactly why Apple's own guidance for parallel loops says to let GCD's internal work-stealing balance the load rather than statically partitioning ([Apple, *Optimize for Apple Silicon*](https://developer.apple.com/news/?id=vk3m204o)).

Three options, in increasing effort:

1. **Sharded queues (recommended next step).** Replace the single global queue with `P` queues (one per worker), each with its own lock. A worker pushes children to *its own* queue (no contention on the common path). When a worker's queue is empty, it scans siblings round-robin and steals a batch from the back of the fullest. This removes ~all steady-state lock contention because the common case (push/pop your own queue) touches an uncontended lock. ~80% of the benefit of full work-stealing for ~30% of the complexity.

2. **Chase-Lev lock-free work-stealing deque (the "real" answer).** Each worker owns a deque: it `push`/`pop`s the **bottom** (LIFO, lock-free, single-owner — cache-friendly, depth-first which keeps the working set small), and idle thieves `steal` from the **top** (the only contended, CAS-based operation). This is the design used by Intel TBB, Rust's Rayon, Java's ForkJoinPool, and Cilk. It is *the* structure for divide-and-conquer / tree workloads. Note the well-documented weak-memory-model subtleties on ARM (Apple Silicon is weakly ordered): the canonical fix requires care with the `steal` CAS and a `seq_cst` fence on the fast path — see the verification literature ([Chase-Lev formal verification, arXiv:2309.03642](https://arxiv.org/abs/2309.03642); [Wingo, "correct and efficient work-stealing for weak memory models"](https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models)). A mature C++17 reference implementation you can mirror: [ConorWilliams/ConcurrentDeque](https://github.com/ConorWilliams/ConcurrentDeque). **Skeptical note:** this is the *correct* design but on a warm-cache, syscall-bound walk the difference between sharded-queues-with-stealing and a perfect Chase-Lev deque is likely small. Build the sharded version first; only go lock-free if profiling shows the per-queue locks are still the ceiling.

3. **`DispatchQueue.concurrentPerform` recursively.** Tempting because GCD already has internal work-stealing, but `concurrentPerform` is a *blocking parallel-for over a known count* — it does not naturally express "recursively discovered, unbounded fan-out." Nesting `concurrentPerform` per directory risks thread explosion (each blocked call can spin up helper threads) and you lose control of worker count, which directly fights optimization #1. **Not recommended as the top-level driver.** It *is* fine as a leaf optimization for one very large directory's entries.

**Recommended design:** Keep your explicit pool (you need explicit count control for #1). Move to **P per-worker sharded queues with batch steal-from-back**, LIFO push/pop on the owner side for depth-first locality. Use an atomic `outstanding` counter for termination. Reserve full Chase-Lev for later only if measured necessary.

Sources: [Apple — Optimize for Apple Silicon](https://developer.apple.com/news/?id=vk3m204o) · [Chase-Lev verification (arXiv)](https://arxiv.org/abs/2309.03642) · [Weak-memory work-stealing (Wingo)](https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models) · [ConcurrentDeque C++17 ref](https://github.com/ConorWilliams/ConcurrentDeque)

---

## 2. Apple Silicon P/E core scheduling

### How QoS maps to cores
On Apple Silicon (AMP — asymmetric multiprocessing), **the QoS class is the primary input the scheduler uses to place a thread on a P-core vs an E-core.** Confirmed by Apple and by reverse-engineering of the scheduler:

- `QOS_CLASS_BACKGROUND` (value `0x09`) threads are confined to **E-cores only** (this is where Spotlight indexing, Time Machine, etc. live). **Never run scan workers at Background QoS** — you'll be locked to the slow cluster.
- `QOS_CLASS_UTILITY` (`0x11`), `QOS_CLASS_USER_INITIATED` (`0x19`), and `QOS_CLASS_USER_INTERACTIVE` (`0x21`) are eligible for **P-cores**, and will normally run on P-cores when available, spilling to E-cores under load.
- The scheduler also clusters threads by frequency domain and favors lower-numbered cores first, with frequent migration ([Eclectic Light — How macOS manages virtual cores](https://eclecticlight.co/2023/10/23/how-does-macos-manage-virtual-cores-on-apple-silicon/)).

QoS values are from libpthread's `qos.h` ([PureDarwin/libpthread `pthread/qos.h`](https://github.com/PureDarwin/libpthread/blob/master/pthread/qos.h)): `USER_INTERACTIVE=0x21, USER_INITIATED=0x19, DEFAULT=0x15, UTILITY=0x11, BACKGROUND=0x09`.

### Recommendation
- **Run scan workers at `QOS_CLASS_USER_INITIATED`** — the user kicked off a scan and is waiting, but it's not UI-frame work. `USER_INTERACTIVE` is overkill and would compete with the UI thread; `UTILITY` risks more aggressive E-core spillover. On raw `pthread`s, set it per-thread:

```swift
import Darwin
// Inside each worker thread's entry, first thing:
pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0)
```
This is the documented, ADC-sanctioned way to set QoS on threads not created by GCD ([blog.xoria.org — macOS threading](https://blog.xoria.org/macos-tips-threading/); Apple DTS confirms it's correct for `std::thread`/raw pthreads). If you instead create a `DispatchQueue`, set it via `DispatchQoS(qosClass: .userInitiated, relativePriority: 0)`.

### Can you *pin* to P-cores?
**No public API pins a thread to a specific core or to the P-cluster.** `thread_policy_set` with `THREAD_AFFINITY_POLICY` is a no-op on Apple Silicon. QoS is the only lever — and it's a *hint*, not a guarantee. The practical control you do have is **how many threads you create**: macOS will fill P-cores first, so if you create ≈P-core threads at User-Initiated QoS, they land on P-cores in the common case.

### Does over-spawning hurt? — Yes, and this is your collapse.
Your data (peak at 8 ≈ P-core count, degradation after) is the **exact, independently-reproduced** signature seen across the ecosystem on Apple Silicon:
- The Constantine threadpool issue on an M4 Max (12P+4E) caps at ~8×, and **16 threads is *slower* than 12** — and "trying to change QoS doesn't help" once you've over-subscribed ([constantine#515](https://github.com/mratsim/constantine/issues/515)). The same pattern is reported in Go/gnark, .NET, and OpenSCAD.
- Root cause: for a CPU/syscall-bound homogeneous workload, adding E-core workers drags the *whole* parallel section toward E-core speed (the slowest worker gates a balanced split), and the extra threads add scheduling, migration, and (in your case) lock-contention overhead with little throughput upside.

### Optimal worker-count strategy
1. **Detect P-core count at runtime** (don't hardcode; M-series SKUs vary):
   ```swift
   func performanceCoreCount() -> Int {
       var n = 0; var size = MemoryLayout<Int>.size
       if sysctlbyname("hw.perflevel0.logicalcpu", &n, &size, nil, 0) == 0, n > 0 { return n }
       return ProcessInfo.processInfo.activeProcessorCount // fallback (pre-AS / failure)
   }
   ```
   `hw.perflevel0.*` = performance cluster, `hw.perflevel1.*` = efficiency cluster ([Apple Dev Forums — perf core count](https://developer.apple.com/forums/thread/664774)).
2. **Default worker count = P-core count** (8 on your M5 Pro if perflevel0=8). This matches your measured sweet spot exactly.
3. **Optionally** add a *small* number of E-core helpers (e.g. workers = P + ⌊E/2⌋) *only after* you've fixed the lock contention (#1) — otherwise they hurt. For a syscall-bound walk where workers often block in-kernel (not pure CPU), a few extra threads can actually help hide syscall latency, so **make worker count a tunable and benchmark P, P+2, P+E** once contention is gone. But ship the default at P.

Sources: [Apple — Optimize for Apple Silicon](https://developer.apple.com/news/?id=vk3m204o) · [Eclectic Light — virtual cores / QoS→core mapping](https://eclecticlight.co/2023/10/23/how-does-macos-manage-virtual-cores-on-apple-silicon/) · [constantine#515 — over-spawn degradation](https://github.com/mratsim/constantine/issues/515) · [PureDarwin qos.h](https://github.com/PureDarwin/libpthread/blob/master/pthread/qos.h) · [perflevel sysctl](https://developer.apple.com/forums/thread/664774) · [xoria — pthread QoS](https://blog.xoria.org/macos-tips-threading/)

---

## 3. `getattrlistbulk` tuning

### Signature & request structure
```c
int getattrlistbulk(int dirfd, struct attrlist *attrList,
                    void *attrBuf, size_t attrBufSize, uint64_t options);
```
`attrList` (from `<sys/attr.h>`):
```c
struct attrlist {
    u_short     bitmapcount;   // = ATTR_BIT_MAP_COUNT (5)
    u_int16_t   reserved;
    attrgroup_t commonattr;    // u_int32_t
    attrgroup_t volattr;       // MUST be 0 for getattrlistbulk
    attrgroup_t dirattr;
    attrgroup_t fileattr;
    attrgroup_t forkattr;
};
```
([fergofrog xnu attr.h browser](https://fergofrog.com/code/cbowser/xnu/bsd/sys/attr.h.html); [getattrlistbulk(2) man](https://www.manpagez.com/man/2/getattrlistbulk/))

### Required & recommended attributes for {name, size, type, dates}
- **Required by the API:** `ATTR_CMN_NAME` and `ATTR_CMN_RETURNED_ATTRS` (omitting either → `EINVAL`). `ATTR_CMN_RETURNED_ATTRS` is also what lets you correctly parse variable per-entry layouts.
- **Type:** `ATTR_CMN_OBJTYPE` (VREG/VDIR/VLNK…) — you need this anyway to know which entries are directories to recurse into. (`dirattr`/`fileattr` are mostly redundant if you use OBJTYPE.)
- **Size:** `ATTR_FILE_TOTALSIZE` (allocated) or `ATTR_FILE_DATALENGTH` (logical) in `fileattr`. For a treemap you likely want **`ATTR_FILE_ALLOCSIZE`/`TOTALSIZE`** (on-disk footprint). Pick one; requesting both is wasted bytes per entry.
- **Dates:** `ATTR_CMN_MODTIME` / `ATTR_CMN_CRTIME` / `ATTR_CMN_ACCTIME` as needed — each adds a `timespec` per entry, so request **only the dates you actually index.**

**Skeptical note:** trimming attributes mostly shrinks the per-entry buffer payload and your parse loop; it does **not** dramatically cut kernel cost, because the kernel still walks each inode. Your own experiment (stripping strings = 2%) already shows you're not bound by per-entry byte-shuffling. Treat this as a small, free win, not a lever.

### Option flags ( `<sys/attr.h>` ) — relevant ones
| Flag | Value | Use it? |
|---|---|---|
| `FSOPT_NOFOLLOW` | `0x00000001` | N/A — `getattrlistbulk` reports entries; symlinks come back as `VLNK` via OBJTYPE. You control whether to follow by deciding whether to `openat` the target. |
| `FSOPT_REPORT_FULLSIZE` | `0x00000004` | Optional. Makes the leading length report the *full* needed size so you can detect truncation. Minor diagnostic value; not needed for correctness. |
| `FSOPT_PACK_INVAL_ATTRS` | `0x00000008` | **Recommended.** Guarantees every requested attribute slot is present (defaults for unsupported ones), so your fixed-offset parser never has to special-case a filesystem that omits an attribute. Requires `ATTR_CMN_RETURNED_ATTRS` (which you already request). Slightly *larger* buffers, simpler/branch-free parsing. |
| `FSOPT_ATTR_CMN_EXTENDED` | `0x00000020` | Only if you request extended common attrs; otherwise leave off. |
| `FSOPT_NOFOLLOW_ANY` | `0x00000800` | Security hardening (reject any symlink in the path); not relevant to throughput. |

([attr.h values](https://fergofrog.com/code/cbowser/xnu/bsd/sys/attr.h.html))

### Buffer size
You use 256 KiB. **The buffer mainly bounds how many entries return per syscall; the syscall count per directory ≈ ceil(dir_payload / bufsize).** Most directories are small (a handful to a few hundred entries) and return fully in *one* call regardless — so a bigger buffer helps **only** the rare huge directory. Bumping to 512 KiB–1 MiB is cheap and harmless if you reuse the buffer (see §5), but expect **marginal** total-time impact. **Critical APFS correctness bug to handle:** if a call *exactly* fills the buffer, the *next* call returns `ERANGE` instead of `0` — you must treat `ERANGE`-after-data as "keep going / done," not a fatal error ([getattrlistbulk man](https://www.manpagez.com/man/2/getattrlistbulk/); [Apple Dev Forums — ERANGE](https://developer.apple.com/forums/thread/98262)). A buffer that's a round power-of-two and larger reduces the odds of hitting the exact-fill edge.

### The real per-directory cost: 184k `openat` + traversal
You pay an `openat(dirfd)` + a sequence of `getattrlistbulk` + `close` per directory. This open/close/dir-iterate overhead — **not** attribute marshalling — is the bulk of the kernel time, and it's inherently per-directory.
- **There is no batch "open many dirs" syscall.** `getattrlistbulk` itself only returns the *entries* of one already-open dir; it cannot descend. So you cannot eliminate the 184k opens at the syscall layer.
- **What actually helps:** parallelism (each open/iterate is independent → spread across P-cores, §1–2) and **not re-opening**. Make sure you `openat` each dir exactly once, iterate to completion, `close`, and never re-`stat`/re-open an entry you already have attributes for (the bulk call already gave you type+size+dates, so you should *not* issue a follow-up `getattrlist`/`stat` per file — verify your code doesn't).
- `getdirentriesattr(2)` is **deprecated** and superseded by `getattrlistbulk`; it offered no relevant advantage and is gone on modern macOS — don't reach for it. `getattrlistat(2)` is single-path (one object), useful only for the volume root or one-off lookups, not bulk iteration. You're already on the right primitive.

Sources: [getattrlistbulk(2) man](https://www.manpagez.com/man/2/getattrlistbulk/) · [xnu attr.h flags](https://fergofrog.com/code/cbowser/xnu/bsd/sys/attr.h.html) · [Apple Dev Forums — ERANGE on exact fill](https://developer.apple.com/forums/thread/98262) · [Michael Tsai — directory read performance](https://mjtsai.com/blog/2019/04/22/performance-considerations-when-reading-directories-on-macos/)

---

## 4. Swift concurrency vs GCD vs raw threads

### The shape of the problem
~184k directory "tasks" fanning out dynamically, each doing **blocking in-kernel syscalls** (`openat`, `getattrlistbulk`), feeding a shared accumulator.

### Why structured concurrency (`TaskGroup`) is *not* the hot-path tool here
- **Blocking syscalls don't suspend.** Swift's cooperative thread pool sizes itself to the core count and assumes tasks `await` (yield) at suspension points. `getattrlistbulk` is a synchronous blocking call — it **occupies** a cooperative-pool thread for its whole duration with no suspension. A pool of `TaskGroup` child tasks all blocked in `getattrlistbulk` can starve the pool and risks the runtime's "forward progress" guarantees. This is the wrong tool for a wall of blocking syscalls.
- **Actor accumulator serializes.** Funnelling 1.71M results through one `actor` reintroduces a serialization point (the actor's mailbox) — the same bottleneck you're trying to remove. Per-worker tallies merged at the end (what you already do) is strictly better.
- **Task overhead at 100k+ fan-out:** child-task allocation, escalation bookkeeping, and the executor hop per task are real fixed costs. For a workload where you want maximal control over *exactly N P-core-pinned workers*, the runtime deciding pool size for you fights optimization #1.

The popular "Swift Concurrency avoids thread explosion / outperforms GCD" claim is true for **I/O-bound, await-heavy** UI/server code — *not* for a CPU+blocking-syscall parallel-for where you want fixed worker count and core pinning ([SwiftLee — threads vs tasks](https://www.avanderlee.com/concurrency/threads-vs-tasks-in-swift-concurrency/)).

### Recommendation
- **Hot loop: raw `pthread`s (or a thin `Thread` wrapper) — exactly P of them — with per-thread QoS (`pthread_set_qos_class_self_np`) and per-thread sharded queues + per-thread tally.** This gives you the precise control §1–2 require. GCD `DispatchQueue` with explicit QoS is an acceptable alternative but cedes worker-count control.
- **Orchestration only: Swift concurrency is fine for the *outer* API** — kick off the scan inside a `Task`, `await` its completion, surface progress via an `AsyncStream`. Just keep the 184k-task fan-out *out* of `TaskGroup` and out of the cooperative pool. Bridge the raw-thread engine to async with a single `withCheckedContinuation` that resolves when all workers join.

Sources: [SwiftLee — Threads vs Tasks](https://www.avanderlee.com/concurrency/threads-vs-tasks-in-swift-concurrency/) · [Apple — Optimize for Apple Silicon (work-stealing/concurrentPerform guidance)](https://developer.apple.com/news/?id=vk3m204o)

---

## 5. Memory / allocation

Your own experiment already proved allocation is **~2%** of wall time on a warm cache — so treat this section as *correctness/scalability hygiene and memory-footprint control*, not a speed lever. Still, two are free and worth doing:

### (a) Reuse the attr buffer per worker — **do it (cheap, correct)**
Allocating/freeing a 256 KiB–1 MiB buffer ~184k times is pure waste and adds allocator contention across cores. Allocate **one buffer per worker thread**, sized once, and reuse it for every directory that worker processes. Thread-local (each worker owns its buffer for its lifetime) → zero sharing, zero contention.
```swift
final class Worker {
    private let bufSize = 1 << 20  // 1 MiB, reused for the worker's whole life
    private let buf = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
    deinit { buf.deallocate() }
    // pass `buf`/`bufSize` to every getattrlistbulk call this worker makes
}
```
This also removes per-directory page faults on freshly-malloc'd memory. **Likely the most worthwhile item in this section**, and it directly supports a *larger* buffer (§3) at no steady-state cost.

### (b) String handling — defer to the index layer
- Path *component* names are mostly unique (filenames) — interning them buys little and adds hash-map contention on the hot path.
- **Directory path prefixes** are the high-duplication part (every entry in a dir shares the dir's path). Don't reconstruct a full absolute `String` per entry during the scan. Carry a parent-node reference / interned dir-path id and store entries as `(parentID, name)`; materialize full paths lazily only when the search/treemap UI needs them. This is a **memory-footprint and index-build** win (1.71M entries), not a scan-throughput win.
- Real interning (e.g. a component dictionary) belongs in the *index* you build from the scan, where dedup pays off for search, not in the scan's inner loop.

### (c) Result accumulation
Keep per-worker tallies/arrays and merge once at the end (you already do this — it's correct). Avoid any shared/locked accumulator or actor (see §4). If you stream into a live index, hand each worker its own batch buffer and flush batches to the index under a single coarse handoff, not per-entry.

**Skeptical bottom line for §5:** (a) is worth a few percent and removes allocator cross-core contention that could otherwise *masquerade* as scaling loss; (b)/(c) are about RAM and index quality, not the 20.9s→target scan time.

---

## Recommended implementation order

1. **Cap workers at `hw.perflevel0.logicalcpu` (=8 on M5 Pro) and `pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0)` per worker.** Re-measure — you should *not* see the 12/18-worker collapse anymore, and 8 workers should hold ~5× or improve.
2. **`broadcast()`→`signal()`, batch enqueues, atomic `outstanding` termination counter.** Re-measure scaling cleanliness.
3. **Per-worker reused 1 MiB buffer + `FSOPT_PACK_INVAL_ATTRS` + minimal attr set + ERANGE-after-data handling.**
4. **Only if 1–3 don't reach ~P-core-linear:** move to **P sharded per-worker queues with batch steal-from-back** (and consider lifting worker count to P+small once contention is gone). Reserve Chase-Lev lock-free deques for last, with ARM weak-memory care.
5. Leave Swift `TaskGroup`/actors for the *outer* async API and the *index* layer; keep them out of the 184k-task fan-out.

The first two steps target the actual measured pathology and are low-effort/low-risk. Everything else is incremental.

---

## Source index
- Apple — *Optimize for Apple Silicon with performance and efficiency cores*: https://developer.apple.com/news/?id=vk3m204o
- Eclectic Light — *How does macOS manage virtual cores on Apple silicon?* (QoS→P/E mapping): https://eclecticlight.co/2023/10/23/how-does-macos-manage-virtual-cores-on-apple-silicon/
- constantine#515 — *Threadpool: poor performance scaling on macOS / Apple Silicon* (over-spawn degradation, QoS doesn't fix it): https://github.com/mratsim/constantine/issues/515
- PureDarwin libpthread `pthread/qos.h` (qos_class_t values): https://github.com/PureDarwin/libpthread/blob/master/pthread/qos.h
- blog.xoria.org — *macOS Tips for Programmers: Threading* (pthread_set_qos_class_self_np usage): https://blog.xoria.org/macos-tips-threading/
- Apple Dev Forums — *Number of high-performance cores* (`hw.perflevel0`): https://developer.apple.com/forums/thread/664774
- getattrlistbulk(2) man page: https://www.manpagez.com/man/2/getattrlistbulk/
- xnu `bsd/sys/attr.h` (FSOPT flag values, struct attrlist): https://fergofrog.com/code/cbowser/xnu/bsd/sys/attr.h.html
- Apple Dev Forums — *getattrlistbulk returns ERANGE* (APFS exact-fill bug): https://developer.apple.com/forums/thread/98262
- Michael Tsai — *Performance Considerations When Reading Directories on macOS*: https://mjtsai.com/blog/2019/04/22/performance-considerations-when-reading-directories-on-macos/
- Chase-Lev formal verification (weak memory correctness): https://arxiv.org/abs/2309.03642
- Wingo — *Correct and efficient work-stealing for weak memory models*: https://wingolog.org/archives/2022/10/03/on-correct-and-efficient-work-stealing-for-weak-memory-models
- ConorWilliams/ConcurrentDeque — C++17 Chase-Lev reference: https://github.com/ConorWilliams/ConcurrentDeque
- SwiftLee — *Threads vs. Tasks in Swift Concurrency*: https://www.avanderlee.com/concurrency/threads-vs-tasks-in-swift-concurrency/
