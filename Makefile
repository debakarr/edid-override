CC = clang
CFLAGS ?= -O2 -fobjc-arc -Wall -Wextra -Wno-deprecated-declarations
FRAMEWORKS = -framework Foundation -framework AppKit -framework IOKit -framework CoreGraphics
SRC = src/main.m
BIN = edid-override

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $@ $(SRC) $(FRAMEWORKS)

clean:
	rm -f $(BIN)

install: $(BIN)
	install -d $(HOME)/.local/bin
	install -m 0755 $(BIN) $(HOME)/.local/bin/$(BIN)

.PHONY: all clean install
