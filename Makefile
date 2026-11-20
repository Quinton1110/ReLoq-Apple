# Mac-side checks of the C bridge, exactly as the phone compiles it, and the engine build.
# The app itself is built with xcodegen + xcodebuild (README.md).

CC      ?= cc
CFLAGS  ?= -std=gnu99 -O2 -Wall -Wextra -IShared/Bridge
# ReLoq C, the engine: a git submodule (git submodule update --init). `make engine` builds its three Apple
# slices (iPhone, iPhone simulator, Mac; Engine/apple.mk, a few minutes) into build/reloq, and copies the
# XCFramework and its headers to where project.yml looks for them. The submodule itself is not written to.
RELOQ   ?= Engine/Reloq-C
RELOQ_LIB ?= Engine/reloq.xcframework/macos-arm64/libreloq.a
JOBS    ?= 8

.PHONY: test bridge-test ssml-test userdict-test appgroup-test engine engine-check engine-test dict-live-test release clean

test: bridge-test ssml-test userdict-test appgroup-test

# ReLoq C from the submodule -> Engine/reloq.xcframework + Engine/reloq-include (eci.h, reloq_eci.h,
# reloq_build.h). reloq_build.h names the ReLoq C commit, which the app shows as its engine line
# ("ReLoq C 1.4.1 ECI 1.2.2 build Reloq-C@<commit>"); "+dirty" when the submodule has changes.
engine:
	@test -f $(RELOQ)/include/eci.h || { echo "Engine/Reloq-C is empty: run git submodule update --init"; exit 1; }
	$(MAKE) -f Engine/apple.mk RELOQ=$(CURDIR)/$(RELOQ) OUT=$(CURDIR)/build/reloq -j$(JOBS) xcframework
	rm -rf Engine/reloq.xcframework
	cp -R build/reloq/ReloqEngine.xcframework Engine/reloq.xcframework
	mkdir -p Engine/reloq-include
	cp $(RELOQ)/include/eci.h $(RELOQ)/include/reloq_eci.h Engine/reloq-include/
	printf '#define EV_ENGINE_BUILD "Reloq-C@%s%s"\n#define EV_RELOQ_VERSION "%s"\n' \
	  "$$(git -C $(RELOQ) rev-parse --short HEAD)" \
	  "$$(git -C $(RELOQ) diff --quiet -- src include vendor || echo +dirty)" \
	  "$$(sed -n 's/^version = "\(.*\)"/\1/p' $(RELOQ)/addon/synth/manifest.ini)" > Engine/reloq-include/reloq_build.h
	@cat Engine/reloq-include/reloq_build.h

# The stub bridge + its checks: every parameter reaches the audio, cancel works, empty text is silent.
bridge-test: build/mac/ev_test
	@mkdir -p samples
	@./build/mac/ev_test samples

# The extension's SSML parser (Shared/SSML.swift, exactly as the targets compile it): segments, pauses,
# scoped prosody, and the privacy of the diagnostic shape line.
ssml-test: build/mac/ssml_test
	@./build/mac/ssml_test

# The user's own dictionary entries (Shared/UserDictionary.swift, exactly as the targets compile it):
# parsing as the bridge parses, the store, duplicate detection by the engine's case rules, edits of
# community entries kept as the user's own, validation, that updates never reach the user's files, and
# the Daily / Weekly / Monthly update schedule (Shared/DictionarySchedule.swift).
userdict-test: build/mac/userdict_test
	@./build/mac/userdict_test

build/mac/userdict_test: Shared/UserDictionary.swift Shared/DictionarySchedule.swift Shared/PhoneticRespelling.swift Shared/ListenMarker.swift Shared/DictionarySource.swift Tests/userdict/main.swift
	@mkdir -p build/mac
	swiftc -O Shared/UserDictionary.swift Shared/DictionarySchedule.swift Shared/PhoneticRespelling.swift Shared/ListenMarker.swift Shared/DictionarySource.swift Tests/userdict/main.swift -o $@

# The app group resolver (Shared/AppGroup.swift, exactly as the targets compile it): a copy installed directly keeps
# the entitlements' group; a copy AltStore or SideStore re-signed uses the group they list under ALTAppGroups in its
# Info.plist, and the app and the extension agree. Given bundle paths it prints what each resolves to.
appgroup-test: build/mac/appgroup_test
	@./build/mac/appgroup_test

build/mac/appgroup_test: Shared/AppGroup.swift Tests/appgroup/main.swift
	@mkdir -p build/mac
	swiftc -O Shared/AppGroup.swift Tests/appgroup/main.swift -o $@

build/mac/ssml_test: Shared/SSML.swift Tests/ssml/main.swift
	@mkdir -p build/mac
	swiftc -O Shared/SSML.swift Tests/ssml/main.swift -o $@

build/mac/ev_test: Engine/test/ev_test.c Shared/Bridge/ev_bridge.c Shared/Bridge/ev_bridge.h Shared/Bridge/ev_marks.inc
	@mkdir -p build/mac
	$(CC) $(CFLAGS) -fsanitize=address,undefined Engine/test/ev_test.c Shared/Bridge/ev_bridge.c -lm -liconv -o $@

# The ENGINE path of the bridge compiled (not linked) against ReLoq C's header (after `make engine`).
engine-check:
	$(CC) $(CFLAGS) -DELOQUENCE_ENGINE=1 -DEV_ENGINE_reloq=1 -DECI_STATIC -IEngine/reloq-include -fsyntax-only Shared/Bridge/ev_bridge.c
	@echo "engine path compiles against Engine/reloq-include/eci.h"

# The ENGINE half of the bridge LINKED and RUN on the Mac against ReLoq C's Mac slice (after `make engine`).
# Measures pitch shifts in hertz; with DICT_DIR=<folder holding ENUmain.dic ENURoot.dic ENUabbr.dic from
# IBMTTSDictionaries, e.g. DICT_DIR=Engine/Reloq-C/data/community> it also proves the community dictionary by
# phonemes (without it, the four dictionary checks fail).
engine-test: build/mac/ev_engine_test
	@DICT_DIR=$(DICT_DIR) ./build/mac/ev_engine_test

build/mac/ev_engine_test: Engine/test/ev_engine_test.c Shared/Bridge/ev_bridge.c Shared/Bridge/ev_bridge.h Shared/Bridge/ev_marks.inc $(RELOQ_LIB)
	@mkdir -p build/mac
	$(CC) -std=gnu99 -O2 -w -DELOQUENCE_ENGINE=1 -DEV_ENGINE_reloq=1 -DECI_STATIC -IShared/Bridge -IEngine/reloq-include \
	  Engine/test/ev_engine_test.c $(RELOQ_LIB) -Wl,-dead_strip -lpthread -lm -liconv -o $@

# LIVE (network, not part of `make test`): the offered dictionary sources' latest releases downloaded through the
# app's own functions (Shared/DictionarySource.swift), counted and loaded by the bridge with ReLoq C linked in (after
# `make engine`). `make dict-live-test LINKS="https://github.com/owner/repo"` checks other links the same way.
dict-live-test: build/mac/dictsource_live
	@./build/mac/dictsource_live $(LINKS)

build/mac/dictsource_live: Shared/DictionarySource.swift Shared/UserDictionary.swift Tests/dictsource/main.swift Shared/Bridge/ev_bridge.c Shared/Bridge/ev_bridge.h Shared/Bridge/ev_marks.inc $(RELOQ_LIB)
	@mkdir -p build/mac
	$(CC) -std=gnu99 -O2 -w -DELOQUENCE_ENGINE=1 -DEV_ENGINE_reloq=1 -DECI_STATIC -IShared/Bridge -IEngine/reloq-include \
	  -c Shared/Bridge/ev_bridge.c -o build/mac/ev_bridge_engine.o
	swiftc -O -import-objc-header Shared/Bridge/ev_bridge.h Shared/UserDictionary.swift Shared/DictionarySource.swift \
	  Tests/dictsource/main.swift build/mac/ev_bridge_engine.o $(RELOQ_LIB) -Xlinker -dead_strip -liconv -o $@

# A release: the IPA, the notarized Mac zip, the AltStore / SideStore source and the downloads page (tools/release.sh;
# server and notarization settings in tools/release.local). DRYRUN=1 builds and shows everything but uploads nothing;
# NOTARIZE=1 notarizes in a dry run too; SKIPBUILD=1 reuses build/release/VERSION/.
release:
	@test -n "$(VERSION)" -a -n "$(NOTES)" || { echo 'usage: make release VERSION=0.1 NOTES="What'"'"'s new" [DRYRUN=1] [NOTARIZE=1] [SKIPBUILD=1]'; exit 2; }
	tools/release.sh "$(VERSION)" "$(NOTES)" $(if $(DRYRUN),--dry-run) $(if $(NOTARIZE),--notarize) $(if $(SKIPBUILD),--skip-build)

clean:
	rm -rf build/mac samples
