# Local Soulear - build helpers
#
# Targets:
#   make android-release   Release APK (arm64) via the Flutter container
#   make android-debug     Debug APK via the Flutter container
#   make adb-install       Install the built APK on a connected device
#   make web               Build the web app (Node/TS backend + React frontend)
#   make clean             Remove build artifacts of the app and the Flutter app
#   make container-stop    Stop and remove the persistent build container
#
# The Android targets run in a Podman container (image gmeligio/flutter-android),
# because a local Flutter SDK may not be installed. The web app needs Node.js
# (>= 22) locally; `adb-install` needs adb.

# --- Configuration ----------------------------------------------------------

FLUTTER_SDK ?= 3.47.3
FLUTTER_IMG ?= docker.io/gmeligio/flutter-android

CONTAINER_ENGINE ?= podman

# Name of the persistent build container. It is created once and re-used across
# builds, so the Gradle daemon and Flutter's caches stay warm (much faster than
# `podman run --rm` each time). Remove it with `make container-stop`.
CONTAINER_NAME ?= opencam-flutter

# For `adb-install`: which ABI of the release APK to install.
ABI ?= arm64-v8a

# `podman create` options for the persistent container. --userns=keep-id maps the
# image's `flutter` user (uid 1001) to the host user, so files stay host-owned;
# `:Z` only relabels SELinux. Idle command keeps it alive between builds.
CONTAINER_OPTS = --userns=keep-id:uid=1001,gid=1001 \
	-v $(CURDIR)/flutter_app:/app:Z \
	-w /app

# Android APK output (arm64) relative to flutter_app/.
APK_DIR = flutter_app/build/app/outputs/flutter-apk
RELEASE_APK = $(APK_DIR)/app-$(ABI)-release.apk
DEBUG_APK = $(APK_DIR)/app-debug.apk

.PHONY: all android-release android-debug adb-install adb-install-debug adb-check \
	web clean container-start container-stop help

all: android-release

# --- Persistent build container ---------------------------------------------

## Ensure the persistent container is running.
container-start:
	@if $(CONTAINER_ENGINE) container exists $(CONTAINER_NAME); then \
		if [ "$$($(CONTAINER_ENGINE) inspect -f '{{.State.Running}}' $(CONTAINER_NAME))" != "true" ]; then \
			echo "Starting container $(CONTAINER_NAME)"; \
			$(CONTAINER_ENGINE) start $(CONTAINER_NAME) >/dev/null; \
		fi; \
	else \
		echo "Creating container $(CONTAINER_NAME)"; \
		$(CONTAINER_ENGINE) run -d --name $(CONTAINER_NAME) $(CONTAINER_OPTS) \
			$(FLUTTER_IMG):$(FLUTTER_SDK) sleep infinity >/dev/null; \
	fi

## Run a command inside the persistent container.
## Usage: make in-container CMD="flutter analyze"
in-container: container-start
	$(CONTAINER_ENGINE) exec $(CONTAINER_NAME) $(CMD)

## Stop and remove the persistent build container.
container-stop:
	-$(CONTAINER_ENGINE) rm -f -t 2 $(CONTAINER_NAME) >/dev/null 2>&1
	@echo "Container $(CONTAINER_NAME) removed"

# --- Android (Flutter in the persistent container) --------------------------

## Build the release APK for arm64.
android:
android-release: container-start
	$(CONTAINER_ENGINE) exec $(CONTAINER_NAME) flutter build apk --release --split-per-abi --target-platform android-arm64
	@echo "APK: $(RELEASE_APK)"

## Build the debug APK for arm64.
android-debug: container-start
	$(CONTAINER_ENGINE) exec $(CONTAINER_NAME) flutter build apk --debug --target-platform android-arm64
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
	$(CONTAINER_ENGINE) exec $(CONTAINER_NAME) flutter clean 2>/dev/null || \
		echo "(no running build container - skipping 'flutter clean')"

# --- Help -------------------------------------------------------------------

help:
	@echo "Targets:"
	@echo "  android[-release]   Release APK (arm64) via the Flutter container"
	@echo "  android-debug       Debug APK via the Flutter container"
	@echo "  adb-install         Install the release APK via adb (ABI=$(ABI))"
	@echo "  adb-install-debug   Install the debug APK via adb"
	@echo "  web                 Build the web app (Node/TS + React)"
	@echo "  clean               Remove build artifacts"
	@echo "  container-start     Create/start the persistent build container"
	@echo "  container-stop      Stop and remove the build container"
	@echo ""
	@echo "Variables: FLUTTER_SDK=$(FLUTTER_SDK) FLUTTER_IMG=$(FLUTTER_IMG) CONTAINER_ENGINE=$(CONTAINER_ENGINE) ABI=$(ABI) CONTAINER_NAME=$(CONTAINER_NAME)"
