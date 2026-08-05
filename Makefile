# termux-root-su — build with Android NDK cross-compiler
# Usage: make CC=aarch64-linux-android-gcc
#   or:  make CC=aarch64-linux-gnu-gcc   (Linux static-ish)
#   or:  make                              (host compiler)

CC ?= aarch64-linux-android-gcc
CFLAGS ?= -O2 -Wall -Wextra -static
STRIP ?= aarch64-linux-android-strip

SRCDIR = src
OUTDIR = build

TARGETS = $(OUTDIR)/magisk-proxy $(OUTDIR)/su-relay $(OUTDIR)/test-proxy-client

.PHONY: all clean

all: $(TARGETS)

$(OUTDIR)/magisk-proxy: $(SRCDIR)/magisk-proxy.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR)/su-relay: $(SRCDIR)/su-relay.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR)/test-proxy-client: $(SRCDIR)/test-proxy-client.c | $(OUTDIR)
	$(CC) $(CFLAGS) -o $@ $<

$(OUTDIR):
	mkdir -p $(OUTDIR)

clean:
	rm -rf $(OUTDIR)
