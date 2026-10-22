/*
 * parser.y - Bison grammar with syntax-directed translation and
 *            genuine backpatching for if / if-else statements.
 *
 * Grammar (see README.md for the same grammar in readable form):
 *
 *   program    -> stmt_list
 *   stmt_list  -> stmt_list M stmt | stmt
 *   stmt       -> matched | unmatched
 *   matched    -> IF ( bool ) M matched N ELSE M matched
 *               | { stmt_list } | { }
 *               | ID = expr ;
 *   unmatched  -> IF ( bool ) M stmt
 *               | IF ( bool ) M matched N ELSE M unmatched
 *   bool       -> expr relop expr | ( bool )
 *   expr       -> expr + expr | expr - expr | expr * expr | expr / expr
 *               | - expr | ( expr ) | ID | NUM
 *   M          -> <empty>   { $$ = nextinstr(); }
 *   N          -> <empty>   { emit an unresolved goto; $$ = makelist of it }
 *
 * The matched/unmatched split is the standard textbook solution to
 * the dangling-else problem: an "else" always belongs to the nearest
 * unmatched "if", and this grammar produces ZERO shift/reduce and
 * ZERO reduce/reduce conflicts (see the bison report in the build
 * log / parser.output when built with `make debug`).
 *
 * Backpatching summary:
 *   - bool emits "if a < b goto ?" (truelist) and "goto ?" (falselist)
 *     with genuinely unresolved targets (-1).
 *   - IF rule: backpatch(truelist, M before then-branch),
 *              backpatch(falselist, M before else-branch / after if).
 *   - N emits the exit jump of the then-branch; its list is merged
 *     into the statement's nextlist and patched by the enclosing
 *     context (sequence marker M, or main() at the "end" marker).
 */
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tac.h"

int yylex(void);
void yyerror(const char *s);

extern int lex_line;         /* from lexer.l */
extern int lex_error_count;  /* from lexer.l */
int syntax_error_count = 0;  /* incremented in yyerror() */

/* nextlist of the whole program; main() patches it to the end marker. */
List program_nextlist = NULL;

static BoolAttr make_bool(const char *relop, ExprAttr left, ExprAttr right)
{
    BoolAttr b;
    /* Conditional jump with unresolved target -> truelist. */
    b.truelist = makelist(nextinstr());
    emit_if(relop, left.place, right.place, TARGET_UNRESOLVED);
    /* Unconditional jump with unresolved target -> falselist. */
    b.falselist = makelist(nextinstr());
    emit_goto(TARGET_UNRESOLVED);
    free(left.place);
    free(right.place);
    return b;
}

static char *make_arith(const char *op, ExprAttr left, ExprAttr right)
{
    char *temp = newtemp();
    emit_arith(op, left.place, right.place, temp);
    free(left.place);
    free(right.place);
    return temp;
}
%}

%define parse.error verbose

%union {
    char *sval;
    ExprAttr expr;
    BoolAttr boolean;
    StmtAttr stmt;
    int instr;
    List list;
}

%token IF ELSE
%token <sval> ID NUM
%token LE GE EQ NE

%type <expr> expr
%type <boolean> bool
%type <stmt> stmt matched unmatched stmt_list
%type <instr> M
%type <list> N

%left '+' '-'
%left '*' '/'
%right UMINUS

%start program

%%

program
    : stmt_list                 { program_nextlist = $1.nextlist; }
    ;

stmt_list
    : stmt_list M stmt
        {
            /* Whatever jumped to "after the previous statement" now
             * lands on the first instruction of the next statement. */
            backpatch($1.nextlist, $2);
            $$.nextlist = $3.nextlist;
        }
    | stmt                      { $$.nextlist = $1.nextlist; }
    ;

stmt
    : matched                   { $$.nextlist = $1.nextlist; }
    | unmatched                 { $$.nextlist = $1.nextlist; }
    ;

matched
    : IF '(' bool ')' M matched N ELSE M matched
        {
            backpatch($3.truelist, $5);   /* true  -> then-branch  */
            backpatch($3.falselist, $9);  /* false -> else-branch  */
            $$.nextlist = merge($6.nextlist,
                                merge($7, $10.nextlist));
        }
    | '{' stmt_list '}'         { $$.nextlist = $2.nextlist; }
    | '{' '}'                   { $$.nextlist = NULL; }
    | ID '=' expr ';'
        {
            emit_assign($1, $3.place);
            free($1);
            free($3.place);
            $$.nextlist = NULL;
        }
    ;

unmatched
    : IF '(' bool ')' M stmt
        {
            backpatch($3.truelist, $5);   /* true  -> then-branch  */
            /* false -> whatever follows the if: stays in nextlist */
            $$.nextlist = merge($3.falselist, $6.nextlist);
        }
    | IF '(' bool ')' M matched N ELSE M unmatched
        {
            backpatch($3.truelist, $5);   /* true  -> then-branch  */
            backpatch($3.falselist, $9);  /* false -> else-branch  */
            $$.nextlist = merge($6.nextlist,
                                merge($7, $10.nextlist));
        }
    ;

bool
    : expr '<' expr             { $$ = make_bool("<",  $1, $3); }
    | expr '>' expr             { $$ = make_bool(">",  $1, $3); }
    | expr LE expr              { $$ = make_bool("<=", $1, $3); }
    | expr GE expr              { $$ = make_bool(">=", $1, $3); }
    | expr EQ expr              { $$ = make_bool("==", $1, $3); }
    | expr NE expr              { $$ = make_bool("!=", $1, $3); }
    | '(' bool ')'              { $$ = $2; }
    ;

expr
    : expr '+' expr             { $$.place = make_arith("+", $1, $3); }
    | expr '-' expr             { $$.place = make_arith("-", $1, $3); }
    | expr '*' expr             { $$.place = make_arith("*", $1, $3); }
    | expr '/' expr             { $$.place = make_arith("/", $1, $3); }
    | '-' expr %prec UMINUS
        {
            char *temp = newtemp();
            emit_arith("-", "0", $2.place, temp);
            free($2.place);
            $$.place = temp;
        }
    | '(' expr ')'              { $$.place = $2.place; }
    | ID                        { $$.place = $1; }
    | NUM                       { $$.place = $1; }
    ;

M
    : /* empty */               { $$ = nextinstr(); }
    ;

N
    : /* empty */
        {
            /* Exit jump of a then-branch, target not yet known. */
            $$ = makelist(nextinstr());
            emit_goto(TARGET_UNRESOLVED);
        }
    ;

%%

void yyerror(const char *s)
{
    fprintf(stderr, "Syntax error at line %d: %s\n", lex_line, s);
    syntax_error_count++;
}
