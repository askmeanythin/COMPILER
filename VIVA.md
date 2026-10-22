# Viva Preparation — If–Else Compiler with Backpatching

Everything below describes **this** implementation (`lexer.l`, `parser.y`, `tac.c`, `main.c`). If a feature is not in the code, it is not claimed here.

---

## Two-minute project presentation

"My project is a small compiler for a miniature language, written in C using Flex and Bison on Ubuntu. It takes a source program with assignments, arithmetic expressions, and if–else statements — including nested ones — and generates Three Address Code.

The pipeline has four parts. The Flex lexer converts characters into tokens like identifiers, numbers, and operators, and tracks line numbers for error messages. The Bison parser checks the token stream against my grammar and, through semantic actions, directly generates intermediate code — that is syntax-directed translation. Arithmetic expressions create temporary variables, respecting operator precedence from the grammar.

The most important part is how control flow is generated. When the parser sees a condition like `a < b`, it does not yet know where the true and false branches start, so it emits jumps with unresolved targets — `if a < b goto ?` and `goto ?`. It remembers these instructions in the condition's truelist and falselist. When the branches have been generated and their starting instructions are known, backpatching fills the targets in. Statements also carry a nextlist of jumps that must land on whatever comes after the statement; lists are combined with merge and patched by the surrounding context.

Before printing, a validator checks that no jump is left unpatched and every target is a valid instruction. The project has an automated test suite of 24 tests that check the actual jump targets in the generated code — for example that a false condition really skips the true branch, and that in a dangling-else program the else belongs to the inner if. All 24 tests pass."

## The pipeline in one paragraph

Lexical analysis groups characters into tokens. Syntax analysis groups tokens into statements and expressions according to the grammar. Syntax-directed translation attaches meaning to grammar rules: as each construct is recognised, semantic actions emit TAC instructions and maintain patch lists. Backpatching resolves jump targets once they become known. Validation and printing produce the final numbered TAC.

## Why Flex and Bison?

Writing a lexer and a recursive-descent parser by hand is possible, but Flex/Bison are the standard tools for this job: the lexer is specified as regular expressions and compiled into an efficient finite-automaton scanner, and the parser is generated from the grammar as an LALR parser with automatic conflict reporting. That let me focus on the translation and backpatching logic, and use Bison's conflict reports to prove the grammar is unambiguous (no unresolved conflicts).

## Lexical analysis vs parsing

The lexer works on characters and answers "what kind of token is this?" — it does not know whether tokens form a legal program. The parser works on tokens and answers "does this token sequence follow the grammar?" — `a = ;` has perfectly good tokens but is a syntax error, which only the parser can detect.

## Tokens and lexemes

A **lexeme** is the actual character sequence in the source (`total`, `<=`, `42`). A **token** is the category the compiler uses internally (`ID`, `LE`, `NUM`). In the token dump (`--tokens`), `Line 4 LE (<=) <=` shows line, token, and lexeme. Keywords `if`/`else` are their own tokens, matched before the identifier pattern so they are never treated as names.

## Grammar productions (from `parser.y`)

```
stmt      → matched | unmatched
matched   → IF ( bool ) M matched N ELSE M matched | { stmt_list } | { } | ID = expr ;
unmatched → IF ( bool ) M stmt | IF ( bool ) M matched N ELSE M unmatched
bool      → expr relop expr | ( bool )
expr      → expr + expr | expr − expr | expr * expr | expr / expr | − expr | ( expr ) | ID | NUM
```

## Syntax-directed translation

Each grammar symbol carries attributes: an expression carries `place` (where its value lives), a condition carries `truelist`/`falselist`, a statement carries `nextlist`. Semantic actions in the grammar rules compute these attributes and emit instructions at exactly the point where the information is available — markers `M` and `N` exist only to capture instruction positions and emit the exit jump at the right moment.

## Three Address Code

TAC instructions have at most three operands, which makes them easy to generate and later optimise or translate to machine code. Forms used here: `x = y op z`, `x = y`, `if x relop y goto L`, `goto L`, and a final `end`. Example: `c = a + b * 2;` becomes `t1 = b * 2`, `t2 = a + t1`, `c = t2`.

## Temporary variables

A temporary (`t1`, `t2`, …, from `newtemp()`) holds the value of a sub-expression so that every instruction stays in three-address form. Precedence decides the order: in `a + b * c` the multiplication gets the first temporary because the grammar evaluates it first.

## Conditional and unconditional jumps

A condition compiles to two jumps: a conditional jump (`if a < b goto L`) taken when the condition is true, and an unconditional `goto` taken otherwise. The conditional jump's instruction goes on the truelist, the unconditional one on the falselist.

## makelist, merge, backpatch

- `makelist(i)` — creates a list containing just instruction `i`, whose target is unknown.
- `merge(p1, p2)` — joins two lists so they can be patched together later (for example, the exits of a then-branch and an else-branch both land after the whole if–else).
- `backpatch(p, target)` — writes `target` into every instruction in list `p`. In this code backpatch also frees the list nodes, so each list is patched exactly once by its owner.

## truelist, falselist, nextlist

- **truelist** — jumps to be patched with the address of the true branch.
- **falselist** — jumps to be patched with the address of the false branch.
- **nextlist** — jumps (statement exits) to be patched with the address of whatever executes after the statement. A statement sequence patches the previous statement's nextlist to the next statement's first instruction; at the top level, `main()` patches the program's nextlist to the final `end` instruction.

## Dangling else

In `if (a<b) if (c<d) x=1; else x=2;` the else could belong to either if. This grammar splits statements into *matched* (every if has an else) and *unmatched*. An else can only pair with a rule whose then-branch is matched, which forces it to the **nearest** if. Test T18 verifies the targets: the inner false jump goes to `x = 2`, the outer false jump goes to `end`.

## Operator precedence

Declared in Bison: `%left '+' '-'` below `%left '*' '/'`, `%right UMINUS` for unary minus. The parser resolves the potential expression conflicts using these declarations (recorded in `parser.output`), so `a + b * c` multiplies first and `(a + b) * c` adds first. Test T03 checks the instruction order.

## Error handling

- **Lexical**: invalid characters are reported with line numbers (`Lexical error at line 2: invalid character '@'`), counted, and cause exit code 1.
- **Syntax**: Bison's verbose errors (`Syntax error at line 3: syntax error, unexpected ID`), exit code 1, no TAC printed.
- **Internal**: the TAC validator rejects unpatched jumps, out-of-range targets, and malformed instructions before anything is printed.

## How nested if–else is translated

Recursively, by the same rules: an inner if's condition produces its own truelist/falselist; its branch exits merge into the inner statement's nextlist, which becomes part of the outer branch's nextlist, and so on up, until the outermost context patches everything. In `examples/nested_if_else.src`, both inner then-branches exit to instruction 17 (`done = result`) — the merge chain working through two levels.

## Why unresolved jumps must be patched

When a condition is parsed, the branch instructions do not exist yet — the parser works left to right in one pass. Emitting `goto ?` and patching later is what makes one-pass code generation for control flow possible. If a target stayed unresolved, the output would jump to an undefined place, which is why the validator treats any leftover unresolved jump as a hard error.

## Project limitations (honest list)

Integer arithmetic only; conditions are single relational comparisons (no `&&`/`||`/`!`, no bare `if (x)`); no declarations or type checking; no loops/functions/arrays; no source comments; division by zero in the source is translated but never evaluated at compile time.

---

## 25 likely viva questions

**1. What does your compiler take as input and produce as output?**
A source file (or stdin) in my mini-language; it outputs numbered Three Address Code. It stops at intermediate code — no machine code.

**2. What are the phases of your compiler?**
Lexical analysis (Flex), syntax analysis (Bison), syntax-directed translation (semantic actions emitting TAC), backpatching, then validation and printing.

**3. Why do you need a lexer separate from the parser?**
The lexer simplifies the parser's job: it removes whitespace, recognises multi-character operators like `<=` as single units, and classifies lexemes into tokens. The parser then works on a clean token stream.

**4. How does the lexer distinguish `if` from an identifier `ifx`?**
The keyword pattern is listed before the identifier pattern (wins ties), but matching is longest-first, so `ifx` (3 characters as an identifier) beats `if` (2 as a keyword).

**5. How do you report the line number of an error?**
The lexer counts newlines in a variable `lex_line`; both lexical errors and `yyerror` print it.

**6. What is a token vs a lexeme?**
A lexeme is the literal text (`<=`); a token is its category (`LE`). One token can have many lexemes — `ID` covers `a`, `total`, `count_2`.

**7. What grammar class is your parser?**
LALR(1), generated by Bison. The grammar builds with no unresolved shift/reduce or reduce/reduce conflicts.

**8. How is operator precedence implemented?**
Through Bison precedence declarations (`%left`, `%right UMINUS`); the generated parser resolves expression conflicts with them, which is visible in `parser.output`.

**9. What is syntax-directed translation?**
Attaching attributes and actions to grammar productions so that translation happens as parsing proceeds — here, actions emit TAC and maintain patch lists.

**10. What is Three Address Code? Why "three address"?**
Intermediate code where each instruction names at most three addresses — two operands and one result (plus a jump target for control flow). It is close to machine code but machine-independent.

**11. Why are temporaries needed?**
A complex expression must be broken into steps with one operation each; temporaries hold the intermediate results.

**12. What is backpatching?**
Generating jumps before their targets are known, recording the jump instructions in lists, and filling the targets in later when the destination instruction exists.

**13. Explain makelist, merge, backpatch in one line each.**
makelist: start a list with one pending jump. merge: join two lists to patch together. backpatch: write the target into every jump in a list.

**14. What are truelist and falselist?**
The lists of jumps that must go to the true branch and to the false branch of a condition.

**15. What is nextlist?**
The list of a statement's exit jumps, to be patched with the first instruction after the statement.

**16. What do the markers M and N do?**
`M` records `nextinstr()` — the position where the next construct starts — without emitting anything. `N` emits the unconditional exit jump at the end of a then-branch and returns it as a one-element list.

**17. Walk through `if (a<b) c=1; else c=2;` in your TAC.**
Instructions: `if a < b goto <then>`, `goto <else>`, `c = 1`, `goto <end>`, `c = 2`, `end`. The first jump is patched to the then-branch when M after the condition is known; the second to the else-branch; the third via the merged nextlist, patched by the enclosing context to `end`.

**18. How does the true branch skip the else branch?**
The `N` marker emits a `goto` after the then-branch whose target (patched later) is the instruction after the entire if–else.

**19. What is the dangling-else problem and how did you solve it?**
The ambiguity of which `if` an `else` belongs to. Solved grammatically with matched/unmatched statement categories, forcing the else to the nearest if — proven by test T18.

**20. How do you know no jump is left unpatched?**
`validate_tac()` runs before printing: it fails the compilation if any jump still has target −1 (unresolved) or points outside the instruction array.

**21. Why are instructions numbered from 1 but stored from 0?**
C arrays are 0-based, so internally targets are array indices; the display adds 1 because humans (and textbooks) count instructions from 1. The conversion is documented and applied in exactly one place, the printer.

**22. What happens on `x = a / 0;`?**
It compiles: TAC contains `t1 = a / 0`. The compiler never evaluates expressions, so there is no compile-time division; a runtime would trap it. Test T22 documents this behaviour.

**23. Are variables declared anywhere? What about using an unassigned variable?**
No declarations and no symbol table in this version — assignment introduces a name. Use of an unassigned variable is not detected; that is a stated limitation and a future improvement.

**24. Can your conditions use `&&` or a single variable, like `if (x)`?**
No. A condition must be one relational comparison, optionally parenthesised. Short-circuit boolean operators are the natural next extension of the same truelist/falselist machinery.

**25. How did you test the compiler beyond "it compiles"?**
A 24-test automated suite (`make test`) that, besides exit codes, extracts the numbered TAC and asserts exact jump targets: false jumps land on else-branches, then-exits land after the if–else, the dangling-else targets are correct, nested exits merge to the right instruction. Error cases must fail with the right error class and line numbers. The binary was also run under AddressSanitizer/UBSan with no findings.

**26. Why does a sequence of statements need backpatching at all?**
Because a statement like an `if` ends with jumps whose destination is "whatever comes next" — unknown until the next statement is parsed. The sequence rule patches the previous statement's nextlist with the marker captured before the next statement.

**27. What would you add next?**
While loops (same list machinery plus a loop-back edge), boolean operators with short-circuit evaluation, and a symbol table with declarations and type checking.
