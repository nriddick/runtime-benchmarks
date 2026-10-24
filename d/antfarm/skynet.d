/// skynet on the fork-join dispatcher: 10-way forks to depth 8 (100M
/// leaves); nine children go on the deque, the tenth runs inline.
module skynet;

import forkjoin;
import bench;
import core.stdc.stdio : printf;
import core.stdc.stdlib : malloc, free;
import core.time : MonoTime;

enum uint depthMax = 8;
enum ulong expected = 4999999950000000UL;

struct Sky
{
    Node node;
    Sky* kids;
    ulong num;
    ulong result;
}

Node* skyRun(Node* node) nothrow @nogc @system
{
    auto s = cast(Sky*) node;
    auto depth = s.node.depth;
    if (depth == depthMax)
    {
        s.result = s.num;
        return complete(node);
    }
    ulong offset = 1;
    foreach (_; 0 .. depthMax - depth - 1) offset *= 10;
    auto kids = cast(Sky*) malloc(10 * Sky.sizeof);
    Node*[10] nodes;
    foreach (i; 0 .. 10)
    {
        kids[i] = Sky.init;
        kids[i].num = s.num + offset * i;
        kids[i].node.run = &skyRun;
        nodes[i] = &kids[i].node;
    }
    s.kids = kids;
    s.node.join = &skyJoin;
    return fork(node, nodes[]);
}

Node* skyJoin(Node* node) nothrow @nogc @system
{
    auto s = cast(Sky*) node;
    ulong sum;
    foreach (i; 0 .. 10) sum += s.kids[i].result;
    s.result = sum;
    free(s.kids);
    return null;
}

void skynet()
{
    Sky root;
    root.node.run = &skyRun;
    runRoot(&root.node);
    if (root.result != expected)
        printf("ERROR: wrong result - %llu\n", root.result);
}

void main(string[] args)
{
    Dispatcher pool;
    startPool(pool, threadArg(args, 0));
    skynet(); // warmup
    auto start = MonoTime.currTime;
    skynet();
    auto end = MonoTime.currTime;
    reportRun(start, end);
    pool.stop();
}
