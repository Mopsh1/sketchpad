# Sketchpad — personal macOS whiteboard (SwiftUI + WKWebView hosting Excalidraw)
#
#   make deps      install xcodegen via Homebrew and the web dependencies via npm
#   make project   regenerate Sketchpad.xcodeproj from project.yml
#   make web       build the Excalidraw page into web/dist
#   make build     web, then a Release build into ./build
#   make run       build, then launch the app
#   make test      run the unit tests
#   make install   copy the built app into /Applications
#   make icon      render previews of the app icon (Sketchpad/AppIcon.icon) into build/icon-preview

APP      := build/Build/Products/Release/Sketchpad.app
XCODEGEN := xcodegen

# xcodebuild's output is piped through grep; pipefail keeps a failed build from looking successful.
SHELL       := /bin/bash
.SHELLFLAGS := -o pipefail -c

.PHONY: deps project web build run test install icon clean

deps:
	brew install xcodegen
	npm --prefix web ci

project:
	$(XCODEGEN) generate

Sketchpad.xcodeproj: project.yml
	$(XCODEGEN) generate

web/node_modules: web/package-lock.json
	npm --prefix web ci
	@touch $@

web: web/node_modules
	npm --prefix web run build

build: web Sketchpad.xcodeproj
	xcodebuild -project Sketchpad.xcodeproj -scheme Sketchpad -configuration Release -destination 'platform=macOS' -derivedDataPath build build | grep -E "error:|warning:|BUILD"

run: build
	open "$(APP)"

test: web Sketchpad.xcodeproj
	xcodebuild -project Sketchpad.xcodeproj -scheme Sketchpad -configuration Debug -destination 'platform=macOS' -derivedDataPath build test 2>&1 | grep -E "error:|✘|✔|Test run|TEST|passed|failed"

install: build
	rm -rf /Applications/Sketchpad.app
	cp -R "$(APP)" /Applications/
	@echo "Installed /Applications/Sketchpad.app"

ICTOOL := /Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool

# The icon is an Icon Composer document; edit it in Icon Composer (in Xcode.app) or by hand, then
# check every appearance here.
icon:
	mkdir -p build/icon-preview
	for r in Default Dark TintedLight TintedDark ClearLight ClearDark; do \
		"$(ICTOOL)" Sketchpad/AppIcon.icon --export-image --platform macOS --rendition $$r \
			--width 512 --height 512 --scale 1 --output-file build/icon-preview/$$r.png > /dev/null; \
	done
	@echo "Wrote build/icon-preview/*.png"

clean:
	rm -rf build web/dist web/public/fonts
