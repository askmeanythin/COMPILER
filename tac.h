/*
 * tac.h - Three Address Code (TAC) representation and backpatching.
 *
 * Project: Simple Compiler Supporting If-Else Statements using
 *          Lexical Analysis, Parsing, Syntax-Directed Translation
 *          and Backpatching for Three Address Code Generation.
 *
 * Index convention (documented, used consistently everywhere):
 *   - Internally, instructions are indexed from 0 (C array index).
 *   - When TAC is displayed, instruction numbers start from 1.
 *   - A jump target stored internally as T is displayed as T+1.
 *   - An unresolved jump has target == TARGET_UNRESOLVED (-1).
 *   - The last instruction emitted for a successful program is a
 *     KIND_END marker ("end"), so every valid jump target satisfies
 *     0 <= target < instruction_count.
 */
#ifndef TAC_H
#define TAC_H

#define MAX_INSTRUCTIONS 4096
#define TARGET_UNRESOLVED (-1)

/* Kinds of TAC instructions. */
typedef enum {
    KIND_ASSIGN, /* result = arg1                                  */
    KIND_ARITH,  /* result = arg1 op arg2   (op in + - * /)        */
    KIND_IF,     /* if arg1 op arg2 goto target  (op is relop)     */
    KIND_GOTO,   /* goto target                                    */
    KIND_END     /* end  (program termination marker)              */
} InstrKind;

typedef struct {
    InstrKind kind;
    char op[16];     /* arithmetic operator or relational operator   */
    char arg1[128];
    char arg2[128];
    char result[128];
    int target;      /* jump target (internal 0-based); -1 = unset   */
} Instruction;

/* A patch list: linked list of instruction indexes whose jump target
 * is not yet known and must be filled in later by backpatch().       */
typedef struct ListNode {
    int index; /* internal instruction index */
    struct ListNode *next;
} ListNode;
typedef ListNode *List;

/* Semantic attribute records used by the Bison grammar. */
typedef struct {
    char *place; /* heap-allocated name: identifier, constant or temp */
} ExprAttr;

typedef struct {
    List truelist;  /* jumps to fill with the "condition true" target  */
    List falselist; /* jumps to fill with the "condition false" target */
} BoolAttr;

typedef struct {
    List nextlist; /* jumps to fill with the instruction after the stmt */
} StmtAttr;

/* Set to 1 to enable the backpatching trace (compiler --trace). */
extern int tac_trace;

/* Number of instructions emitted so far; also the index of the next
 * instruction that emit() will create.                               */
int nextinstr(void);
int instr_count(void);
const Instruction *get_instr(int index);

/* emit() functions: append an instruction, return its internal index. */
int emit_assign(const char *result, const char *arg1);
int emit_arith(const char *op, const char *arg1, const char *arg2,
               const char *result);
int emit_if(const char *relop, const char *arg1, const char *arg2,
            int target);
int emit_goto(int target);
int emit_end(void);

/* Backpatching primitives (the heart of this project). */
List makelist(int index);
List merge(List p1, List p2);
void backpatch(List p, int target);

/* Fresh temporary name (t1, t2, ...). Heap allocated; caller owns it. */
char *newtemp(void);

/* Validate all instructions; returns number of validation errors and
 * prints a message for each problem found to stderr.                 */
int validate_tac(void);

/* Print the final TAC, numbered from 1, to stdout. */
void print_tac(void);

/* Human-readable description of one instruction into buf. */
void format_instr(const Instruction *ins, char *buf, unsigned long bufsize);

#endif /* TAC_H */
