/*
 * lexer.l - Flex lexical analyser for the if-else compiler.
 *
 * Recognises: keywords if/else, identifiers, integer constants,
 * arithmetic operators (+ - * /), relational operators
 * (< > <= >= == !=), the assignment operator (=), parentheses,
 * braces and semicolons.
 *
 * - Multi-character relational operators are matched BEFORE the
 *   single-character ones (Flex uses longest match, and the order
 *   below also lists them first), so "<=" is never split into
 *   "<" + "=".
 * - Keywords are matched BEFORE the identifier rule, so "if" and
 *   "else" are never returned as identifiers (Flex prefers the
 *   earlier rule when two patterns match the same length, and the
 *   longest match otherwise - "ifx" is longer, so it stays an ID).
 * - Line numbers are tracked in lex_line and used in error reports.
 * - An invalid character is reported as a lexical error, counted in
 *   lex_error_count, skipped, and scanning continues; main() turns a
 *   non-zero count into a non-zero exit status.
 */
%{
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "tac.h"
#include "parser.tab.h"

int lex_line = 1;        /* current source line, used in error messages */
int lex_error_count = 0; /* number of invalid characters seen           */
%}

%option noyywrap
%option nodefault
%option noinput nounput

DIGIT   [0-9]
LETTER  [a-zA-Z_]
ID      {LETTER}({LETTER}|{DIGIT})*
NUM     {DIGIT}+

%%

"if"                    { return IF; }
"else"                  { return ELSE; }

"<="                    { return LE; }
">="                    { return GE; }
"=="                    { return EQ; }
"!="                    { return NE; }
"<"                     { return '<'; }
">"                     { return '>'; }

{ID}                    { yylval.sval = strdup(yytext); return ID; }
{NUM}                   { yylval.sval = strdup(yytext); return NUM; }

"+"                     { return '+'; }
"-"                     { return '-'; }
"*"                     { return '*'; }
"/"                     { return '/'; }
"="                     { return '='; }
";"                     { return ';'; }
"("                     { return '('; }
")"                     { return ')'; }
"{"                     { return '{'; }
"}"                     { return '}'; }

[ \t\r]+                { /* skip spaces, tabs, carriage returns */ }
\n                      { lex_line++; }
.                       {
                            fprintf(stderr,
                                    "Lexical error at line %d: invalid "
                                    "character '%s'\n",
                                    lex_line, yytext);
                            lex_error_count++;
                        }

%%
