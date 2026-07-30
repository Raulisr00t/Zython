# Zython — Phase 2 (Zig)

Phase 2 of the interpreter project: same pipeline as `../pyinterp/` (lexer -> parser -> AST ->
bytecode compiler -> VM), rewritten in Zig. See `../pyinterp/README.md` for the pipeline design
this ports from, and the top of the plan doc for why Zig + isolated-heap-per-VM-instance +
message passing was chosen over C/a GIL/CPython's real no-GIL approach.

## Toolchain

Zig 0.16.0 lives in `../tools/zig-x86_64-windows-0.16.0/zig.exe` (downloaded locally, not on
PATH, so it doesn't touch machine-wide state). Run it via that path, or from inside `zython/`:

```
../tools/zig-x86_64-windows-0.16.0/zig.exe build          # build zig-out/bin/zython.exe
../tools/zig-x86_64-windows-0.16.0/zig.exe build test      # run all `test { ... }` blocks
../tools/zig-x86_64-windows-0.16.0/zig.exe build run -- tests/programs/hello.zpy
```

Note: Zig 0.16 uses a notably different std lib API than older tutorials show (e.g.
`std.heap.DebugAllocator` not `GeneralPurposeAllocator`, `std.ArrayList(T)` is unmanaged-by-default
with `.empty` + explicit allocator per call, `pub fn main(init: std.process.Init) !void` with an
`Io` instance threaded through file/process APIs instead of the old implicit-argv `main() !void`).
If something from an older Zig example doesn't compile, that's almost certainly why -- check the
actual installed stdlib source under `lib/std/` rather than assuming.

## Status

**Z1 — done.** Project scaffold + full lexer port (`src/token.zig`, `src/lexer.zig`), same token
set and INDENT/DEDENT handling as `pyinterp/lexer.py`, 10 passing tests.

**Z2 — done.** Parser -> AST port (`src/ast.zig`, `src/parser.zig`) for the same initial subset
as `pyinterp/parser.py`: literals, arithmetic/comparison/boolean expressions, assignment,
`if`/`elif`/`else` (elif desugars into nested `If`, same as Phase 1), `while`, `def`/`return`.
`Node` is a tagged union; child nodes are arena-allocated `*const Node`. 8 more tests (18 total).

**Z3 — done.** The pipeline actually runs programs now:

- `src/value.zig` -- the runtime `Value` tagged union (int/float/bool/none/string/function/
  builtin), since unlike Phase 1 there's no host dynamic typing to borrow. Arithmetic/comparison
  promote int -> float when mixed, matching Python's numeric tower for the common case.
- `src/bytecode.zig` -- `Opcode`/`Instruction`/`CodeObject`, same opcode set as
  `pyinterp/bytecode.py`'s M1-M3 subset.
- `src/compiler.zig` -- AST -> bytecode, ported from `compiler.py` (jump backpatching, `and`/`or`
  short-circuit via `JUMP_IF_*_OR_POP`, everything Phase 1 already validated).
- `src/vm.zig` -- the frame-based dispatch loop, plus `--verbose`: prints every instruction as it
  executes (worker id, pc, opcode, arg, stack contents), **flushed after every single
  instruction** so it's genuinely live, not buffered-then-dumped. Worker-id-prefixed from day one
  even though there's only ever worker 0 until Z4.

`zython script.zpy` now computes and prints real output (`fib.zpy` produces the same
`0 1 1 2 3 5 8 13 21 34` as the Python version). `--dump-bytecode` and `--verbose` both work; all
four `--dump-*`/`--verbose` flags can combine. 13 more tests (31 total).

Memory strategy: `main.zig` uses the process-lifetime arena (`init.arena`) and never calls
`.deinit()` on the lexer/parser/VM -- deliberate (bulk-free at process exit, the "arena per VM
instance" plan). Tests use `std.testing.allocator` wrapped in a per-test `ArenaAllocator`.

One known simplification: `MAKE_FUNCTION` wraps a function's `CodeObject` into a callable `Value`
at **compile time** (in `compiler.zig`) rather than at VM runtime like Phase 1 does, since there
are no closures in this subset yet -- a function's "instance" is always identical regardless of
when it's constructed, so this is behaviorally equivalent for now. Revisit if/when closures land.

**Z4 — done. This is the actual point of Phase 2.** Real OS threads, isolated heaps, message
passing -- no GIL, no shared mutable object graph to lock:

- `src/worker.zig` -- `spawn(func, ...args)` starts a **real `std.Thread`** running a brand new,
  fully isolated `VM` (its own arena, its own globals, its own `Mailbox`). Args are deep-copied
  via `Value` -> `Message` -> `Value` (see `value.zig`) so the new thread never touches the
  spawning thread's arena -- only plain data (int/float/bool/none/string) can cross; functions/
  workers can't, since they reference a specific worker's arena-allocated bytecode graph.
  `join(handle)` blocks for the thread and returns its result, also deep-copied.
- `Mailbox` -- one per worker, a queue guarded by `Io.Mutex`/`Io.Condition` (Zig 0.16 moved these
  off `std.Thread` and onto `std.Io` entirely -- another version-specific surprise). `send()`
  appends + signals; `recv()` blocks until something arrives.
- The **only** other genuinely shared mutable state in the whole VM is stdout (there's only one
  real terminal) -- `vm.zig`'s `out_mutex` (one `Io.Mutex`, shared by the whole worker tree) wraps
  every `print()` and every `--verbose` trace line so concurrent workers' output can't interleave
  mid-line. Every other object is per-worker; nothing else needs a lock, which is the entire point
  of the isolated-heap design (contrast with CPython's real no-GIL effort, which has to solve this
  for *every* mutable object via biased refcounting -- see the plan doc).
- `spawn`/`send`/`recv`/`join` are plain **builtins**, not new syntax -- zero changes needed to
  the lexer/parser/compiler for this milestone.

Confirmed with `--verbose`: trace lines from two spawned workers computing simultaneously actually
interleave (alternating multi-line blocks of `worker 1`/`worker 2`, not one finishing before the
other starts) -- see `tests/programs/spawn_join.zpy` and `send_recv.zpy`. 4 more tests (35 total).
Also timed directly (`Measure-Command` over `bench_sequential.zpy` vs `bench_parallel.zpy`, same
CPU-heavy work): sequential ~3.7s, parallel (2 workers) ~2.0s -- a real ~1.8x speedup, not just
interleaving.

**Z5 — done (partial M4 port).** Lists, indexing, `for`-loops -- tightly scoped to the
highest-value subset rather than the full M4 (dicts/tuples/slicing/`in` are deferred):

- `src/value.zig` -- `ListObj` (heap-allocated, reference-semantic like real Python lists --
  `y = x` aliases, doesn't copy) and `IterObj` (internal-only, what `GET_ITER`/`FOR_ITER` push).
- New opcodes: `BUILD_LIST`, `BINARY_SUBSCR`/`STORE_SUBSCR` (with Python-style negative indexing
  and a real `IndexError` on out-of-range), `GET_ITER`/`FOR_ITER`.
- New builtins: `len()`, `range(stop)`/`range(start, stop)`, `append(list, item)`. `range()`
  **materializes a full list** rather than a lazy sequence (no lazy-iterator abstraction yet) --
  a documented simplification, revisit if a program needs a huge range without paying to allocate
  it. `append(list, item)` instead of `list.append(item)`: there's no attribute-access syntax in
  this subset yet, so list mutation goes through a plain builtin function.

Zero changes needed to the lexer's token set (Z1 already ported the *full* keyword/token list,
including `[`/`]`/`for`/`in`, even though only M1-M3 syntax used any of it until now). 6 more
tests (44 total). See `tests/programs/collections.zpy`.

Deferred to a later pass: dict/tuple literals, slicing (`x[a:b]`), `in`/`not in`, classes, `try`/
`except`.

Next: Z5+ (lists/dicts/for-loops, classes, exceptions) -- mirrors Phase 1's M4-M6, revisited now
that the core architecture (including concurrency) is proven end-to-end.
