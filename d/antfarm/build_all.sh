#!/usr/bin/env bash
# Builds the Ant Farm (D) benchmarks into build/<bench>, the layout the
# harness expects. Fetches Ant Farm at the tag below (or at
# RUNTIME_BENCHMARKS_LIBRARY_REF) into build/antfarm. Needs LDC (ldc2) 1.40
# or newer and git. Links the same allocator the C++ runtimes look for, in the
# same order: tcmalloc, mimalloc, jemalloc, else the system allocator.
set -euo pipefail
cd "$(dirname "$0")"
ANTFARM_TAG=${RUNTIME_BENCHMARKS_LIBRARY_REF:-v2.0.0}
ANTFARM_REPO=https://github.com/nriddick/antfarm
DC=${DC:-ldc2}

mkdir -p build
if [[ ! -d build/antfarm/.git ]]; then
  rm -rf build/antfarm
  git clone -q --depth 1 --branch "$ANTFARM_TAG" "$ANTFARM_REPO" build/antfarm
else
  git -C build/antfarm fetch -q --depth 1 origin "$ANTFARM_TAG"
  git -C build/antfarm checkout -q FETCH_HEAD
fi

malloc_lib=
installed=$(ldconfig -p 2>/dev/null || true)
for lib in tcmalloc_minimal tcmalloc mimalloc jemalloc; do
  if grep -q "lib$lib\.so " <<<"$installed"; then malloc_lib="-L-l$lib"; echo "Using malloc: $lib"; break; fi
done
[[ -n $malloc_lib ]] || echo "Using malloc: default"

# -O3 -mcpu=native -release -boundscheck=off is the D counterpart of the C++
# release presets (-O3 -march=native, asserts off). No alignment or layout
# flags: the C++ builds use the compiler defaults.
flags=(-O3 -release -mcpu=native -boundscheck=off)
inc=(-I. -Ibuild/antfarm -Ibuild/antfarm/threadpool/source -Ibuild/antfarm/forkjoin/source)
for bench in fib skynet nqueens matmul; do
  "$DC" "${flags[@]}" -i "${inc[@]}" "$bench.d" "-of=build/$bench" "-od=build/obj-$bench" $malloc_lib -L-lpthread &
done
wait
rm -rf build/obj-*

# The harness reads the compiler for its results metadata from the first
# command in build/compile_commands.json.
{
  echo "["
  sep=
  for bench in fib skynet nqueens matmul; do
    printf '%s  {"directory": "%s", "command": "%s %s -i %s %s.d -of=build/%s", "file": "%s.d"}' \
      "$sep" "$PWD" "$DC" "${flags[*]}" "${inc[*]}" "$bench" "$bench" "$bench"
    sep=$',\n'
  done
  echo; echo "]"
} > build/compile_commands.json
