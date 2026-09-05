DEVELOPER_DIR ?= /Applications/Xcode-beta.app/Contents/Developer
CONFIGURATION ?= debug
SWIFT_ENV = DEVELOPER_DIR=$(DEVELOPER_DIR) \
	CLANG_MODULE_CACHE_PATH=$(CURDIR)/.build/module-cache \
	SWIFTPM_MODULECACHE_OVERRIDE=$(CURDIR)/.build/module-cache
SWIFT_PATHS = --disable-sandbox \
	--cache-path $(CURDIR)/.build/cache \
	--config-path $(CURDIR)/.build/config \
	--security-path $(CURDIR)/.build/security
PRODUCTS_CONFIGURATION = $(if $(filter release,$(CONFIGURATION)),Release,Debug)
APP_BUNDLE = $(CURDIR)/.build/BreakBar.app
APP_CONTENTS = $(APP_BUNDLE)/Contents
APP_EXECUTABLE = $(APP_CONTENTS)/MacOS/BreakBar
APP_EXECUTABLE_SOURCE = $(CURDIR)/.build/out/Products/$(PRODUCTS_CONFIGURATION)/BreakBar
SIGNING_IDENTITY ?= -

.PHONY: build bundle release-bundle test run demo

build:
	$(SWIFT_ENV) swift build $(SWIFT_PATHS) --configuration $(CONFIGURATION)

bundle: build
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_CONTENTS)/MacOS
	cp $(APP_EXECUTABLE_SOURCE) $(APP_EXECUTABLE)
	cp $(CURDIR)/Support/Info.plist $(APP_CONTENTS)/Info.plist
	codesign --force --sign - --identifier app.breakbar.mac \
		--entitlements $(CURDIR)/Support/BreakBar.entitlements $(APP_BUNDLE)

release-bundle:
	test "$(SIGNING_IDENTITY)" != "-"
	$(MAKE) bundle CONFIGURATION=release
	codesign --force --timestamp --options runtime \
		--generate-entitlement-der \
		--sign "$(SIGNING_IDENTITY)" \
		--identifier app.breakbar.mac \
		--entitlements $(CURDIR)/Support/BreakBar.entitlements $(APP_BUNDLE)
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

test:
	$(SWIFT_ENV) swift test $(SWIFT_PATHS)

run: bundle
	open -n $(APP_BUNDLE)

demo: bundle
	open -n $(APP_BUNDLE) --args --demo
