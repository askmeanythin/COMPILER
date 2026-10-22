# Development of a Simple Compiler Supporting If–Else Statements Using Lexical Analysis, Parsing, Syntax-Directed Translation, and Backpatching for Three Address Code Generation

A small but complete compiler written in **C** with **Flex** (lexical analysis) and **Bison** (syntax analysis). It reads a program in a miniature language, checks it, and generates **Three Address Code (TAC)**. Conditional control flow (`if` / `if–else`, including nesting) is implemented with **genuine backpatching**: jumps are first emitted with unresolved targets and are patched later by `makelist`, `merge`, and `backpatch`.

The compiler does **not** generate machine code and does **not** execute the source program. Its output is correct, validated intermediate code.

---

## 1. Objective and problem statement

Build one integrated application that takes a source program through:

```
Source program → Flex lexer → token stream → Bison parser →
syntax-directed translation → TAC generation → backpatching →
final numbered TAC output
```

and produces TAC whose jump targets are provably correct (checked by a built-in validator and by an automated test suite that verifies branch structure, not just exit codes).

## 2. Scope of the supported language

Supported:

- Identifiers: `a`, `total`, `count`, `total_2`, … (`[a-zA-Z_][a-zA-Z0-9_]*`)
- Integer constants: `0`, `42`, `2024`, …
- Assignments: `x = expression;`
- Arithmetic: `+  -  *  /`, parentheses, unary minus (`-a` compiles to `0 - a`)
- Relational operators in conditions: `<  >  <=  >=  ==  !=`
- `if (condition) statement`
- `if (condition) statement else statement`
- Nested `if` / `if–else` to any depth
- Blocks `{ ... }` with multiple statements, and empty blocks `{ }`
- A condition is a **relational expression** `expr relop expr`, optionally parenthesised: `if ((a < b)) { ... }`

Not supported (see Limitations): declarations, loops, functions, boolean operators (`&&`, `||`, `!` on conditions), floats, strings, comments. Note: `else if (...) ... else ...` chains *do* work, because the else branch is itself a statement — this was verified by compiling an if / else-if / else chain and checking all five jump targets.

Variables need **no declaration**; an assignment creates/uses the name directly. There is no symbol table and no type checking — every value is treated as an integer.

## 3. Software requirements

- Ubuntu Linux (or Ubuntu under WSL on Windows) — developed and tested on **Ubuntu 24.04.5 LTS**
- GCC 13.3, Flex 2.6.4, Bison 3.8.2, GNU Make 4.3 (see `results/environment.txt`)

Install on a fresh Ubuntu:

```bash
sudo apt update
sudo apt install -y build-essential flex bison
```

## 4. Architecture and pipeline

| Phase | File | Responsibility |
|---|---|---|
| Driver / CLI | `main.c` | Parses options (`--tokens`, `--trace`, `--help`), opens the file or stdin, runs the parser, emits the final `end` marker, patches the program's `nextlist`, validates and prints TAC |
| Lexical analysis | `lexer.l` | Tokens, keyword recognition, line numbers, invalid-character detection |
| Syntax analysis + SDT | `parser.y` | Grammar, precedence, semantic actions that emit TAC and drive backpatching |
| TAC + backpatching | `tac.h`, `tac.c` | Instruction array, `emit_*`, `makelist`/`merge`/`backpatch`, temporaries, validation, printing |

## 5. Folder structure

```
if_else_compiler/
├── lexer.l                 Flex specification
├── parser.y                Bison grammar + semantic actions
├── tac.h / tac.c           TAC representation and backpatching
├── main.c                  Command-line driver
├── Makefile                build / run / test / debug / clean
├── README.md               this file
├── VIVA.md                 viva preparation (25+ Q&A)
├── examples/               demonstration programs (.src)
│   ├── assignment.src      arithmetic.src     simple_if.src
│   ├── if_else.src         nested_if_else.src sequential_if.src
│   ├── multiple_statements.src                invalid_syntax.src
├── tests/
│   ├── test_compiler.sh    automated suite (24 tests)
│   ├── cases/              per-test input programs
│   └── expected/           golden TAC outputs for key examples
└── results/                genuine captured outputs
    ├── environment.txt     build_log.txt      test_results.txt
    ├── tokens.txt          sample_input.txt   sample_output.txt
    ├── tac_output.txt      backpatch_trace.txt
    └── screenshots/        captured demo screenshots (see §15)
```

## 6. Grammar

```
program    → stmt_list
stmt_list  → stmt_list M stmt | stmt
stmt       → matched | unmatched
matched    → IF ( bool ) M matched N ELSE M matched
           | { stmt_list } | { }
           | ID = expr ;
unmatched  → IF ( bool ) M stmt
           | IF ( bool ) M matched N ELSE M unmatched
bool       → expr < expr | expr > expr | expr <= expr
           | expr >= expr | expr == expr | expr != expr
           | ( bool )
expr       → expr + expr | expr - expr | expr * expr | expr / expr
           | - expr | ( expr ) | ID | NUM
M          → ε        { M.instr = nextinstr() }
N          → ε        { emit goto with unresolved target; N.nextlist = makelist of it }
```

Precedence: `*` `/` bind tighter than `+` `-`; binary operators are left-associative; unary minus binds tightest. Declared in Bison as `%left '+' '-'`, `%left '*' '/'`, `%right UMINUS`.

### Dangling else

The `matched`/`unmatched` split is the standard solution: a statement is *matched* if every `if` inside it has an `else`. An `else` can only complete a *matched* then-branch, so it always binds to the **nearest unmatched `if`**. Test T18 in the suite proves this by checking jump targets.

### Parser conflicts

The grammar builds with **no unresolved shift/reduce or reduce/reduce conflicts** (Bison prints no conflict warning). The Bison report (`make debug` writes `parser.output`) records 20 potential conflicts inside expression states, all resolved deterministically by the declared operator precedence/associativity — the intended mechanism, not an accident. (An earlier draft of this grammar also had a separate empty-statement-list production; that made the list structure ambiguous and produced 6 real shift/reduce conflicts. It was removed, and empty blocks are handled by the explicit `{ }` production instead.)

## 7. Lexical analysis (`lexer.l`)

- Keywords `if` / `else` are matched before the identifier rule, so they are never returned as identifiers; `ifx` is still an identifier (longest match).
- Multi-character operators `<= >= == !=` are single tokens (longest match).
- `lex_line` counts source lines and is used in every error message.
- An invalid character (for example `@`) prints `Lexical error at line N: invalid character 'c'`, is counted, skipped, and makes the compilation fail with exit code 1.
- Token-dump mode: `./compiler --tokens examples/if_else.src` (see `results/tokens.txt`).

Sample of the token dump for `if_else.src`:

```
Line 4   IF         if
Line 4   (          (
Line 4   ID         a
Line 4   <          <
Line 4   ID         b
Line 4   )          )
```

## 8. Syntax analysis (`parser.y`)

The Bison parser consumes the token stream, enforces the grammar (including precedence), and reports errors as `Syntax error at line N: ...` (verbose Bison messages, e.g. `syntax error, unexpected ID`). Any syntax or lexical error makes the compiler exit with status 1 and no TAC is printed.

## 9. Syntax-directed translation

Attributes used:

| Attribute | Meaning |
|---|---|
| `expr.place` | Name holding the expression's value (identifier, constant, or a fresh temporary `t1`, `t2`, …) |
| `bool.truelist` | List of jumps to patch with the first instruction of the *true* branch |
| `bool.falselist` | List of jumps to patch with the first instruction of the *false* branch |
| `stmt.nextlist` | List of jumps to patch with the first instruction *after* the statement |
| `M.instr` | Index of the next instruction to be emitted (marker) |
| `N.nextlist` | One-element list: the exit jump emitted at the end of a then-branch |

An arithmetic action creates a temporary and emits one instruction, e.g. `a + b * c` emits `t1 = b * c` then `t2 = a + t1` — precedence comes from the grammar, not from string tricks.

Instruction representation (`tac.h`):

```c
typedef struct {
    InstrKind kind;   /* ASSIGN, ARITH, IF, GOTO, END */
    char op[16];      /* arithmetic or relational operator */
    char arg1[128];
    char arg2[128];
    char result[128];
    int target;       /* jump target, internal 0-based; -1 = unresolved */
} Instruction;
```

## 10. TAC instruction format

Instructions are stored 0-based internally and **displayed numbered from 1**; a stored target `T` is displayed as `T + 1`. The final instruction of every successful compilation is `end`, so every jump target points at a real instruction.

```
result = arg1              assignment / copy
result = arg1 op arg2      arithmetic
if arg1 relop arg2 goto L  conditional jump
goto L                     unconditional jump
end                        program end marker
```

## 11. Backpatching algorithm

For a condition `a < b` the parser emits two jumps **without knowing their targets**:

```
i:   if a < b goto ?        (truelist  = makelist(i))
i+1: goto ?                 (falselist = makelist(i+1))
```

- `makelist(i)` — new list containing only instruction `i`.
- `merge(p1, p2)` — concatenated list (used e.g. to combine the exits of both branches).
- `backpatch(p, target)` — writes `target` into every instruction in `p`, then frees the list (backpatching consumes the list; every list is patched exactly once, by its owner).

Translation of `if (B) S1 else S2`:

1. `backpatch(B.truelist, M1)` where `M1` = first instruction of `S1`.
2. `S1` is translated; the `N` marker emits the then-branch exit `goto ?` and returns it as a list.
3. `backpatch(B.falselist, M2)` where `M2` = first instruction of `S2`.
4. `S.nextlist = merge(S1.nextlist, merge(N.nextlist, S2.nextlist))` — patched later by the enclosing sequence or, at top level, by `main()` to the `end` instruction.

`if (B) S1` (no else) is the same without step 3's branch: `S.nextlist = merge(B.falselist, S1.nextlist)`, so a false condition lands on whatever follows the `if`.

In a statement sequence, the marker between statements patches the previous statement's `nextlist` to the start of the next statement.

Run `./compiler --trace <file>` to see every emission, `makelist`, `merge`, and `backpatch` as it happens (full logs in `results/backpatch_trace.txt`).

### Validation

Before printing, `validate_tac()` checks every instruction: no jump may remain unpatched (`target == -1`), every jump target must be inside the instruction array, and assignments/arithmetic/conditional instructions must be well-formed. Any violation prints `Validation error: ...` and the compiler exits non-zero without printing TAC.

## 12. Build and execution

```bash
make                 # build ./compiler
make run             # build + run examples/if_else.src
./compiler examples/if_else.src          # compile a file
./compiler --tokens examples/if_else.src # token dump only
./compiler --trace  examples/if_else.src # backpatching trace + TAC
./compiler < examples/if_else.src        # read from stdin
make test            # automated suite (24 tests)
make debug           # sanitizer build (compiler_debug) + parser.output
make clean           # remove generated files
```

Exit status: `0` on success; `1` on lexical/syntax errors, TAC validation failure, bad options, or an unreadable file.

## 13. Worked example (verified output)

Source (`examples/if_else.src`):

```c
a = 10;
b = 20;

if (a < b) {
    c = a + b;
} else {
    c = a - b;
}
```

How it flows through the compiler:

1. **Lexer** — produces the token stream in `results/tokens.txt` (keywords, `ID`, `NUM`, `<`, braces, … with line numbers).
2. **Parser/SDT** — assignments emit instructions 1–2. The condition emits instructions 3–4 with `goto ?` targets; `truelist = {3}`, `falselist = {4}`.
3. **Then-branch** — marker `M1 = 5`; instructions 5–6 (`t1 = a + b`, `c = t1`); marker `N` emits instruction 7 (`goto ?`).
4. **Else-branch** — marker `M2 = 8`; instructions 8–9.
5. **Backpatching** (from the actual `--trace` log):
   - `backpatch(list {3}, target 5)` → `3: if a < b goto 5`
   - `backpatch(list {4}, target 8)` → `4: goto 8`
   - exits merged, then at program end `backpatch(list {7}, target 10)` → `7: goto 10`
6. **Validation** passes (no unresolved targets, all targets in range), then the final TAC is printed.

Actual output (`results/sample_output.txt`):

```
Three Address Code:
1: a = 10
2: b = 20
3: if a < b goto 5
4: goto 8
5: t1 = a + b
6: c = t1
7: goto 10
8: t2 = a - b
9: c = t2
10: end
```

Reading it: if `a < b` is true, control goes to 5 (then-branch) and instruction 7 skips the else-branch; if false, instruction 4 jumps to 8 (else-branch). Both paths continue at 10.

Nested example (`examples/nested_if_else.src`, output in `results/tac_output.txt`): the outer false jump lands on the second inner `if` (instruction 12), both inner then-branches exit to instruction 17 — demonstrating that merged `nextlist`s are patched correctly through nesting.

## 14. Test results

`make test` runs `tests/test_compiler.sh`: **24 tests, 24 passed, 0 failed** (full genuine log: `results/test_results.txt`). The suite covers assignments, all four arithmetic operators, precedence and parentheses, simple `if`, `if–else`, nested `if–else`, multiple statements in blocks, sequential conditionals, all six relational operators, empty blocks, six error cases (missing semicolon/brace/parenthesis, invalid character, incomplete conditional, `else` without `if`), dangling-else association, false-branch and true-branch skipping, nested target structure, division-by-zero-as-syntax, parenthesised conditions, and unary minus. Structural tests extract the numbered TAC and compare actual goto targets against the branch instructions they must point to.

The compiler was also run under AddressSanitizer + UndefinedBehaviorSanitizer (`make debug`) over all valid examples with **no findings** (including leak checking).

## 15. Screenshots

Real screenshots from running the demo on Windows (Ubuntu under WSL) are in `results/screenshots/`, numbered in demo order: the build, each example's TAC output (assignment, arithmetic, simple if, if–else, sequential if, nested if–else, multiple statements), the invalid-syntax error, and the backpatching trace. The text logs in `results/` (`build_log.txt`, `test_results.txt`, `tokens.txt`, `tac_output.txt`, `backpatch_trace.txt`) are genuine captured outputs of the same runs.

## 16. Limitations

- Integer-only arithmetic; no floating point, characters, or strings.
- Conditions must be a single relational comparison (optionally parenthesised). No `&&`, `||`, `!`, and no using a bare variable as a condition (`if (x)` is a syntax error).
- No declarations, symbol table, or type checking; using an unassigned variable is not detected.
- No loops, functions, arrays, or pointers.
- No comments in source programs.
- Division by zero *in the source* (e.g. `x = a / 0;`) is accepted and translated to TAC (`t1 = a / 0`) — this compiler never evaluates expressions, so nothing is divided at compile time; a runtime for the TAC would be responsible for trapping it (test T22 documents this).
- Very large programs are capped at 4096 TAC instructions (guard in `tac.c`).

## 17. Future improvements

- Boolean operators with short-circuit backpatching (`&&`, `||`, `!`).
- `while` loops (the same `makelist`/`merge`/`backpatch` machinery applies).
- A symbol table with declarations and simple type checking.
- An interpreter for the generated TAC, then a code-generation phase.
- Constant folding and other basic optimisations on the TAC.
