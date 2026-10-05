# Builds the port program into the application's priv directory. elixir_make runs this
# when the dependency compiles, with MIX_APP_PATH set to where the application is built.

PREFIX = $(MIX_APP_PATH)/priv
CFLAGS ?= -O2
CFLAGS += -Wall -Wextra -std=gnu11

all: $(PREFIX)/nanosleep

$(PREFIX)/nanosleep: c_src/nanosleep.c Makefile
	@mkdir -p $(PREFIX)
	$(CC) $(CFLAGS) -o $@ c_src/nanosleep.c $(LDFLAGS)

clean:
	$(RM) $(PREFIX)/nanosleep

.PHONY: all clean
