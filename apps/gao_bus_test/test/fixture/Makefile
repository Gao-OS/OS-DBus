CC      ?= gcc
CFLAGS  := $(shell pkg-config --cflags gio-2.0) -Wall -Wextra -O2
LDFLAGS := $(shell pkg-config --libs gio-2.0)

all: external_fixture

external_fixture: external_fixture.c
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS)

clean:
	rm -f external_fixture

.PHONY: all clean
