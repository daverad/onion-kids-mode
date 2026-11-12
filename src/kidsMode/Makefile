INCLUDE_CJSON=1
include ../common/config.mk

TARGET = kidui
KIDS_BUILD_SOURCE ?= unverified
CFLAGS += -DKIDS_BUILD_SOURCE=\"$(KIDS_BUILD_SOURCE)\"

LDFLAGS := $(LDFLAGS) -lSDL -lSDL_ttf -lSDL_image -lSDL_rotozoom -lm -pthread -lkbinput

include ../common/commands.mk
include ../common/recipes.mk

# Keep strict diagnostics confined to the new headless policy/runtime units.
allowance.o allowance_store.o allowance_runtime.o: CFLAGS += -Wextra -Wpedantic -Werror -Wformat=2 -Wshadow -Wconversion -Wstrict-prototypes
