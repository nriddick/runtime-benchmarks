/// Shared plumbing for the Ant Farm ports: the harness's argument
/// convention (`<exe> [param] <threads>`), the YAML result block, peak RSS
/// and the processor order the dispatcher is started on.
module bench;

import forkjoin;
import threadpool : ProcessorId;
import core.stdc.stdio : printf;
import core.time : MonoTime;

/// The thread count is the last argument; `paramCount` positional
/// parameters precede it. Without one, half the logical CPUs, as the C++
/// ports default to `hardware_concurrency() / 2`.
size_t threadArg(string[] args, size_t paramCount)
{
    import std.conv : to;
    if (args.length > paramCount + 1)
        return args[paramCount + 1].to!size_t;
    auto half = cpuOrder().length / 2;
    return half ? half : 1;
}

/// Logical CPUs in start order: every physical core first, grouped by
/// last-level cache, then the SMT siblings in the same order.
int[] cpuOrder()
{
    import std.algorithm : sort, map;
    import std.array : array, split;
    import std.conv : to;
    import std.file : exists, readText;
    import std.format : format;
    import std.string : strip;

    static int[] cached;
    if (cached !is null) return cached;
    static struct Cpu { int id, llc, sibling; }
    Cpu[] cpus;
    for (int id = 0;; ++id)
    {
        auto base = format("/sys/devices/system/cpu/cpu%d", id);
        if (!exists(base)) break;
        if (exists(base ~ "/online") && readText(base ~ "/online").strip == "0") continue;
        auto llcPath = base ~ "/cache/index3/id";
        int llc = exists(llcPath) ? readText(llcPath).strip.to!int : 0;
        auto siblings = readText(base ~ "/topology/thread_siblings_list").strip;
        int first = siblings.split(",")[0].split("-")[0].to!int;
        cpus ~= Cpu(id, llc, id == first ? 0 : 1);
    }
    cpus.sort!((a, b) => a.sibling != b.sibling ? a.sibling < b.sibling
        : a.llc != b.llc ? a.llc < b.llc : a.id < b.id);
    cached = cpus.map!(c => c.id).array;
    return cached;
}

/// Starts the dispatcher with the library's defaults on the first `threads`
/// processors of the start order (the calling thread is participant 0) and
/// prints the harness's `threads:` line.
void startPool(ref Dispatcher pool, size_t threads)
{
    ProcessorId[] ids;
    foreach (cpu; cpuOrder()[0 .. threads]) ids ~= ProcessorId(0, cast(ushort) cpu);
    pool.start(ids, DispatcherOptions.init);
    printf("threads: %zu\n", threads);
}

/// The YAML block the harness parses (`runs[0].duration`, `max_rss`).
void reportRun(MonoTime start, MonoTime end)
{
    printf("runs:\n");
    printf("  - iteration_count: 1\n");
    printf("    duration: %lld us\n", cast(long) (end - start).total!"usecs");
    printf("    max_rss: %ld KiB\n", peakRssKiB());
}

long peakRssKiB() nothrow @nogc
{
    import core.sys.posix.sys.resource : getrusage, rusage, RUSAGE_SELF;
    rusage usage;
    getrusage(RUSAGE_SELF, &usage);
    return usage.ru_maxrss;
}
