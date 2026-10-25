/// matmul(N) on the fork-join dispatcher, after the libfork port: quadrant
/// recursion down to 32x32 in two phases of four, so no two tasks write the
/// same C block concurrently. The join of phase 0 forks phase 1 and returns
/// its inline child as the continuation. The timed region includes
/// allocating and filling the matrices, as in the C++ ports.
module matmul;

import forkjoin;
import bench;
import core.stdc.stdio : printf;
import core.stdc.stdlib : malloc, free, exit;
import core.time : MonoTime;

/// The same i-k-j loop as the C++ ports' `matmul_small`, not a tuned kernel.
/// Row pointers and size_t indices are a codegen workaround: with int indices
/// LDC keeps 32-bit index arithmetic with per-iteration sign extension, which
/// left the vectorized loop at twice clang's instruction count. With them the
/// object code is the same 4x-unrolled AVX2 loop clang emits for matmul.hpp.
void matmulSmall(int* a, int* b, int* c, int n, int N) nothrow @nogc @system
{
    immutable size_t un = n, uN = N;
    foreach (size_t i; 0 .. un)
    {
        auto ci = c + i * uN;
        auto ai = a + i * uN;
        foreach (size_t k; 0 .. un)
        {
            immutable aik = ai[k];
            auto bk = b + k * uN;
            foreach (size_t j; 0 .. un)
                ci[j] += aik * bk[j];
        }
    }
}

struct Mm
{
    Node node;
    Mm* kids;
    int* a, b, c;
    int n, N;
    int phase;
}

void setKid(ref Mm kid, int* a, int* b, int* c, int n, int N) nothrow @nogc @system
{
    kid = Mm.init;
    kid.a = a;
    kid.b = b;
    kid.c = c;
    kid.n = n;
    kid.N = N;
    kid.node.run = &mmRun;
}

Node* forkPhase(Mm* m) nothrow @nogc @system
{
    int k = m.n / 2, N = m.N;
    auto a = m.a, b = m.b, c = m.c;
    auto kids = m.kids;
    if (m.phase == 0)
    {
        setKid(kids[0], a, b, c, k, N);
        setKid(kids[1], a, b + k, c + k, k, N);
        setKid(kids[2], a + k * N, b, c + k * N, k, N);
        setKid(kids[3], a + k * N, b + k, c + k * N + k, k, N);
    }
    else
    {
        setKid(kids[0], a + k, b + k * N, c, k, N);
        setKid(kids[1], a + k, b + k * N + k, c + k, k, N);
        setKid(kids[2], a + k * N + k, b + k * N, c + k * N, k, N);
        setKid(kids[3], a + k * N + k, b + k * N + k, c + k * N + k, k, N);
    }
    Node*[4] nodes = [&kids[0].node, &kids[1].node, &kids[2].node, &kids[3].node];
    return fork(&m.node, nodes[]);
}

Node* mmRun(Node* node) nothrow @nogc @system
{
    auto m = cast(Mm*) node;
    if (m.n <= 32)
    {
        matmulSmall(m.a, m.b, m.c, m.n, m.N);
        return complete(node);
    }
    m.kids = allocFrames!Mm(4);
    m.phase = 0;
    m.node.join = &mmJoin;
    return forkPhase(m);
}

Node* mmJoin(Node* node) nothrow @nogc @system
{
    auto m = cast(Mm*) node;
    if (m.phase == 0)
    {
        m.phase = 1;
        return forkPhase(m);
    }
    freeFrame(m.kids);
    return null;
}

int[] runMatmul(int N)
{
    auto total = cast(size_t) N * N;
    auto a = cast(int*) malloc(total * int.sizeof);
    auto b = cast(int*) malloc(total * int.sizeof);
    auto c = cast(int*) malloc(total * int.sizeof);
    a[0 .. total] = 1;
    b[0 .. total] = 1;
    c[0 .. total] = 0;
    Mm root;
    setKid(root, a, b, c, N, N);
    runRoot(&root.node);
    free(a);
    free(b);
    return c[0 .. total];
}

void validate(int[] c, int N)
{
    foreach (i, v; c)
        if (v != N)
        {
            printf("Wrong result at (%d,%d) : %d. expected %d\n",
                cast(int)(i / N), cast(int)(i % N), v, N);
            exit(1);
        }
}

void main(string[] args)
{
    if (args.length < 2)
    {
        printf("Usage: matmul <matrix size (power of 2)> [threads]\n");
        return;
    }
    import std.conv : to;
    auto N = args[1].to!int;
    Dispatcher pool;
    startPool(pool, threadArg(args, 1));
    free(runMatmul(N).ptr); // warmup
    printf("runs:\n");
    auto start = MonoTime.currTime;
    auto c = runMatmul(N);
    auto end = MonoTime.currTime;
    validate(c, N);
    free(c.ptr);
    printf("  - matrix_size: %d\n", N);
    printf("    duration: %lld us\n", cast(long)(end - start).total!"usecs");
    printf("    max_rss: %ld KiB\n", peakRssKiB());
    pool.stop();
}
