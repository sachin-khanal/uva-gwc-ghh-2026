# File:    Makefile
# Purpose: ONE entry point for every build/run/test action, for humans AND LLM agents.
#          Run `make help` to list targets. Nothing here requires opening the Xcode app after the
#          one-time setup in docs/SETUP.md.
#
# Typical loop:   make gen        # (re)generate Waypoint.xcodeproj from project.yml
#                 make test       # fast pure-logic tests, no phone needed (~seconds)
#                 make typecheck  # type-check the iOS app against the iOS SDK (fast, no phone)
#                 make check      # full xcodebuild compile without signing (needs healthy Xcode)
#                 DEVICE=<id> make run   # build + sign + install + launch on your iPhone
#
# IMPORTANT - build output lives OUTSIDE the repo: ~/Desktop is iCloud-synced and adds Finder
# metadata that makes `codesign` fail ("resource fork, Finder information... not allowed").
# So everything is built under $(BUILD_ROOT) instead.

SHELL        := /bin/bash
.DEFAULT_GOAL := help

APP_NAME     := Waypoint
PROJECT      := $(APP_NAME).xcodeproj
SCHEME       := $(APP_NAME)
CONFIG       ?= Debug
BUILD_ROOT   := $(HOME)/Library/Caches/Waypoint
DERIVED      := $(BUILD_ROOT)/DerivedData
SPM_SCRATCH  := $(BUILD_ROOT)/spm
CORE_PKG     := Package/WaypointCore

# Per-developer values come from Config/Local.xcconfig (git-ignored; created by `make setup`).
LOCAL_XCCONFIG := Config/Local.xcconfig
TEAM   := $(strip $(shell sed -n 's/^DEVELOPMENT_TEAM *= *//p' $(LOCAL_XCCONFIG) 2>/dev/null))
SUFFIX := $(strip $(shell sed -n 's/^WAYPOINT_DEV_SUFFIX *= *//p' $(LOCAL_XCCONFIG) 2>/dev/null))
SUFFIX := $(if $(SUFFIX),$(SUFFIX),shared)
BUNDLE_PREFIX := $(strip $(shell sed -n 's/^WAYPOINT_BUNDLE_PREFIX *= *//p' Config/Local.xcconfig Config/Base.xcconfig 2>/dev/null | tail -1))
BUNDLE_ID := $(BUNDLE_PREFIX).$(SUFFIX)

# DEVICE = the iPhone's identifier from `make devices` (the "Identifier" column / UDID).
DEST := $(if $(DEVICE),id=$(DEVICE),generic/platform=iOS)
APP_PATH := $(DERIVED)/Build/Products/$(CONFIG)-iphoneos/$(APP_NAME).app

XCODEBUILD := xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
              -derivedDataPath $(DERIVED) -destination '$(DEST)'
# Lets xcodebuild create/refresh the free provisioning profile and register the phone.
SIGN_FLAGS := -allowProvisioningUpdates -allowProvisioningDeviceRegistration

.PHONY: test-tools test-all backup-maps restore-maps list-map-backups help setup doctor hooks test-hooks team-id gen test typecheck check build install launch run logs selftest-sim selftest-scan selftest-e2e uitest uitest-shots devices open clean clean-all

help: ## Show this help
	@echo "Waypoint make targets:"; echo
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
	@echo; echo "Variables: DEVICE=<id from 'make devices'>  CONFIG=Debug|Release"
	@echo "Docs: README.md, AGENTS.md, docs/SETUP.md"

setup: ## One-time: install XcodeGen, create Config/Local.xcconfig, run doctor
	@command -v xcodegen >/dev/null || { echo "Installing xcodegen via Homebrew..."; brew install xcodegen; }
	@if [ ! -f $(LOCAL_XCCONFIG) ]; then cp Config/Local.xcconfig.example $(LOCAL_XCCONFIG); \
	  echo "Created $(LOCAL_XCCONFIG). EDIT IT: set DEVELOPMENT_TEAM and WAYPOINT_DEV_SUFFIX."; fi
	@sh scripts/docs-sync.sh install
	@./scripts/doctor.sh

doctor: ## Check the toolchain, signing config and connected devices
	@./scripts/doctor.sh

hooks: ## Install the git pre-commit hook that requires a docs/WORKLOG.md entry with every code commit (AGENTS.md rule 12)
	@sh scripts/docs-sync.sh install

test-hooks: ## Self-test the docs hook in a throwaway git repo
	@sh scripts/test-docs-sync.sh

team-id: ## Print your Apple team id from your signing certificate (for Config/Local.xcconfig)
	@./scripts/team-id.sh

gen: ## Generate Waypoint.xcodeproj from project.yml (run after editing project.yml or adding files)
	@command -v xcodegen >/dev/null || { echo "xcodegen missing: run 'make setup'"; exit 1; }
	xcodegen generate --quiet
	@echo "Generated $(PROJECT)"

test: ## Run WaypointCore unit tests on macOS (no phone, no simulator needed)
	cd $(CORE_PKG) && swift test --scratch-path $(SPM_SCRATCH)

test-tools: ## Run the NON-Swift tests: map validator (python) and web viewer (node). Skips what is not installed.
	@# `make test` only builds WaypointCore, so nothing here is covered by it and nothing in CI runs it
	@# either. That is how four separate places came to pin "format 4 is invalid" while the app was
	@# writing format 4 (2026-10-18): the web viewer refused every map and no build complained.
	@if command -v python3 >/dev/null 2>&1; then \
	  echo "== map validator (python) =="; python3 -m unittest discover -s tools -q || exit 1; \
	else echo "python3 not installed; skipping the map validator tests"; fi
	@if command -v node >/dev/null 2>&1; then \
	  echo "== web viewer (node) =="; cd web && node test-web.mjs | tail -3; \
	else echo "node not installed; skipping the web viewer tests"; fi

test-all: test test-tools ## Everything testable without a phone: WaypointCore + validator + web viewer

typecheck: ## Type-check the iOS app against the iOS SDK (works even if xcodebuild is broken)
	./scripts/typecheck.sh

check: gen ## Compile the iOS app via xcodebuild WITHOUT signing (needs a healthy Xcode install)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
	  -derivedDataPath $(DERIVED) -destination 'generic/platform=iOS' \
	  CODE_SIGNING_ALLOWED=NO build | tail -25

build: gen ## Build + sign the app for your phone (set DEVICE=...)
	@[ -n "$(TEAM)" ] && ! echo "$(TEAM)" | grep -q REPLACE || { echo "Set DEVELOPMENT_TEAM in $(LOCAL_XCCONFIG) (see docs/SETUP.md)"; exit 1; }
	$(XCODEBUILD) $(SIGN_FLAGS) build | tail -25

backup-maps: ## Copy the maps (scans, 3D models) out of the app on the phone to ~/Library/Caches/Waypoint/map-backups (DEVICE=...)
	@BUNDLE_ID=$(BUNDLE_ID) sh scripts/phone-maps.sh backup

restore-maps: ## Copy the newest backup that has a scan back onto the phone (DEVICE=..., optional DIR=path)
	@BUNDLE_ID=$(BUNDLE_ID) sh scripts/phone-maps.sh restore $(DIR)

list-map-backups: ## List the map backups on this Mac
	@sh scripts/phone-maps.sh list

install: backup-maps ## Install the last build onto the phone (DEVICE=...); backs up the phone's maps first
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device install app --device $(DEVICE) "$(APP_PATH)"

launch: ## Launch the installed app and stream its console to this terminal (DEVICE=...)
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --console $(BUNDLE_ID)

run: build install launch ## Build, install and launch on your phone (DEVICE=...)

ROOM ?= Room 204
EXTRA ?=

selftest-sim: ## HEADLESS on-phone test: run the simulated walk to ROOM (default "Room 204"), print every cue, exit PASS/FAIL (DEVICE=...). Phone must be unlocked; you will hear it.
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --console $(BUNDLE_ID) -- -autoSimulate "$(ROOM)"

selftest-e2e: ## HEADLESS end-to-end self-test on the phone: capabilities, storage, Keychain, synthetic scan -> save -> reload -> share -> simulated walk, cloud (if configured). Prints PASS/FAIL per check (DEVICE=...)
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --console $(BUNDLE_ID) -- -autoE2E YES

selftest-scan: ## HEADLESS scan monitor: app starts scanning by itself and prints tracking/mesh/box stats once per second (DEVICE=...). Walk with the phone; Ctrl-C to stop.
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --terminate-existing --console $(BUNDLE_ID) -- -autoScan YES $(EXTRA)

UITEST_RESULT := $(BUILD_ROOT)/uitest.xcresult
UITEST_SHOTS  := $(BUILD_ROOT)/uitest-screens
ONLY ?=

uitest: gen backup-maps ## Run the UI tests ON THE PHONE (taps + screenshots), then export screenshots (DEVICE=...; ONLY=testName for one). Phone unlocked; Settings > Developer > Enable UI Automation
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	rm -rf "$(UITEST_RESULT)"
	-$(XCODEBUILD) $(SIGN_FLAGS) -resultBundlePath "$(UITEST_RESULT)" $(if $(ONLY),-only-testing:WaypointUITests/WaypointUITests/$(ONLY)) test 2>&1 | grep -E "Test Case|error:|Executed|TEST (SUCCEEDED|FAILED)|\*\* " | tail -40
	@$(MAKE) --no-print-directory uitest-shots

uitest-shots: ## Export the screenshots + notes from the last `make uitest` into $(UITEST_SHOTS)
	rm -rf "$(UITEST_SHOTS)" && mkdir -p "$(UITEST_SHOTS)"
	xcrun xcresulttool export attachments --path "$(UITEST_RESULT)" --output-path "$(UITEST_SHOTS)"
	@echo "Screenshots/notes in: $(UITEST_SHOTS)"; ls "$(UITEST_SHOTS)" | head -30

logs: ## Stream the phone's logs for this app only (DEVICE=...). Ctrl-C to stop.
	@[ -n "$(DEVICE)" ] || { echo "Set DEVICE=<id>; list with 'make devices'"; exit 1; }
	xcrun devicectl device process launch --device $(DEVICE) --console $(BUNDLE_ID)

devices: ## List connected iPhones and their identifiers
	xcrun devicectl list devices

open: gen ## Open the project in the Xcode app (optional; the CLI is enough)
	open $(PROJECT)

clean: ## Remove build output for this project
	rm -rf $(DERIVED)

clean-all: clean ## Also remove SwiftPM scratch and the generated Xcode project
	rm -rf $(SPM_SCRATCH) $(PROJECT)
