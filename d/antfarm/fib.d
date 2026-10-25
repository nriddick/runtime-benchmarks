/// fib(n) on the fork-join dispatcher: fib(n-1) goes on the deque, fib(n-2)
/// runs inline, the join adds the results. No sequential cutoff. Child
/// frames come from the dispatcher's frame pool (`allocFrames`/`freeFrame`).
module fib;

import forkjoin;
import bench;
import core.stdc.stdio : printf;
import core.time : MonoTime;

struct Fib
{
    Node node;
    Fib* kids;
    ulong result;
    uint n;
}

Node* fibRun(Node* node) nothrow @nogc @system
{
    auto f = cast(Fib*) node;
    if (f.n < 2)
    {
        f.result = f.n;
        return complete(node);
    }
    auto kids = allocFrames!Fib(2);
    kids[0] = Fib.init;
    kids[0].n = f.n - 1;
    kids[0].node.run = &fibRun;
    kids[1] = Fib.init;
    kids[1].n = f.n - 2;
    kids[1].node.run = &fibRun;
    f.kids = kids;
    f.node.join = &fibJoin;
    Node*[2] nodes = [&kids[0].node, &kids[1].node];
    return fork(node, nodes[]);
}

Node* fibJoin(Node* node) nothrow @nogc @system
{
    auto f = cast(Fib*) node;
    f.result = f.kids[0].result + f.kids[1].result;
    freeFrame(f.kids);
    return null;
}

ulong fib(uint n)
{
    Fib root;
    root.n = n;
    root.node.run = &fibRun;
    runRoot(&root.node);
    return root.result;
}

void main(string[] args)
{
    if (args.length < 2)
    {
        printf("Usage: fib <n-th fibonacci number requested> [threads]\n");
        return;
    }
    import std.conv : to;
    auto n = args[1].to!uint;
    Dispatcher pool;
    startPool(pool, threadArg(args, 1));
    fib(30); // warmup
    auto start = MonoTime.currTime;
    auto result = fib(n);
    printf("output: %llu\n", result);
    auto end = MonoTime.currTime;
    reportRun(start, end);
    pool.stop();
}
