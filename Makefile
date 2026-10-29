# Sketchpad — personal macOS whiteboard (SwiftUI + WKWebView hosting Excalidraw)
#
#   make deps      install xcodegen via Homebrew and the web dependencies via npm
#   make project   regenerate Sketchpad.xcodeproj from project.yml
#   make web       build the Excalidraw page into web/dist
#   make build     web, then a Release build into ./build
#   make run       build, then launch the app
#   make test      run the unit tests
#   make install   copy the built app into /Applications
#   make icon      regenerate the app icon PNGs from Scripts/make-icon.swift

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

icon:
	swift Scripts/make-icon.swift Sketchpad/Assets.xcassets/AppIcon.appiconset

clean:
	rm -rf build web/dist web/public/fonts
