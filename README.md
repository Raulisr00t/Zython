# Zython

A Python 3 subset — tokenizer, parser, bytecode compiler, and virtual machine — written from
scratch in Zig, with real multithreaded execution.

## Highlights

- **Full pipeline**: source text → tokens → AST → bytecode → VM, with `--dump-tokens` /
  `--dump-ast` / `--dump-bytecode` flags to inspect every stage.
- **True parallelism, no GIL.** `spawn()`-ed workers run as real OS threads, each with its own
  isolated heap — no shared mutable object graph, so there's no per-object locking anywhere.
  `send()`/`recv()`/`join()` move data between workers by message passing. The same CPU-bound
  workload takes ~3.7s run sequentially and ~2.0s split across two workers — measured, not
  assumed.
- **`--verbose` live execution tracing**: every instruction prints as it executes — worker id,
  program counter, opcode, operand, live stack contents — flushed per instruction, so you can
  watch the VM work in real time, including two workers' traces genuinely interleaving.
- **A real language subset**: variables, arithmetic/comparison/boolean expressions, `if`/`elif`/
  `else`, `while`/`for`, functions with recursion, and lists with indexing.

## Quick start

```sh
zig.exe build --build-file build.zig
zython.exe fib.zpy
zython.exe --verbose small.zpy
zig.exe build test --build-file build.zig
```
