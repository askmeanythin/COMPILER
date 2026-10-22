# Makefile for the if-else compiler (Flex + Bison + C)
#
# Targets:
#   make        build ./compiler
#   make run    run the if-else demonstration program
#   make test   run the automated test suite
#   make debug  build ./compiler_debug with sanitizers and produce
#               parser.output (Bison state/conflict report)
#   make clean  remove all generated files

CC      = gcc
CFLAGS  = -Wall -Wextra -Wpedantic -std=gnu11 -g
BISON   = bison
FLEX    = flex

SOURCES = lex.yy.c parser.tab.c tac.c main.c
HEADERS = tac.h parser.tab.h

all: compiler

compiler: $(SOURCES) $(HEADERS)
	$(CC) $(CFLAGS) -o $@ $(SOURCES)

# Bison must run before Flex: lexer.l includes parser.tab.h.
parser.tab.c parser.tab.h: parser.y tac.h
	$(BISON) -d -o parser.tab.c parser.y

lex.yy.c: lexer.l parser.tab.h
	$(FLEX) -o $@ lexer.l

run: compiler
	./compiler examples/if_else.src

test: compiler
	bash tests/test_compiler.sh

debug: parser.tab.c lex.yy.c tac.c main.c tac.h
	$(BISON) --report=all -o parser.tab.c parser.y
	$(CC) $(CFLAGS) -O0 -fsanitize=address,undefined -o compiler_debug $(SOURCES)

clean:
	rm -f compiler compiler_debug lex.yy.c parser.tab.c parser.tab.h \
	      parser.output *.o

.PHONY: all run test debug clean
