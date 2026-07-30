# Zython

A Python 3 subset — tokenizer, parser, bytecode compiler, and virtual machine — implemented twice:
a reference implementation in Python, and a from-scratch systems implementation in Zig with real
multithreaded execution.

## Highlights

- **Full pipeline, both implementations**: source text → tokens → AST → bytecode → VM, with
  `--dump-tokens` / `--dump-ast` / `--dump-bytecode` flags to inspect every stage.
- **True parallelism, no GIL.** The Zig VM runs `spawn()`-ed workers as real OS threads, each with
  its own isolated heap — no shared mutable object graph, so there's no per-object locking
  anywhere. `send()`/`recv()`/`join()` move data between workers by message passing. The same
  CPU-bound workload takes ~3.7s run sequentially and ~2.0s split across two workers — measured,
  not assumed.
- **`--verbose` live execution tracing** (Zig VM): every instruction prints as it executes —
  worker id, program counter, opcode, operand, live stack contents — flushed per instruction, so
  you can watch the VM work in real time, including two workers' traces genuinely interleaving.
- **A real language subset**: variables, arithmetic/comparison/boolean expressions, `if`/`elif`/
  `else`, `while`/`for`, functions with recursion, lists/dicts/tuples, classes with inheritance,
  and `try`/`except`/`finally`/`raise` — the exception handling is a genuine VM-managed block
  stack (`SETUP_TRY`/`POP_BLOCK`/`MATCH_EXC`), not the host language's own try/except wrapped
  around everything.

## Implementations

| | [`pyinterp/`](pyinterp/README.md) | [`zython/`](zython/README.md) |
|---|---|---|
| Language | Python | Zig |
| Values | Reuses host Python `int`/`str`/`list`/`dict` directly | Custom tagged-union `Value` type |
| Memory | Host GC | Arena allocator per VM instance |
| Concurrency | — | Real OS threads, isolated heaps, message passing |
| Coverage | Full: collections, classes, exceptions | Core + lists/`for`; collections/classes/exceptions in progress |
| Tests | 84 | 44 |

## Quick start

```sh
# Python implementation (run from the repo root)
python main.py tests/programs/fib.py
python -m pytest tests/ -q

# Zig implementation (toolchain vendored in tools/, nothing installed system-wide)
tools/zig-x86_64-windows-0.16.0/zig.exe build --build-file zython/build.zig
zython/zig-out/bin/zython.exe zython/tests/programs/fib.zpy
zython/zig-out/bin/zython.exe --verbose zython/tests/programs/small.zpy
tools/zig-x86_64-windows-0.16.0/zig.exe build test --build-file zython/build.zig
```

## Layout

```
pyinterp/    Python implementation: lexer, parser, compiler, VM, builtins
zython/      Zig implementation: same pipeline + real multithreading
tools/       Vendored Zig 0.16.0 toolchain
```

See each implementation's own README for architecture details, design tradeoffs, and known
limitations.
