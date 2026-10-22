#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tac.h"
#include "parser.tab.h"

int yyparse(void);
int yylex(void);
int yylex_destroy(void);
extern FILE *yyin;
extern char *yytext;

extern int lex_line;         /* from lexer.l */
extern int lex_error_count;  /* from lexer.l */
extern int syntax_error_count; /* from parser.y */
extern List program_nextlist;  /* from parser.y */

static const char *token_name(int tok)
{
    switch (tok) {
    case IF:   return "IF";
    case ELSE: return "ELSE";
    case ID:   return "ID";
    case NUM:  return "NUM";
    case LE:   return "LE (<=)";
    case GE:   return "GE (>=)";
    case EQ:   return "EQ (==)";
    case NE:   return "NE (!=)";
    default:   return NULL;
    }
}

static int run_tokens(void)
{
    int tok;
    printf("Tokens:\n");
    while ((tok = yylex()) != 0) {
        const char *name = token_name(tok);
        if (name != NULL) {
            printf("Line %-3d %-10s %s\n", lex_line, name, yytext);
            if (tok == ID || tok == NUM)
                free(yylval.sval);
        } else {
            char one[2] = {(char)tok, '\0'};
            printf("Line %-3d %-10s %s\n", lex_line, one, yytext);
        }
    }
    if (lex_error_count > 0) {
        fprintf(stderr, "Tokenisation finished with %d lexical "
                        "error(s)\n", lex_error_count);
        return 1;
    }
    return 0;
}

static void usage(const char *prog)
{
    printf("Usage: %s [--tokens | --trace] [file]\n", prog);
    printf("  --tokens   print the token stream only\n");
    printf("  --trace    print the backpatching trace, then the TAC\n");
    printf("  --help     show this message\n");
    printf("With no file, input is read from standard input.\n");
}

int main(int argc, char **argv)
{
    const char *filename = NULL;
    int tokens_mode = 0;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--tokens") == 0) {
            tokens_mode = 1;
        } else if (strcmp(argv[i], "--trace") == 0) {
            tac_trace = 1;
        } else if (strcmp(argv[i], "--help") == 0) {
            usage(argv[0]);
            return 0;
        } else if (argv[i][0] == '-') {
            fprintf(stderr, "Unknown option: %s\n", argv[i]);
            usage(argv[0]);
            return 1;
        } else if (filename == NULL) {
            filename = argv[i];
        } else {
            fprintf(stderr, "Only one input file may be given\n");
            return 1;
        }
    }

    if (filename != NULL) {
        yyin = fopen(filename, "r");
        if (yyin == NULL) {
            perror(filename);
            return 1;
        }
    }

    if (tac_trace)
        printf("Backpatching trace:\n");

    int status;
    if (tokens_mode) {
        status = run_tokens();
    } else {
        int parse_result = yyparse();
        if (parse_result != 0 || syntax_error_count > 0 ||
            lex_error_count > 0) {
            fprintf(stderr,
                    "Compilation failed: %d syntax error(s), "
                    "%d lexical error(s)\n",
                    syntax_error_count, lex_error_count);
            status = 1;
        } else {
            /* The whole program's nextlist lands on the end marker. */
            int end_index = emit_end();
            backpatch(program_nextlist, end_index);
            int validation_errors = validate_tac();
            if (validation_errors > 0) {
                fprintf(stderr, "TAC validation FAILED with %d "
                                "error(s)\n", validation_errors);
                status = 1;
            } else {
                print_tac();
                status = 0;
            }
        }
    }

    yylex_destroy();
    if (filename != NULL && yyin != NULL)
        fclose(yyin);
    return status;
}
