#!/usr/bin/env bash
#
# test_compiler.sh - automated test suite for the if-else compiler.
#
# Every test runs the real compiler, checks the exit code AND the
# generated TAC (instruction contents and jump targets), and prints:
#   Test ID | Purpose | Expected | Actual | PASS/FAIL
# The suite exits non-zero if any test fails.
#
# Note: the compiler itself validates the TAC (no unpatched jumps,
# all targets in range) before printing it, so a successful run with
# exit code 0 already implies the validator passed. Several tests
# additionally verify the exact branch structure by following the
# numbered instructions and their goto targets.

set -u
cd "$(dirname "$0")/.."
COMPILER="./compiler"

PASS_COUNT=0
FAIL_COUNT=0
declare -a TAC_LINES=()
RC=0
OUT=""
ERR=""

run_compiler() { # $1 = source file
    OUT="$("$COMPILER" "$1" 2>/tmp/_test_err.txt)"
    RC=$?
    ERR="$(cat /tmp/_test_err.txt)"
    TAC_LINES=()
    while IFS= read -r line; do
        TAC_LINES+=("$line")
    done < <(printf '%s\n' "$OUT" | grep -E '^[0-9]+: ' || true)
}

# line_no <regex> : display number (1-based) of first matching TAC line
line_no() {
    local i
    for i in "${!TAC_LINES[@]}"; do
        if printf '%s' "${TAC_LINES[$i]}" | grep -Eq "$1"; then
            echo $((i + 1))
            return 0
        fi
    done
    echo 0
}

# target_of <display number> : goto target on that line, or empty
target_of() {
    local idx=$(($1 - 1))
    printf '%s' "${TAC_LINES[$idx]}" | sed -nE 's/.*goto ([0-9]+).*/\1/p'
}

# text_at <display number> : instruction text without the number
text_at() {
    local idx=$(($1 - 1))
    printf '%s' "${TAC_LINES[$idx]}" | sed -E 's/^[0-9]+: //'
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

# T01 - simple assignment (examples/assignment.src)
run_compiler examples/assignment.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'total = a' \
   && printf '%s' "$OUT" | grep -q 'count = total'; then
    report T01 "Simple assignment" "exit 0, plain copy assignments" \
           "exit 0, assignments found" 0
else
    report T01 "Simple assignment" "exit 0, plain copy assignments" \
           "exit=$RC" 1
fi

# T02 - addition and subtraction
run_compiler tests/cases/add_sub.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a \+ b' \
   && printf '%s' "$OUT" | grep -Eq '= a - b'; then
    report T02 "Addition and subtraction" "temps for a+b and a-b" \
           "both present" 0
else
    report T02 "Addition and subtraction" "temps for a+b and a-b" \
           "exit=$RC" 1
fi

# T03 - operator precedence: b*c evaluated before a+... for p,
#        while explicit parentheses make (a+b) evaluated first for r.
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
           "mul@$L_MUL add@$L_ADD padd@$L_PAREN_ADD pmul@$L_PAREN_MUL rc=$RC" 1
fi

# T04 - multiplication and division
run_compiler tests/cases/mul_div.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a \* b' \
   && printf '%s' "$OUT" | grep -Eq '= a / b'; then
    report T04 "Multiplication and division" "temps for a*b and a/b" \
           "both present" 0
else
    report T04 "Multiplication and division" "temps for a*b and a/b" \
           "exit=$RC" 1
fi

# T05 - simple if: condition true -> then stmt, false -> after the if
run_compiler examples/simple_if.src
IF_L=$(line_no 'if a < b goto')
THEN_L=$(line_no 'c = 1')
AFTER_L=$(line_no 'd = 2')
T_IF=$(target_of "$IF_L")
T_FALSE=$(target_of $((IF_L + 1)))
if [ "$RC" -eq 0 ] && [ "$T_IF" = "$THEN_L" ] && [ "$T_FALSE" = "$AFTER_L" ]; then
    report T05 "Simple if" "if->$THEN_L (then), goto->$AFTER_L (after)" \
           "if->$T_IF, goto->$T_FALSE" 0
else
    report T05 "Simple if" "if target=then line, false target=after line" \
           "if->$T_IF goto->$T_FALSE then@$THEN_L after@$AFTER_L rc=$RC" 1
fi

# T06 - if-else structure: both branches present with correct contents
run_compiler examples/if_else.src
IF_L=$(line_no 'if a < b goto')
THEN_L=$(line_no '= a \+ b')
ELSE_L=$(line_no '= a - b')
if [ "$RC" -eq 0 ] && [ "$IF_L" -gt 0 ] && [ "$THEN_L" -gt "$IF_L" ] \
   && [ "$ELSE_L" -gt "$THEN_L" ]; then
    report T06 "If-else structure" "then-branch (+ ) before else-branch (-)" \
           "if@$IF_L then@$THEN_L else@$ELSE_L" 0
else
    report T06 "If-else structure" "then before else" \
           "if@$IF_L then@$THEN_L else@$ELSE_L rc=$RC" 1
fi

# T07 - nested if-else: outer branches reach the two inner ifs, and
#        inner then-branches exit to the statement after the outer if
run_compiler examples/nested_if_else.src
O_IF=$(line_no 'if a < b goto')
O_ELSE_IF=$(line_no 'if a == c goto')
DONE_L=$(line_no 'done = result')
T_O=$(target_of "$O_IF")
T_O_FALSE=$(target_of $((O_IF + 1)))
EXIT1=$(target_of $(( $(line_no 'result = 1') + 1 )))
EXIT2=$(target_of $(( $(line_no 'result = 3') + 1 )))
I1_IF=$(line_no 'if b > c goto')
if [ "$RC" -eq 0 ] && [ "$T_O" = "$I1_IF" ] && [ "$T_O_FALSE" = "$O_ELSE_IF" ] \
   && [ "$EXIT1" = "$DONE_L" ] && [ "$EXIT2" = "$DONE_L" ]; then
    report T07 "Nested if-else targets" \
           "outer true->inner1@$I1_IF, outer false->inner2@$O_ELSE_IF, exits->done@$DONE_L" \
           "true->$T_O false->$T_O_FALSE exits->$EXIT1,$EXIT2" 0
else
    report T07 "Nested if-else targets" "nested targets as documented" \
           "T_O=$T_O T_O_FALSE=$T_O_FALSE EXIT=$EXIT1,$EXIT2 rc=$RC" 1
fi

# T08 - multiple statements in blocks
run_compiler examples/multiple_statements.src
SKIP_T=$(target_of $(( $(line_no 'c = t') + 1 )))
AFTER_L=$(line_no '= c \+ 1')
if [ "$RC" -eq 0 ] && [ "$(line_no 'a = t')" -gt 0 ] \
   && [ "$(line_no 'b = t')" -gt 0 ] && [ "$(line_no 'c = 0')" -gt 0 ] \
   && [ "$SKIP_T" = "$AFTER_L" ]; then
    report T08 "Multiple statements in blocks" \
           "3 then-stmts + 3 else-stmts, skip goto->after@$AFTER_L" \
           "skip->$SKIP_T" 0
else
    report T08 "Multiple statements in blocks" "block statements + skip" \
           "skip=$SKIP_T after@$AFTER_L rc=$RC" 1
fi

# T09 - sequential conditionals: first if's false jump lands on the
#        second if, and control continues after both
run_compiler examples/sequential_if.src
IF1=$(line_no 'if a < b goto')
IF2=$(line_no 'if b > a goto')
F1=$(target_of $((IF1 + 1)))
if [ "$RC" -eq 0 ] && [ "$F1" = "$IF2" ] && [ "$IF2" -gt "$IF1" ]; then
    report T09 "Sequential conditionals" "if1 false->if2@$IF2" \
           "if1 false->$F1" 0
else
    report T09 "Sequential conditionals" "if1 false->if2" \
           "F1=$F1 IF2=$IF2 rc=$RC" 1
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
           "$OK found, rc=$RC" 1
fi

# T11 - empty blocks are supported and produce valid control flow
run_compiler tests/cases/empty_block.src
if [ "$RC" -eq 0 ] && [ "$(line_no 'c = 3')" -gt 0 ] \
   && ! printf '%s' "$OUT" | grep -q 'goto ?'; then
    report T11 "Empty blocks" "exit 0, no unpatched jumps" \
           "exit 0, valid TAC" 0
else
    report T11 "Empty blocks" "exit 0, no unpatched jumps" \
           "exit=$RC" 1
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

# T18 - dangling else binds to the NEAREST if: inner false -> x = 2,
#        outer false -> end (skipping the whole inner statement)
run_compiler tests/cases/dangling_else.src
O_IF=$(line_no 'if a < b goto')
I_IF=$(line_no 'if c < d goto')
X2_L=$(line_no 'x = 2')
END_L=$(line_no 'end')
O_FALSE=$(target_of $((O_IF + 1)))
I_FALSE=$(target_of $((I_IF + 1)))
I_TRUE=$(target_of "$I_IF")
if [ "$RC" -eq 0 ] && [ "$I_FALSE" = "$X2_L" ] && [ "$O_FALSE" = "$END_L" ] \
   && [ "$I_TRUE" = "$(line_no 'x = 1')" ]; then
    report T18 "Dangling-else association" \
           "inner false->x=2@$X2_L, outer false->end@$END_L" \
           "inner false->$I_FALSE, outer false->$O_FALSE" 0
else
    report T18 "Dangling-else association" "else binds to inner if" \
           "I_FALSE=$I_FALSE O_FALSE=$O_FALSE X2@$X2_L END@$END_L rc=$RC" 1
fi

# T19 - false condition skips the true branch (falselist target = else)
run_compiler examples/if_else.src
IF_L=$(line_no 'if a < b goto')
ELSE_L=$(line_no '= a - b')
FALSE_T=$(target_of $((IF_L + 1)))
if [ "$RC" -eq 0 ] && [ "$FALSE_T" = "$ELSE_L" ]; then
    report T19 "False condition skips true branch" \
           "false goto->else@$ELSE_L" "false goto->$FALSE_T" 0
else
    report T19 "False condition skips true branch" "false goto->else" \
           "FALSE_T=$FALSE_T ELSE@$ELSE_L rc=$RC" 1
fi

# T20 - true branch skips the false branch (exit goto after then-part
#        jumps over the else-part to the end marker)
run_compiler examples/if_else.src
ELSE_FIRST=$(line_no '= a - b')
END_L=$(line_no 'end')
EXIT_T=$(target_of $((ELSE_FIRST - 1)))
if [ "$RC" -eq 0 ] && [ "$EXIT_T" = "$END_L" ]; then
    report T20 "True branch skips false branch" \
           "then-exit goto->end@$END_L" "exit goto->$EXIT_T" 0
else
    report T20 "True branch skips false branch" "then-exit goto->end" \
           "EXIT_T=$EXIT_T END@$END_L rc=$RC" 1
fi

# T21 - nested control flow: many distinct, in-range jump targets,
#        no unresolved placeholders anywhere (validator also enforces)
run_compiler examples/nested_if_else.src
DISTINCT=$(printf '%s\n' "${TAC_LINES[@]}" | grep -oE 'goto [0-9]+' \
           | sort -u | wc -l)
if [ "$RC" -eq 0 ] && [ "$DISTINCT" -ge 5 ] \
   && ! printf '%s' "$OUT" | grep -q 'goto ?'; then
    report T21 "Nested control flow, multiple targets" \
           ">=5 distinct targets, none unresolved" \
           "$DISTINCT distinct targets" 0
else
    report T21 "Nested control flow, multiple targets" ">=5 distinct" \
           "$DISTINCT distinct, rc=$RC" 1
fi

# T22 - division by zero as source syntax: the compiler generates TAC
#        for it (it does NOT evaluate expressions at compile time, so
#        no compile-time division happens and nothing crashes).
run_compiler tests/cases/div_zero.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= a / 0'; then
    report T22 "Division by zero (syntax only)" \
           "accepted, TAC contains a / 0 (not evaluated)" \
           "exit 0, TAC generated" 0
else
    report T22 "Division by zero (syntax only)" "accepted as expression" \
           "exit=$RC" 1
fi

# T23 (extra) - parenthesised condition
run_compiler tests/cases/paren_condition.src
if [ "$RC" -eq 0 ] && [ "$(line_no 'if a < b goto')" -gt 0 ]; then
    report T23 "Parenthesised condition (extra)" "exit 0, if generated" \
           "exit 0" 0
else
    report T23 "Parenthesised condition (extra)" "exit 0" "exit=$RC" 1
fi

# T24 (extra) - unary minus
run_compiler tests/cases/unary_minus.src
if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -Eq '= 0 - a'; then
    report T24 "Unary minus (extra)" "compiled as 0 - a" \
           "exit 0, 0 - a present" 0
else
    report T24 "Unary minus (extra)" "compiled as 0 - a" "exit=$RC" 1
fi

echo "======================================================"
echo "Tests passed: $PASS_COUNT, failed: $FAIL_COUNT, total: $((PASS_COUNT + FAIL_COUNT))"
if [ "$FAIL_COUNT" -eq 0 ]; then
    echo "ALL TESTS PASSED"
    exit 0
fi
echo "SOME TESTS FAILED"
exit 1
