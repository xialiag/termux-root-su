# termux-root-su — build with Android NDK cross-compiler
# Usage: make CC=aarch64-linux-android-gcc
#   or:  make CC=aarch64-linux-gnu-gcc   (Linux static-ish)
#   or:  make                              (host compiler)

CC ?= aarch64-linux-gnu-gcc
CFLAGS ?= -O2 -Wall -Wextra -static
STRIP ?= aarch64-linux-gnu-strip

SRCDIR = src
OUTDIR = build

TARGETS = $(OUTDIR)/magisk-proxy $(OUTDIR)/su

.PHONY: all clean

all: $(TARGETS)

$(OUTDIR)/magisk-proxy: $(SRCDIR)/magisk-proxy.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR)/su: $(SRCDIR)/su.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -rf $(OUTDIR)
