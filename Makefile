DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
SWIFT_ENV = DEVELOPER_DIR=$(DEVELOPER_DIR) \
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/module-cache \
	SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/module-cache
SWIFT_PATHS = --disable-sandbox \
	--cache-path $(CURDIR)/.build/cache \
	--config-path $(CURDIR)/.build/config \
	--security-path $(CURDIR)/.build/security
APP_BUNDLE = $(CURDIR)/.build/BreakBar.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_EXECUTABLE = $(APP_CONTENTS)/MacOS/BreakBar

.PHONY: build bundle test run demo

build:
	$(SWIFT_ENV) swift build $(SWIFT_PATHS)

bundle: build
	mkdir -p $(APP_CONTENTS)/MacOS
	cp $(CURDIR)/.build/out/Products/Debug/BreakBar $(APP_EXECUTABLE)
	cp $(CURDIR)/Support/Info.plist $(APP_CONTENTS)/Info.plist

test:
	$(SWIFT_ENV) swift test $(SWIFT_PATHS)

run: bundle
	open -n $(APP_BUNDLE)

demo: bundle
	open -n $(APP_BUNDLE) --args --demo
