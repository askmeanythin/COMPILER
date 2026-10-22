#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tac.h"

int tac_trace = 0;

static Instruction code[MAX_INSTRUCTIONS];
static int code_count = 0;
static int temp_count = 0;


static int label_of[MAX_INSTRUCTIONS];
static int label_count = 0;

static void assign_labels(void)
{
    for (int i = 0; i < code_count; i++)
        label_of[i] = 0;
    label_count = 0;
    for (int i = 0; i < code_count; i++) {
        if ((code[i].kind == KIND_IF || code[i].kind == KIND_GOTO) &&
            code[i].target >= 0 && code[i].target < code_count &&
            label_of[code[i].target] == 0) {
            label_of[code[i].target] = ++label_count;
        }
    }
}

int nextinstr(void)
{
    return code_count;
}

int instr_count(void)
{
    return code_count;
}

const Instruction *get_instr(int index)
{
    if (index < 0 || index >= code_count)
        return NULL;
    return &code[index];
}

static int emit_common(InstrKind kind)
{
    if (code_count >= MAX_INSTRUCTIONS) {
        fprintf(stderr, "Internal error: too many TAC instructions\n");
        exit(1);
    }
    Instruction *ins = &code[code_count];
    memset(ins, 0, sizeof(*ins));
    ins->kind = kind;
    ins->target = TARGET_UNRESOLVED;
    return code_count++;
}

static void trace_emit(int index)
{
    if (tac_trace) {
        char buf[512];
        format_instr(&code[index], buf, sizeof(buf));
        printf("TRACE: emitted instruction %d: %s\n", index + 1, buf);
    }
}

int emit_assign(const char *result, const char *arg1)
{
    int i = emit_common(KIND_ASSIGN);
    snprintf(code[i].result, sizeof(code[i].result), "%s", result);
    snprintf(code[i].arg1, sizeof(code[i].arg1), "%s", arg1);
    trace_emit(i);
    return i;
}

int emit_arith(const char *op, const char *arg1, const char *arg2,
               const char *result)
{
    int i = emit_common(KIND_ARITH);
    snprintf(code[i].op, sizeof(code[i].op), "%s", op);
    snprintf(code[i].arg1, sizeof(code[i].arg1), "%s", arg1);
    snprintf(code[i].arg2, sizeof(code[i].arg2), "%s", arg2);
    snprintf(code[i].result, sizeof(code[i].result), "%s", result);
    trace_emit(i);
    return i;
}

int emit_if(const char *relop, const char *arg1, const char *arg2,
            int target)
{
    int i = emit_common(KIND_IF);
    snprintf(code[i].op, sizeof(code[i].op), "%s", relop);
    snprintf(code[i].arg1, sizeof(code[i].arg1), "%s", arg1);
    snprintf(code[i].arg2, sizeof(code[i].arg2), "%s", arg2);
    code[i].target = target;
    if (tac_trace && target == TARGET_UNRESOLVED)
        printf("TRACE: instruction %d has UNRESOLVED target\n", i + 1);
    trace_emit(i);
    return i;
}

int emit_goto(int target)
{
    int i = emit_common(KIND_GOTO);
    code[i].target = target;
    if (tac_trace && target == TARGET_UNRESOLVED)
        printf("TRACE: instruction %d has UNRESOLVED target\n", i + 1);
    trace_emit(i);
    return i;
}

int emit_end(void)
{
    int i = emit_common(KIND_END);
    code[i].target = -2; /* not a jump */
    trace_emit(i);
    return i;
}

char *newtemp(void)
{
    char buf[32];
    snprintf(buf, sizeof(buf), "t%d", ++temp_count);
    return strdup(buf);
}

/* ---------------- Backpatching primitives ---------------- */

List makelist(int index)
{
    ListNode *node = (ListNode *)malloc(sizeof(ListNode));
    if (node == NULL) {
        fprintf(stderr, "Internal error: out of memory\n");
        exit(1);
    }
    node->index = index;
    node->next = NULL;
    if (tac_trace)
        printf("TRACE: makelist(%d) -> list {%d}\n", index + 1, index + 1);
    return node;
}

static void trace_list(List p)
{
    printf("{");
    int first = 1;
    for (ListNode *n = p; n != NULL; n = n->next) {
        printf("%s%d", first ? "" : ",", n->index + 1);
        first = 0;
    }
    printf("}");
}

List merge(List p1, List p2)
{
    if (tac_trace && !(p1 == NULL && p2 == NULL)) {
        printf("TRACE: merge(");
        trace_list(p1);
        printf(", ");
        trace_list(p2);
        printf(")\n");
    }
    if (p1 == NULL)
        return p2;
    if (p2 == NULL)
        return p1;
    ListNode *tail = p1;
    while (tail->next != NULL)
        tail = tail->next;
    tail->next = p2;
    return p1;
}

void backpatch(List p, int target)
{
    if (tac_trace && p != NULL) {
        printf("TRACE: backpatch(list ");
        trace_list(p);
        printf(", target %d)\n", target + 1);
    }
    /* Fill the target of every instruction in the list, then free
     * the list nodes: backpatch() consumes (owns) the list.        */
    while (p != NULL) {
        ListNode *next = p->next;
        if (p->index < 0 || p->index >= code_count) {
            fprintf(stderr,
                    "Internal error: backpatch index %d out of range\n",
                    p->index + 1);
            exit(1);
        }
        code[p->index].target = target;
        if (tac_trace) {
            char buf[512];
            format_instr(&code[p->index], buf, sizeof(buf));
            printf("TRACE:   instruction %d is now: %s\n",
                   p->index + 1, buf);
        }
        free(p);
        p = next;
    }
}

/* ---------------- Validation ---------------- */

int validate_tac(void)
{
    int errors = 0;

    /* The program must end with the end marker, so that every label
     * and jump target refers to a real instruction.                 */
    if (code_count == 0 || code[code_count - 1].kind != KIND_END) {
        fprintf(stderr,
                "Validation error: program does not end with an "
                "'end' instruction\n");
        errors++;
    }

    /* Label checks: compute the label assignment, then require that
     * every jump target received exactly one label (assign_labels
     * gives each distinct target a unique label, so a jump whose
     * target has label 0 would mean the mapping is inconsistent),
     * and that the labels in use are exactly L1..L<label_count>.    */
    assign_labels();
    {
        int seen[MAX_INSTRUCTIONS];
        for (int i = 0; i < code_count; i++)
            seen[i] = 0;
        for (int i = 0; i < code_count; i++) {
            if (label_of[i] > 0) {
                if (label_of[i] > label_count || seen[label_of[i]]) {
                    fprintf(stderr,
                            "Validation error: duplicate or invalid "
                            "label L%d\n",
                            label_of[i]);
                    errors++;
                }
                seen[label_of[i]] = 1;
            }
        }
        for (int i = 0; i < code_count; i++) {
            Instruction *ins = &code[i];
            if ((ins->kind == KIND_IF || ins->kind == KIND_GOTO) &&
                ins->target >= 0 && ins->target < code_count &&
                label_of[ins->target] == 0) {
                fprintf(stderr,
                        "Validation error: instruction %d jumps to "
                        "instruction %d, which has no label\n",
                        i + 1, ins->target + 1);
                errors++;
            }
        }
    }

    for (int i = 0; i < code_count; i++) {
        Instruction *ins = &code[i];
        switch (ins->kind) {
        case KIND_IF:
        case KIND_GOTO:
            if (ins->target == TARGET_UNRESOLVED) {
                fprintf(stderr,
                        "Validation error: instruction %d is an "
                        "unpatched jump\n",
                        i + 1);
                errors++;
            } else if (ins->target < 0 || ins->target >= code_count) {
                fprintf(stderr,
                        "Validation error: instruction %d jumps to "
                        "invalid target %d\n",
                        i + 1, ins->target + 1);
                errors++;
            }
            if (ins->kind == KIND_IF &&
                (ins->arg1[0] == '\0' || ins->arg2[0] == '\0' ||
                 ins->op[0] == '\0')) {
                fprintf(stderr,
                        "Validation error: instruction %d is a "
                        "malformed conditional jump\n",
                        i + 1);
                errors++;
            }
            break;
        case KIND_ASSIGN:
            if (ins->result[0] == '\0' || ins->arg1[0] == '\0') {
                fprintf(stderr,
                        "Validation error: instruction %d is a "
                        "malformed assignment\n",
                        i + 1);
                errors++;
            }
            break;
        case KIND_ARITH:
            if (ins->result[0] == '\0' || ins->arg1[0] == '\0' ||
                ins->arg2[0] == '\0' || ins->op[0] == '\0') {
                fprintf(stderr,
                        "Validation error: instruction %d is a "
                        "malformed arithmetic operation\n",
                        i + 1);
                errors++;
            }
            break;
        case KIND_END:
            break;
        }
    }
    return errors;
}

/* ---------------- Printing ---------------- */

void format_instr(const Instruction *ins, char *buf, unsigned long bufsize)
{
    switch (ins->kind) {
    case KIND_ASSIGN:
        snprintf(buf, bufsize, "%s = %s", ins->result, ins->arg1);
        break;
    case KIND_ARITH:
        snprintf(buf, bufsize, "%s = %s %s %s", ins->result, ins->arg1,
                 ins->op, ins->arg2);
        break;
    case KIND_IF:
        if (ins->target == TARGET_UNRESOLVED)
            snprintf(buf, bufsize, "if %s %s %s goto ?", ins->arg1,
                     ins->op, ins->arg2);
        else if (ins->target >= 0 && ins->target < code_count &&
                 label_of[ins->target] > 0)
            snprintf(buf, bufsize, "if %s %s %s goto L%d", ins->arg1,
                     ins->op, ins->arg2, label_of[ins->target]);
        else
            snprintf(buf, bufsize, "if %s %s %s goto %d", ins->arg1,
                     ins->op, ins->arg2, ins->target + 1);
        break;
    case KIND_GOTO:
        if (ins->target == TARGET_UNRESOLVED)
            snprintf(buf, bufsize, "goto ?");
        else if (ins->target >= 0 && ins->target < code_count &&
                 label_of[ins->target] > 0)
            snprintf(buf, bufsize, "goto L%d", label_of[ins->target]);
        else
            snprintf(buf, bufsize, "goto %d", ins->target + 1);
        break;
    case KIND_END:
        snprintf(buf, bufsize, "end");
        break;
    default:
        snprintf(buf, bufsize, "<bad instruction>");
        break;
    }
}

void print_tac(void)
{
    char buf[512];
    assign_labels();
    printf("Three Address Code:\n");
    for (int i = 0; i < code_count; i++) {
        format_instr(&code[i], buf, sizeof(buf));

        if (label_of[i] > 0)
            printf("L%d: %s\n", label_of[i], buf);
        else
            printf("%d: %s\n", i + 1, buf);
    }
}
