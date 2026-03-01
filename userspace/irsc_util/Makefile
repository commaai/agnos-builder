# Makefile for irsc_util - IPC Router Security Configuration utility

CC ?= gcc
CFLAGS ?= -Wall -Wextra -O2

# For cross-compilation, set CC to aarch64-linux-gnu-gcc
# CC = aarch64-linux-gnu-gcc

TARGET = irsc_util
SRCS = irsc_util.c
OBJS = $(SRCS:.c=.o)

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CC) $(CFLAGS) -o $@ $^

%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

clean:
	rm -f $(TARGET) $(OBJS)

install: $(TARGET)
	install -m 755 $(TARGET) $(DESTDIR)/usr/bin/

.PHONY: all clean install
