# Screenshots index

All screenshots show **genuine, unedited output** of the commands
listed, produced by the current build (labelled TAC, 28-test suite).

Capture method: the project's build environment is a headless Linux
VM with no display, so the images were rendered from the actual
terminal output captured in that environment (monospace terminal
rendering, e.g. the same technique as `freeze`/`termshot`). The text
in every image is byte-for-byte the program's real output; only the
rendering into an image is mechanical. To re-capture natively on any
machine with a display, run the command shown at the top of each
screenshot in a terminal and use the OS screenshot tool.

| File | Command shown | What it demonstrates |
|---|---|---|
| `00_build.png` | `make clean && make` | Clean build, no warnings |
| `01_assignment.png` | `./compiler examples/assignment.src` | Simple assignments |
| `02_arithmetic.png` | `./compiler examples/arithmetic.src` | Arithmetic TAC with temporaries |
| `03_simple_if.png` | `./compiler examples/simple_if.src` | Labelled `if` (no else) output |
| `04_if_else.png` | `./compiler examples/if_else.src` | Labelled `if-else` output (L1/L2/L3) |
| `05_sequential_if.png` | `./compiler examples/sequential_if.src` | Two sequential conditionals |
| `06_nested_if_else.png` | `./compiler examples/nested_if_else.src` | Nested conditionals, 7 labels |
| `07_multiple_statements.png` | `./compiler examples/multiple_statements.src` | Blocks with multiple statements |
| `08_invalid_syntax.png` | `./compiler examples/invalid_syntax.src` | Syntax-error handling, exit code 1 |
| `09_backpatch_trace.png` | `./compiler --trace examples/if_else.src` | Backpatching trace: `goto ?` targets resolved step by step |
| `10_make_test.png` | `make test` | Full automated suite: **28 passed, 0 failed** + final summary |
| `11_tokens.png` | `./compiler --tokens examples/if_else.src` | Lexical analysis (token stream) |

Final test summary: see `10_make_test.png` (28/28) and
`../test_results.txt`.
