# ReLoq C as a static library for Apple platforms: iPhone (arm64), the iPhone simulator on Apple
# silicon (arm64) and macOS on Apple silicon (arm64), and one XCFramework of the three. ReLoq Apple links
# it into ONE shared dynamic framework that its app and its speech-synthesis extension both load.
# Run by `make engine` (the top-level Makefile); it reads ReLoq C from RELOQ (the Engine/Reloq-C submodule)
# and writes only to OUT, so the submodule stays clean.
#
# The same split as ReLoq C's eci/Makefile: the 6.1 rule provider (vendor/openevv61/Makefile.native,
# PORT=posix, rules -Os, everything else -O2) and the ReLoq core (every src/*.c the ECI library is made
# of; eci/Makefile SOURCE).
#
# Apple arm64 needs ReLoq C's setNonSequential to take fixed arguments (the fix in the submodule,
# vendor/openevv61/src/eci/bridge/eci_deltainit2.c): it is variadic and the rule table calls it through
# a fixed prototype, and Apple's arm64 takes variable arguments off the stack, so without the fix it read
# stack garbage - a crash creating the first US English instance on an iPhone, and wrong or refused
# speech in a build without LTO. With the fix, LTO and non-LTO builds give the same samples. LTO stays
# because it is faster code: the objects are ThinLTO, and `lib` then PRE-LINKS everything into ONE native
# object (ld -r, the LTO done once, here), so the app's own link takes under a second.
#
#   make -f Engine/apple.mk RELOQ=Engine/Reloq-C OUT=build/reloq -j8 xcframework
#                                         -> build/reloq/ReloqEngine.xcframework
#   make -f Engine/apple.mk RELOQ=Engine/Reloq-C OUT=build/reloq PLATFORM=macos lib
#                                         -> build/reloq/macos/libreloq.a
#
# The archive exports the ECI names (eciNewEx, eciAddText ...) as HIDDEN symbols (-fvisibility=hidden,
# ECI_STATIC): they link into the consumer's image and are not re-exported from it.

SELF     := $(abspath $(lastword $(MAKEFILE_LIST)))
RELOQ    ?= $(dir $(SELF))Reloq-C
ROOT     := $(abspath $(RELOQ))
OUT      ?= $(dir $(SELF))../build/reloq
override OUT := $(abspath $(OUT))
PLATFORM ?= macos
OPT      ?= -O2 -flto=thin
RULE_OPT ?= -Os

ifeq ($(PLATFORM),ios)
TARGET := arm64-apple-ios16.0
SDK    := iphoneos
else ifeq ($(PLATFORM),ios-sim)
TARGET := arm64-apple-ios16.0-simulator
SDK    := iphonesimulator
else ifeq ($(PLATFORM),macos)
TARGET := arm64-apple-macos11.0
SDK    := macosx
else
$(error PLATFORM must be ios, ios-sim or macos)
endif

PCC    := $(shell xcrun --sdk $(SDK) -f clang) -isysroot $(shell xcrun --sdk $(SDK) --show-sdk-path) -target $(TARGET)
PAR    := $(shell xcrun -f ar)
PB     := $(OUT)/$(PLATFORM)
RULES  := $(PB)/rules/libreloq61.a

CORE_SOURCES := $(filter-out $(ROOT)/src/reloq_host.c $(ROOT)/src/reloq_voice_filter.c $(ROOT)/src/reloq_orthography.c \
                  $(ROOT)/src/reloq_german_word_edges.c $(ROOT)/src/reloq_english%.c,$(wildcard $(ROOT)/src/*.c)) \
                $(ROOT)/src/reloq_english_spr.c
CORE_OBJECTS := $(patsubst $(ROOT)/src/%.c,$(PB)/core/%.o,$(CORE_SOURCES))
CORE_CFLAGS  := $(OPT) -std=c11 -Wall -Wextra -pedantic -pthread -ffunction-sections -fdata-sections \
                -ffp-contract=off -fvisibility=hidden -DECI_STATIC -MMD -MP -I$(ROOT)/include

.PHONY: lib rules xcframework clean
lib: $(PB)/libreloq.a

rules:
	$(MAKE) -C $(ROOT)/vendor/openevv61 -f Makefile.native BUILD='$(PB)/rules' CC='$(PCC)' AR='$(PAR)' \
	  OPT='$(OPT)' RULE_OPT='$(RULE_OPT)' PORT=posix

$(RULES): rules ;

$(PB)/core/%.o: $(ROOT)/src/%.c
	@mkdir -p $(dir $@)
	$(PCC) $(CORE_CFLAGS) -c $< -o $@

-include $(CORE_OBJECTS:.o=.d)

# Every object of both halves into one relocatable native object; LTO happens here (-flto=thin in the
# objects). The ECI names stay global (hidden); the rest of the names are the engine's own.
$(PB)/reloq.o: $(CORE_OBJECTS) $(RULES)
	rm -f $(PB)/all.a && cp $(RULES) $(PB)/all.a && $(PAR) rs $(PB)/all.a $(CORE_OBJECTS) >/dev/null
	printf '_eci*\n_reloq_eci_*\n' > $(PB)/keep.txt
	$(PCC) -r -nostdlib $(filter -flto%,$(OPT)) -Wl,-all_load -Wl,-exported_symbols_list,$(PB)/keep.txt $(PB)/all.a -o $@
	rm -f $(PB)/all.a

$(PB)/libreloq.a: $(PB)/reloq.o
	rm -f $@ && $(PAR) rcs $@ $(PB)/reloq.o
	@mkdir -p $(PB)/Headers && cp $(ROOT)/include/eci.h $(ROOT)/include/reloq_eci.h $(PB)/Headers/

# The three slices, each its own sub-make (PLATFORM picks the compiler), then one XCFramework.
xcframework:
	$(MAKE) -f $(SELF) RELOQ=$(ROOT) OUT=$(OUT) PLATFORM=ios lib
	$(MAKE) -f $(SELF) RELOQ=$(ROOT) OUT=$(OUT) PLATFORM=ios-sim lib
	$(MAKE) -f $(SELF) RELOQ=$(ROOT) OUT=$(OUT) PLATFORM=macos lib
	rm -rf $(OUT)/ReloqEngine.xcframework
	xcodebuild -create-xcframework \
	  -library $(OUT)/ios/libreloq.a -headers $(OUT)/ios/Headers \
	  -library $(OUT)/ios-sim/libreloq.a -headers $(OUT)/ios-sim/Headers \
	  -library $(OUT)/macos/libreloq.a -headers $(OUT)/macos/Headers \
	  -output $(OUT)/ReloqEngine.xcframework

clean:
	rm -rf $(OUT)
