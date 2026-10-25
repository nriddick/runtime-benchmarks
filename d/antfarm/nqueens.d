/// nqueens(14) on the fork-join dispatcher, after the libfork port: each
/// placement forks one child per safe column, carrying a copy of the board.
module nqueens;

import forkjoin;
import bench;
import core.stdc.stdio : printf;
import core.time : MonoTime;

enum int work = 14;
enum int expected = 365_596;

struct Queens
{
    Node node;
    Queens* kids;
    int result;
    int count;
    char[work] buf;
}

Node* queensRun(Node* node) nothrow @nogc @system
{
    auto q = cast(Queens*) node;
    int xMax = cast(int) q.node.depth;
    if (xMax == work)
    {
        q.result = 1;
        return complete(node);
    }
    char[work] safe;
    int count;
    foreach (y; 0 .. work)
    {
        char c = cast(char) y;
        bool ok = true;
        foreach (x; 0 .. xMax)
        {
            char p = q.buf[x];
            if (c == p || c == p - (xMax - x) || c == p + (xMax - x))
            {
                ok = false;
                break;
            }
        }
        if (ok) safe[count++] = c;
    }
    if (count == 0)
    {
        q.result = 0;
        return complete(node);
    }
    auto kids = allocFrames!Queens(count);
    Node*[work] nodes;
    foreach (i; 0 .. count)
    {
        kids[i] = Queens.init;
        kids[i].buf = q.buf;
        kids[i].buf[xMax] = safe[i];
        kids[i].node.run = &queensRun;
        nodes[i] = &kids[i].node;
    }
    q.kids = kids;
    q.count = count;
    q.node.join = &queensJoin;
    return fork(node, nodes[0 .. count]);
}

Node* queensJoin(Node* node) nothrow @nogc @system
{
    auto q = cast(Queens*) node;
    int sum;
    foreach (i; 0 .. q.count) sum += q.kids[i].result;
    q.result = sum;
    freeFrame(q.kids);
    return null;
}

int nqueens()
{
    Queens root;
    root.node.run = &queensRun;
    runRoot(&root.node);
    if (root.result != expected)
        printf("error: expected %d, got %d\n", expected, root.result);
    return root.result;
}

void main(string[] args)
{
    Dispatcher pool;
    startPool(pool, threadArg(args, 0));
    nqueens(); // warmup
    auto start = MonoTime.currTime;
    auto result = nqueens();   // checks the answer, as the C++ ports do inside the timer
    printf("output: %d\n", result);
    auto end = MonoTime.currTime;
    reportRun(start, end);
    pool.stop();
}
