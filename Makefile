# Local Soulear - build helpers
#
# Targets:
#   make android-release   Release APK (arm64) via the Flutter container
#   make android-debug     Debug APK via the Flutter container
#   make adb-install       Install the built APK on a connected device
#   make web               Build the web app (Node/TS backend + React frontend)
#   make clean             Remove build artifacts of the app and the Flutter app
#
# The Android targets run in a Podman container (image gmeligio/flutter-android)
# like build.sh, because a local Flutter SDK may not be installed. The web app
# needs Node.js (>= 22) locally; `adb-install` needs adb.

# --- Configuration ----------------------------------------------------------

FLUTTER_SDK ?= 3.47.3
FLUTTER_IMG ?= docker.io/gmeligio/flutter-android

CONTAINER_ENGINE ?= podman

# For `adb-install`: which ABI of the release APK to install.
ABI ?= arm64-v8a

# Podman invocation for a Flutter command in the flutter_app directory.
# No -it: meant for automation/CI. `,Z`/`,U` set the SELinux context and the
# ownership so files created in the container belong to the host user.
CONTAINER_RUN = $(CONTAINER_ENGINE) run --rm \
	-v $(CURDIR)/flutter_app:/app:U,Z \
	-w /app \
	$(FLUTTER_IMG):$(FLUTTER_SDK)

# Android APK output (arm64) relative to flutter_app/.
APK_DIR = flutter_app/build/app/outputs/flutter-apk
RELEASE_APK = $(APK_DIR)/app-$(ABI)-release.apk
DEBUG_APK = $(APK_DIR)/app-debug.apk

.PHONY: all android-release android-debug adb-install adb-install-debug adb-check web clean help

all: android-release

# --- Android (Flutter in the container) -------------------------------------

## Build the release APK for arm64 (like build.sh).
android:
android-release:
	$(CONTAINER_RUN) flutter build apk --release --split-per-abi --target-platform android-arm64
	@echo "APK: $(RELEASE_APK)"

## Build the debug APK for arm64.
android-debug:
	$(CONTAINER_RUN) flutter build apk --debug --target-platform android-arm64
	@echo "APK: $(DEBUG_APK)"

# --- Install ----------------------------------------------------------------

## Install the release APK on a connected device via adb
## (run `make android-release` first; choose the ABI with `ABI=`).
adb-install:
	@test -f $(RELEASE_APK) || { echo "APK missing: $(RELEASE_APK) - run 'make android-release' first."; exit 1; }
	@$(MAKE) --no-print-directory adb-check
	adb install -r $(RELEASE_APK)

## Install the debug APK via adb (run `make android-debug` first).
adb-install-debug:
	@test -f $(DEBUG_APK) || { echo "APK missing: $(DEBUG_APK) - run 'make android-debug' first."; exit 1; }
	@$(MAKE) --no-print-directory adb-check
	adb install -r $(DEBUG_APK)

# Check that a device is connected (clear message otherwise).
adb-check:
	@command -v adb >/dev/null || { echo "adb not found - install the Android Platform-Tools."; exit 1; }
	@adb get-state >/dev/null 2>&1 || { echo "No device/emulator connected (adb get-state failed)."; exit 1; }

# --- Web (Node/TypeScript backend + React frontend) -------------------------

## Build the web app: frontend (Vite) and backend (tsc) into app/*/dist.
web: app/node_modules
	npm --prefix app run build

## Install the web app dependencies (needs Node.js >= 22).
app/node_modules: app/package.json app/package-lock.json
	npm --prefix app install

# --- Clean ------------------------------------------------------------------

## Remove build artifacts of the web app and the Flutter app.
clean:
	rm -rf app/web/dist app/server/dist
	# Remove Flutter artifacts (build/, .dart_tool/, ...).
	$(CONTAINER_RUN) flutter clean

# --- Help -------------------------------------------------------------------

help:
	@echo "Targets:"
	@echo "  android[-release]   Release APK (arm64) via the Flutter container"
	@echo "  android-debug       Debug APK via the Flutter container"
	@echo "  adb-install         Install the release APK via adb (ABI=$(ABI))"
	@echo "  adb-install-debug   Install the debug APK via adb"
	@echo "  web                 Build the web app (Node/TS + React)"
	@echo "  clean               Remove build artifacts"
	@echo ""
	@echo "Variables: FLUTTER_SDK=$(FLUTTER_SDK) FLUTTER_IMG=$(FLUTTER_IMG) CONTAINER_ENGINE=$(CONTAINER_ENGINE) ABI=$(ABI)"
