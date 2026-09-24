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
APP_FRAMEWORKS = $(APP_CONTENTS)/Frameworks
APP_RESOURCES = $(APP_CONTENTS)/Resources
APP_ICON_SOURCE = $(CURDIR)/Support/AppIcon.png
APP_ICON = $(CURDIR)/.build/AppIcon.icns
APP_ICON_ASSETS = $(CURDIR)/.build/Assets.car
BUNDLE_IDENTIFIER ?= app.breakbar.mac
BUNDLE_DISPLAY_NAME ?= BreakBar
UI_TEST_APP_BUNDLE = $(CURDIR)/.build/BreakBarUITest.app
SPARKLE_FRAMEWORK = $(APP_FRAMEWORKS)/Sparkle.framework
SPARKLE_FRAMEWORK_SOURCE = $(CURDIR)/.build/out/Products/$(PRODUCTS_CONFIGURATION)/Sparkle.framework
SPARKLE_LICENSE_SOURCE = $(CURDIR)/.build/artifacts/sparkle/Sparkle/LICENSE
SWIFT_PROTOBUF_LICENSE_SOURCE = $(CURDIR)/.build/checkouts/swift-protobuf/LICENSE.txt
BUSY_PROTOBUF_LICENSE_SOURCE = $(CURDIR)/Support/ThirdPartyLicenses/BUSYProtobuf.md
SIGNING_IDENTITY ?= -

.PHONY: build bundle release-bundle test test-ui test-busybar-hardware run demo

build:
	$(SWIFT_ENV) swift build $(SWIFT_PATHS) --configuration $(CONFIGURATION)

$(APP_ICON_ASSETS): $(APP_ICON_SOURCE) $(CURDIR)/scripts/generate-app-icon.sh
	DEVELOPER_DIR=$(DEVELOPER_DIR) $(CURDIR)/scripts/generate-app-icon.sh $(APP_ICON_SOURCE) $(APP_ICON)

$(APP_ICON): $(APP_ICON_ASSETS)
	@test -f $(APP_ICON) || DEVELOPER_DIR=$(DEVELOPER_DIR) $(CURDIR)/scripts/generate-app-icon.sh $(APP_ICON_SOURCE) $(APP_ICON)

bundle: build $(APP_ICON_ASSETS) $(APP_ICON)
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_CONTENTS)/MacOS $(APP_FRAMEWORKS) $(APP_RESOURCES)/ThirdPartyLicenses
	cp $(APP_EXECUTABLE_SOURCE) $(APP_EXECUTABLE)
	ditto $(SPARKLE_FRAMEWORK_SOURCE) $(SPARKLE_FRAMEWORK)
	cp $(SPARKLE_LICENSE_SOURCE) $(APP_RESOURCES)/ThirdPartyLicenses/Sparkle.txt
	cp $(SWIFT_PROTOBUF_LICENSE_SOURCE) $(APP_RESOURCES)/ThirdPartyLicenses/SwiftProtobuf.txt
	cp $(BUSY_PROTOBUF_LICENSE_SOURCE) $(APP_RESOURCES)/ThirdPartyLicenses/BUSYProtobuf.txt
	cp $(APP_ICON) $(APP_RESOURCES)/AppIcon.icns
	cp $(APP_ICON_ASSETS) $(APP_RESOURCES)/Assets.car
	cp $(CURDIR)/Support/Info.plist $(APP_CONTENTS)/Info.plist
	plutil -replace CFBundleIdentifier -string "$(BUNDLE_IDENTIFIER)" $(APP_CONTENTS)/Info.plist
	plutil -replace CFBundleDisplayName -string "$(BUNDLE_DISPLAY_NAME)" $(APP_CONTENTS)/Info.plist
	plutil -replace CFBundleName -string "$(BUNDLE_DISPLAY_NAME)" $(APP_CONTENTS)/Info.plist
	codesign --force --sign - --identifier "$(BUNDLE_IDENTIFIER)" \
		--entitlements $(CURDIR)/Support/BreakBar.entitlements $(APP_BUNDLE)

release-bundle:
	test "$(SIGNING_IDENTITY)" != "-"
	$(MAKE) bundle CONFIGURATION=release
	codesign --force --timestamp --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Installer.xpc
	codesign --force --timestamp --options runtime \
		--preserve-metadata=entitlements \
		--sign "$(SIGNING_IDENTITY)" \
		$(SPARKLE_FRAMEWORK)/Versions/B/XPCServices/Downloader.xpc
	codesign --force --timestamp --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(SPARKLE_FRAMEWORK)/Versions/B/Autoupdate
	codesign --force --timestamp --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(SPARKLE_FRAMEWORK)/Versions/B/Updater.app
	codesign --force --timestamp --options runtime \
		--sign "$(SIGNING_IDENTITY)" \
		$(SPARKLE_FRAMEWORK)
	codesign --force --timestamp --options runtime \
		--generate-entitlement-der \
		--sign "$(SIGNING_IDENTITY)" \
		--identifier "$(BUNDLE_IDENTIFIER)" \
		--entitlements $(CURDIR)/Support/BreakBar.entitlements $(APP_BUNDLE)
	codesign --verify --deep --strict --verbose=2 $(APP_BUNDLE)

test:
	$(SWIFT_ENV) swift test $(SWIFT_PATHS)

test-ui:
	$(MAKE) bundle \
		APP_BUNDLE=$(UI_TEST_APP_BUNDLE) \
		BUNDLE_IDENTIFIER=app.breakbar.mac.uitest \
		BUNDLE_DISPLAY_NAME="BreakBar UI Tests"
	DEVELOPER_DIR=$(DEVELOPER_DIR) xcodebuild -quiet test \
		-project $(CURDIR)/Tests/BreakBarUITests/BreakBarUITests.xcodeproj \
		-scheme BreakBarUITests \
		-destination 'platform=macOS' \
		-derivedDataPath $(CURDIR)/.build/ui-test-derived \
		-parallel-testing-enabled NO

test-busybar-hardware:
	BREAKBAR_BUSYBAR_ACCEPTANCE=1 $(SWIFT_ENV) swift test $(SWIFT_PATHS) \
		--filter BusyBarHardwareAcceptanceTests/testPhysicalInputsOverUSB

run: bundle
	open -n $(APP_BUNDLE)

demo: bundle
	open -n $(APP_BUNDLE) --args --demo
