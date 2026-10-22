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
