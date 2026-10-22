#!/usr/bin/env bash
#
# test_compiler.sh - automated test suite for the if-else compiler.
#
# Version 2 (label-aware, hardened):
#  * The compiler's final TAC uses labels (L1, L2, ...) for jump
#    targets. This harness parses BOTH the instruction sequence and
#    the label definitions, resolves every "goto Lk" to the sequence
#    number of the instruction labelled Lk, and then checks branch
#    structure numerically - the same rigour as before, now through
#    the label mapping (which is itself tested in T25).
#  * Hardened after a field failure (WSL lab machine, 15/24): when a
#    compiler run produced no TAC, the old helpers indexed the empty
#    result array and died with "unbound variable" / "bad array
#    subscript" (old line 52), cascading into bogus FAIL values.
#    Every array access is now bounds-checked, every lookup result is
#    validated before use, and a failed structural check reports the
#    compiler's exit code and stderr instead of empty variables.
#  * Requires bash (associative arrays). The Makefile invokes this
#    script with bash explicitly; running it with sh is rejected
#    below with a clear message instead of cryptic errors.
#
# Every test prints: ID | Purpose | Expected | Actual | PASS/FAIL
# The suite exits non-zero if any test fails.
#
# Note: the compiler itself validates the TAC before printing (no
# unpatched jumps, all targets in range, labels consistent), so a
# run with exit code 0 already implies the validator passed.

if [ -z "${BASH_VERSION:-}" ]; then
    echo "This test suite must be run with bash (use: bash tests/test_compiler.sh or make test)" >&2
    exit 2
fi

set -u
cd "$(dirname "$0")/.."
COMPILER="./compiler"

PASS_COUNT=0
FAIL_COUNT=0
RC=0
OUT=""
ERR=""

# Parsed view of the last compiler run's TAC:
#   INSTR_TEXT[seq-1]  instruction text without its "N:"/"Lk:" prefix
#   SEQ_LABEL[seq-1]   label of that instruction, or "" if none
#   LABEL_SEQ[label]   sequence number (1-based) of a label
declare -a INSTR_TEXT=()
declare -a SEQ_LABEL=()
declare -A LABEL_SEQ=()

run_compiler() { # $1 = source file
    OUT="$("$COMPILER" "$1" 2>/tmp/_test_err.txt)"
    RC=$?
    ERR="$(cat /tmp/_test_err.txt)"
    INSTR_TEXT=()
    SEQ_LABEL=()
    LABEL_SEQ=()
    local line prefix text seq
    while IFS= read -r line; do
        prefix="${line%%:*}"
        text="${line#*: }"
        seq=$(( ${#INSTR_TEXT[@]} + 1 ))
        INSTR_TEXT+=("$text")
        if [[ "$prefix" =~ ^L[0-9]+$ ]]; then
            SEQ_LABEL+=("$prefix")
            LABEL_SEQ["$prefix"]=$seq
        else
            SEQ_LABEL+=("")
        fi
    done < <(printf '%s\n' "$OUT" | grep -E '^(L[0-9]+|[0-9]+): ' || true)
}

instr_count() { echo "${#INSTR_TEXT[@]}"; }

# line_no <regex> : sequence number of first matching instruction
line_no() {
    local i n
    n="$(instr_count)"
    for (( i = 0; i < n; i++ )); do
        if printf '%s' "${INSTR_TEXT[$i]}" | grep -Eq "$1"; then
            echo $(( i + 1 ))
            return 0
        fi
    done
    echo 0
}

# target_seq <sequence number> : sequence number that the goto on
# that instruction jumps to (labels resolved), or "" if the line is
# not a jump / the number is out of range / the label is undefined.
target_seq() {
    local seq="${1:-0}" n ref
    n="$(instr_count)"
    if [ "$seq" -lt 1 ] || [ "$seq" -gt "$n" ]; then
        echo ""
        return 0
    fi
    ref="$(printf '%s' "${INSTR_TEXT[$((seq - 1))]}" \
           | sed -nE 's/.*goto (L[0-9]+|[0-9]+).*/\1/p')"
    if [ -z "$ref" ]; then
        echo ""
    elif [[ "$ref" =~ ^L ]]; then
        echo "${LABEL_SEQ[$ref]:-}"
    else
        echo "$ref"
    fi
}

diag() { # compact diagnostics for a failed structural test
    echo "rc=$RC lines=$(instr_count) err: $(printf '%s' "$ERR" | head -1)"
}

report() { # $1=id $2=purpose $3=expected $4=actual $5=0 pass / 1 fail
    if [ "$5" -eq 0 ]; then
        PASS_COUNT=$((PASS_COUNT + 1))
        echo "$1 | $2 | Expected: $3 | Actual: $4 | PASS"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        echo "$1 | $2 | Expected: $3 | Actual: $4 | FAIL"
    fi
}

expect_error() { # $1=id $2=purpose $3=file $4=stderr pattern
    run_compiler "$3"
    if [ "$RC" -ne 0 ] && printf '%s' "$ERR" | grep -Eq "$4"; then
        report "$1" "$2" "non-zero exit + error matching '$4'" \
               "exit=$RC, error reported" 0
    else
        report "$1" "$2" "non-zero exit + error matching '$4'" \
               "exit=$RC, stderr: $ERR" 1
    fi
}

echo "================ Compiler test suite ================"
echo "bash $BASH_VERSION | compiler: $COMPILER"

# T01 - simple assignment (examples/assignment.src)
run_compiler examples/assignment.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'total = a' \
   && printf '%s' "$OUT" | grep -q 'count = total'; then
    report T01 "Simple assignment" "exit 0, plain copy assignments" \
           "exit 0, assignments found" 0
else
    report T01 "Simple assignment" "exit 0, plain copy assignments" \
           "$(diag)" 1
fi

# T02 - addition and subtraction
run_compiler tests/cases/add_sub.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a \+ b' \
   && printf '%s' "$OUT" | grep -Eq '= a - b'; then
    report T02 "Addition and subtraction" "temps for a+b and a-b" \
           "both present" 0
else
    report T02 "Addition and subtraction" "temps for a+b and a-b" \
           "$(diag)" 1
fi

# T03 - operator precedence and parentheses
run_compiler tests/cases/precedence.src
L_MUL=$(line_no '= b \* c')
L_ADD=$(line_no '= a \+ t')
L_PAREN_ADD=$(line_no '= a \+ b')
L_PAREN_MUL=$(line_no '= t[0-9]+ \* c')
if [ "$RC" -eq 0 ] && [ "$L_MUL" -gt 0 ] && [ "$L_ADD" -gt "$L_MUL" ] \
   && [ "$L_PAREN_ADD" -gt 0 ] && [ "$L_PAREN_MUL" -gt "$L_PAREN_ADD" ]; then
    report T03 "Operator precedence and parentheses" \
           "* before + for a+b*c; (a+b) before * for (a+b)*c" \
           "mul@$L_MUL add@$L_ADD paren-add@$L_PAREN_ADD paren-mul@$L_PAREN_MUL" 0
else
    report T03 "Operator precedence and parentheses" \
           "* before + ; parens first" \
           "mul@$L_MUL add@$L_ADD padd@$L_PAREN_ADD pmul@$L_PAREN_MUL $(diag)" 1
fi

# T04 - multiplication and division
run_compiler tests/cases/mul_div.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a \* b' \
   && printf '%s' "$OUT" | grep -Eq '= a / b'; then
    report T04 "Multiplication and division" "temps for a*b and a/b" \
           "both present" 0
else
    report T04 "Multiplication and division" "temps for a*b and a/b" \
           "$(diag)" 1
fi

# T05 - simple if: true -> then stmt, false -> after the if
run_compiler examples/simple_if.src
IF_L=$(line_no 'if a < b goto')
THEN_L=$(line_no 'c = 1')
AFTER_L=$(line_no 'd = 2')
T_IF=$(target_seq "$IF_L")
T_FALSE=$(target_seq $(( IF_L + 1 )))
if [ "$RC" -eq 0 ] && [ -n "$T_IF" ] && [ "$T_IF" = "$THEN_L" ] \
   && [ -n "$T_FALSE" ] && [ "$T_FALSE" = "$AFTER_L" ]; then
    report T05 "Simple if" "if->then@$THEN_L, false->after@$AFTER_L" \
           "if->$T_IF, false->$T_FALSE (labels resolved)" 0
else
    report T05 "Simple if" "if target=then, false target=after" \
           "if->$T_IF false->$T_FALSE then@$THEN_L after@$AFTER_L $(diag)" 1
fi

# T06 - if-else structure: both branches present, then before else
run_compiler examples/if_else.src
IF_L=$(line_no 'if a < b goto')
THEN_L=$(line_no '= a \+ b')
ELSE_L=$(line_no '= a - b')
if [ "$RC" -eq 0 ] && [ "$IF_L" -gt 0 ] && [ "$THEN_L" -gt "$IF_L" ] \
   && [ "$ELSE_L" -gt "$THEN_L" ]; then
    report T06 "If-else structure" "then-branch (+) before else-branch (-)" \
           "if@$IF_L then@$THEN_L else@$ELSE_L" 0
else
    report T06 "If-else structure" "then before else" \
           "if@$IF_L then@$THEN_L else@$ELSE_L $(diag)" 1
fi

# T07 - nested if-else targets (labels resolved to sequence numbers)
run_compiler examples/nested_if_else.src
O_IF=$(line_no 'if a < b goto')
O_ELSE_IF=$(line_no 'if a == c goto')
DONE_L=$(line_no 'done = result')
R1_L=$(line_no 'result = 1')
R3_L=$(line_no 'result = 3')
T_O=$(target_seq "$O_IF")
T_O_FALSE=$(target_seq $(( O_IF + 1 )))
EXIT1=$(target_seq $(( R1_L + 1 )))
EXIT2=$(target_seq $(( R3_L + 1 )))
I1_IF=$(line_no 'if b > c goto')
if [ "$RC" -eq 0 ] && [ -n "$T_O" ] && [ "$T_O" = "$I1_IF" ] \
   && [ -n "$T_O_FALSE" ] && [ "$T_O_FALSE" = "$O_ELSE_IF" ] \
   && [ -n "$EXIT1" ] && [ "$EXIT1" = "$DONE_L" ] \
   && [ -n "$EXIT2" ] && [ "$EXIT2" = "$DONE_L" ]; then
    report T07 "Nested if-else targets" \
           "outer true->inner1@$I1_IF, outer false->inner2@$O_ELSE_IF, exits->done@$DONE_L" \
           "true->$T_O false->$T_O_FALSE exits->$EXIT1,$EXIT2" 0
else
    report T07 "Nested if-else targets" "nested targets as documented" \
           "T_O=$T_O T_O_FALSE=$T_O_FALSE EXIT=$EXIT1,$EXIT2 $(diag)" 1
fi

# T08 - multiple statements in blocks; then-exit skips to after-if
run_compiler examples/multiple_statements.src
C_L=$(line_no 'c = t')
SKIP_T=$(target_seq $(( C_L + 1 )))
AFTER_L=$(line_no '= c \+ 1')
if [ "$RC" -eq 0 ] && [ "$(line_no 'a = t')" -gt 0 ] \
   && [ "$(line_no 'b = t')" -gt 0 ] && [ "$(line_no 'c = 0')" -gt 0 ] \
   && [ -n "$SKIP_T" ] && [ "$SKIP_T" = "$AFTER_L" ]; then
    report T08 "Multiple statements in blocks" \
           "3 then-stmts + 3 else-stmts, skip goto->after@$AFTER_L" \
           "skip->$SKIP_T" 0
else
    report T08 "Multiple statements in blocks" "block statements + skip" \
           "skip=$SKIP_T after@$AFTER_L $(diag)" 1
fi

# T09 - sequential conditionals: first if's false jump lands on second if
run_compiler examples/sequential_if.src
IF1=$(line_no 'if a < b goto')
IF2=$(line_no 'if b > a goto')
F1=$(target_seq $(( IF1 + 1 )))
if [ "$RC" -eq 0 ] && [ -n "$F1" ] && [ "$F1" = "$IF2" ] && [ "$IF2" -gt "$IF1" ]; then
    report T09 "Sequential conditionals" "if1 false->if2@$IF2" \
           "if1 false->$F1" 0
else
    report T09 "Sequential conditionals" "if1 false->if2" \
           "F1=$F1 IF2=$IF2 $(diag)" 1
fi

# T10 - every relational operator
run_compiler tests/cases/relops.src
OK=0
for OP in '<' '>' '<=' '>=' '==' '!='; do
    if printf '%s' "$OUT" | grep -Fq "if a $OP b goto"; then
        OK=$((OK + 1))
    fi
done
if [ "$RC" -eq 0 ] && [ "$OK" -eq 6 ]; then
    report T10 "All relational operators" "6 operators in conditions" \
           "6 found" 0
else
    report T10 "All relational operators" "6 operators" \
           "$OK found, $(diag)" 1
fi

# T11 - empty blocks produce valid control flow, no unresolved jumps
run_compiler tests/cases/empty_block.src
if [ "$RC" -eq 0 ] && [ "$(line_no 'c = 3')" -gt 0 ] \
   && ! printf '%s' "$OUT" | grep -q 'goto ?'; then
    report T11 "Empty blocks" "exit 0, no unpatched jumps" \
           "exit 0, valid TAC" 0
else
    report T11 "Empty blocks" "exit 0, no unpatched jumps" \
           "$(diag)" 1
fi

# T12-T17 - error cases (must fail with a reported error)
expect_error T12 "Missing semicolon" tests/cases/missing_semicolon.src \
             'Syntax error at line [0-9]+'
expect_error T13 "Missing closing brace" tests/cases/missing_brace.src \
             'Syntax error at line [0-9]+'
expect_error T14 "Missing closing parenthesis" tests/cases/missing_paren.src \
             'Syntax error at line [0-9]+'
expect_error T15 "Invalid characters" tests/cases/invalid_char.src \
             "Lexical error at line 2: invalid character '@'"
expect_error T16 "Incomplete conditional" tests/cases/incomplete_if.src \
             'Syntax error at line [0-9]+'
expect_error T17 "Else without matching if" tests/cases/else_without_if.src \
             'Syntax error at line [0-9]+'

# T18 - dangling else binds to the NEAREST if
run_compiler tests/cases/dangling_else.src
O_IF=$(line_no 'if a < b goto')
I_IF=$(line_no 'if c < d goto')
X1_L=$(line_no 'x = 1')
X2_L=$(line_no 'x = 2')
END_L=$(line_no '^end$')
O_FALSE=$(target_seq $(( O_IF + 1 )))
I_FALSE=$(target_seq $(( I_IF + 1 )))
I_TRUE=$(target_seq "$I_IF")
if [ "$RC" -eq 0 ] && [ -n "$I_FALSE" ] && [ "$I_FALSE" = "$X2_L" ] \
   && [ -n "$O_FALSE" ] && [ "$O_FALSE" = "$END_L" ] \
   && [ -n "$I_TRUE" ] && [ "$I_TRUE" = "$X1_L" ]; then
    report T18 "Dangling-else association" \
           "inner false->x=2@$X2_L, outer false->end@$END_L" \
           "inner false->$I_FALSE, outer false->$O_FALSE" 0
else
    report T18 "Dangling-else association" "else binds to inner if" \
           "I_FALSE=$I_FALSE O_FALSE=$O_FALSE I_TRUE=$I_TRUE $(diag)" 1
fi

# T19 - false condition skips the true branch (false goto = else start)
run_compiler examples/if_else.src
IF_L=$(line_no 'if a < b goto')
ELSE_L=$(line_no '= a - b')
FALSE_T=$(target_seq $(( IF_L + 1 )))
if [ "$RC" -eq 0 ] && [ -n "$FALSE_T" ] && [ "$FALSE_T" = "$ELSE_L" ]; then
    report T19 "False condition skips true branch" \
           "false goto->else@$ELSE_L" "false goto->$FALSE_T (label resolved)" 0
else
    report T19 "False condition skips true branch" "false goto->else" \
           "FALSE_T=$FALSE_T ELSE@$ELSE_L $(diag)" 1
fi

# T20 - true branch skips the false branch (then-exit goto = end)
run_compiler examples/if_else.src
ELSE_FIRST=$(line_no '= a - b')
END_L=$(line_no '^end$')
EXIT_T=$(target_seq $(( ELSE_FIRST - 1 )))
if [ "$RC" -eq 0 ] && [ -n "$EXIT_T" ] && [ "$EXIT_T" = "$END_L" ]; then
    report T20 "True branch skips false branch" \
           "then-exit goto->end@$END_L" "exit goto->$EXIT_T (label resolved)" 0
else
    report T20 "True branch skips false branch" "then-exit goto->end" \
           "EXIT_T=$EXIT_T END@$END_L $(diag)" 1
fi

# T21 - nested control flow: many distinct label targets, none unresolved
run_compiler examples/nested_if_else.src
DISTINCT=$(printf '%s\n' "$OUT" | grep -oE 'goto L[0-9]+' | sort -u | wc -l)
if [ "$RC" -eq 0 ] && [ "$DISTINCT" -ge 5 ] \
   && ! printf '%s' "$OUT" | grep -q 'goto ?'; then
    report T21 "Nested control flow, multiple targets" \
           ">=5 distinct label targets, none unresolved" \
           "$DISTINCT distinct label targets" 0
else
    report T21 "Nested control flow, multiple targets" ">=5 distinct" \
           "$DISTINCT distinct, $(diag)" 1
fi

# T22 - division by zero as source syntax (never evaluated at compile time)
run_compiler tests/cases/div_zero.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a / 0'; then
    report T22 "Division by zero (syntax only)" \
           "accepted, TAC contains a / 0 (not evaluated)" \
           "exit 0, TAC generated" 0
else
    report T22 "Division by zero (syntax only)" "accepted as expression" \
           "$(diag)" 1
fi

# T23 (extra) - parenthesised condition
run_compiler tests/cases/paren_condition.src
if [ "$RC" -eq 0 ] && [ "$(line_no 'if a < b goto')" -gt 0 ]; then
    report T23 "Parenthesised condition (extra)" "exit 0, if generated" \
           "exit 0" 0
else
    report T23 "Parenthesised condition (extra)" "exit 0" "$(diag)" 1
fi

# T24 (extra) - unary minus
run_compiler tests/cases/unary_minus.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= 0 - a'; then
    report T24 "Unary minus (extra)" "compiled as 0 - a" \
           "exit 0, 0 - a present" 0
else
    report T24 "Unary minus (extra)" "compiled as 0 - a" "$(diag)" 1
fi

# T25 (new) - label integrity on two programs: the set of labels
# defined at instruction lines equals the set of labels referenced
# by gotos; no duplicates; no numeric or unresolved goto remains.
LABEL_OK=1
LABEL_DETAIL=""
for SRC in examples/if_else.src examples/nested_simple.src; do
    run_compiler "$SRC"
    if [ "$RC" -ne 0 ]; then LABEL_OK=0; LABEL_DETAIL="$SRC rc=$RC"; break; fi
    DEFINED=$(printf '%s\n' "$OUT" | grep -oE '^L[0-9]+' | sort)
    DEF_U=$(printf '%s\n' "$DEFINED" | sort -u | wc -l)
    DEF_N=$(printf '%s\n' "$DEFINED" | grep -c . || true)
    REFED=$(printf '%s\n' "$OUT" | grep -oE 'goto L[0-9]+' | sed 's/goto //' | sort -u)
    if [ "$DEF_U" -ne "$DEF_N" ]; then LABEL_OK=0; LABEL_DETAIL="$SRC duplicate labels"; break; fi
    if [ "$(printf '%s\n' "$DEFINED" | sort -u)" != "$REFED" ]; then
        LABEL_OK=0; LABEL_DETAIL="$SRC defined!=referenced"; break
    fi
    if printf '%s\n' "$OUT" | grep -Eq 'goto [0-9]|goto \?'; then
        LABEL_OK=0; LABEL_DETAIL="$SRC numeric/unresolved goto remains"; break
    fi
    LABEL_DETAIL="$SRC labels consistent"
done
if [ "$LABEL_OK" -eq 1 ]; then
    report T25 "Label integrity (new)" \
           "defined labels == referenced labels, unique, no numeric goto" \
           "$LABEL_DETAIL" 0
else
    report T25 "Label integrity (new)" "labels consistent" "$LABEL_DETAIL" 1
fi

# T26 (new) - missing expression is a syntax error
expect_error T26 "Missing expression (new)" tests/cases/missing_expression.src \
             'Syntax error at line [0-9]+'

# T27 (new) - malformed conditional (missing '(') is a syntax error
expect_error T27 "Malformed conditional (new)" tests/cases/malformed_if.src \
             'Syntax error at line [0-9]+'

# T28 (new) - all jumps in this language are FORWARD references
# (there are no loops), every target resolves past its own line, and
# the last instruction is the end marker.
run_compiler examples/nested_simple.src
FWD_OK=1
FWD_DETAIL=""
N="$(instr_count)"
if [ "$RC" -ne 0 ] || [ "$N" -eq 0 ]; then
    FWD_OK=0; FWD_DETAIL="no TAC produced"
else
    for (( i = 1; i <= N; i++ )); do
        T="$(target_seq "$i")"
        if [ -n "$T" ] && [ "$T" -le "$i" ]; then
            FWD_OK=0; FWD_DETAIL="instruction $i jumps backward/sideways to $T"
        fi
    done
    if [ "${INSTR_TEXT[$((N - 1))]}" != "end" ]; then
        FWD_OK=0; FWD_DETAIL="last instruction is not 'end'"
    fi
    [ "$FWD_OK" -eq 1 ] && FWD_DETAIL="all targets forward, ends with 'end'"
fi
if [ "$FWD_OK" -eq 1 ]; then
    report T28 "Forward jumps + end marker (new)" \
           "every goto target > its own line; last instruction 'end'" \
           "$FWD_DETAIL" 0
else
    report T28 "Forward jumps + end marker (new)" "forward jumps + end" \
           "$FWD_DETAIL $(diag)" 1
fi

echo "======================================================"
echo "Tests passed: $PASS_COUNT, failed: $FAIL_COUNT, total: $((PASS_COUNT + FAIL_COUNT))"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "SOME TESTS FAILED"
exit 1
