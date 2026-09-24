BUNDLE=rbenv exec bundle
LANG_VAR=LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
FASTLANE=$(LANG_VAR) $(BUNDLE) exec fastlane
# Explicit --config prevents SwiftLint from picking up nested configs in
# BuildTools/.build/checkouts/ (e.g., SwiftGenPlugin's .swiftlint.yml).
SWIFTLINT_FROM_BUILDTOOLS=swiftlint lint --working-directory .. --config .swiftlint.yml --quiet
# Parse the human-readable output of simctl
SIMULATOR_NAME = $(shell xcrun simctl list devices available \
	| grep "iPhone" \
	| tail -1 | sed 's/^[[:space:]]*//' | sed 's/ *(.*) *$$//')

.PHONY: help build clean test lint lint_lenient format install_dependencies

define run_in_buildtools
	@pushd BuildTools && \
	export SDKROOT=$$(xcrun --sdk macosx --show-sdk-path) && \
	swift package plugin \
		--allow-writing-to-directory .. \
		--allow-writing-to-package-directory \
		$(1) && \
	popd
endef

help: ## Show this list of commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-30s\033[0m %s\n", $$1, $$2}'

swift_percentage: ## Swift and Obj-C percentage on the project
	./scripts/count.rb

generate_colors: ## Generate colors and themes based on themes.csv
	ruby scripts/themes/generate_themes.rb scripts/themes/theme.csv

generate_code:
	$(call run_in_buildtools,generate-code-for-resources --config ../swiftgen.yml)

lint: ## Lint the codebase
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS))

lint_lenient:
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --lenient)

build: ## Builds the Debug configuration using Xcode
	xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       -destination 'generic/platform=iOS Simulator' \
       build

clean: ## Cleans the build artifacts
	xcodebuild -project podcasts.xcodeproj \
       -scheme pocketcasts \
       -configuration Debug \
       clean

ONLY_TESTING ?= PocketCastsTests

test: ## Build and run the PocketCastsTests target with Unit Tests using Xcode
	xcodebuild test -project podcasts.xcodeproj \
	    -scheme pocketcasts \
        -only-testing:$(ONLY_TESTING) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest'

build_staging: ## Builds using the StagingDebug configuration
	xcodebuild -project podcasts.xcodeproj \
       -scheme "Pocket Casts Staging" \
       -configuration StagingDebug \
       -destination 'generic/platform=iOS Simulator' \
       build

test_staging: ## Build and run Unit Tests using the StagingDebug configuration
	xcodebuild test -project podcasts.xcodeproj \
	    -scheme "Pocket Casts Staging" \
        -only-testing:$(ONLY_TESTING) \
        -destination 'platform=iOS Simulator,name=$(SIMULATOR_NAME),OS=latest'

format: ## Lint and autocorrect linter errors
	$(call run_in_buildtools,$(SWIFTLINT_FROM_BUILDTOOLS) --autocorrect)

upload_dsyms: ## Upload dSYMs
	./scripts/upload-symbols -gsp $(HOME)/.configure/pocketcasts-ios/secrets/GoogleService-Info.plist -p ios ./podcasts.app.dSYM.zip

install_dependencies: ## Install dependencies to run this project
	bundle install

update_proto: ## Generates the protobuffer Swift files
	./scripts/update_proto.sh $(API_PATH)

external_contributor: ## Generates an empty ApiCredentials.swift so the app builds
	@cp podcasts/Credentials/ApiCredentials.tpl podcasts/Credentials/LocalApiCredentials.swift
	@sed -i '' 's/%{.*}//' "podcasts/Credentials/LocalApiCredentials.swift"
	$(info You're ready to build the app, go ahead! 🎙)

DEVICE_ID ?= 00000000-0000-0000-0000-000000000000

device: ## Builds, installs and launches on the personal iPhone (paid-team automatic signing)
	xcodebuild -project podcasts.xcodeproj \
	    -scheme pocketcasts \
	    -configuration Debug \
	    -destination 'platform=iOS,id=$(DEVICE_ID)' \
	    PRODUCT_BUNDLE_IDENTIFIER_ROOT=com.example.podcasts \
	    DEVELOPMENT_TEAM=ABCDE12345 \
	    CODE_SIGN_STYLE=Automatic \
	    PROVISIONING_PROFILE_SPECIFIER= \
	    -allowProvisioningUpdates build
	xcrun devicectl device install app --device $(DEVICE_ID) "$$(ls -dt ~/Library/Developer/Xcode/DerivedData/podcasts-*/Build/Products/Debug-iphoneos/podcasts.app | head -1)"
	xcrun devicectl device process launch --device $(DEVICE_ID) com.example.podcasts

# --- TestFlight (fork, personal paid team) ---------------------------------
# Archives a Release build with the fork's bundle-id root + entitlements override
# (same trick as `device`), then exports and uploads to App Store Connect using an
# App Store Connect API key. Key lives at $(ASC_KEY_PATH); Key ID / Issuer ID below.
TESTFLIGHT_ARCHIVE ?= $(CURDIR)/build/PocketCasts.xcarchive
TESTFLIGHT_EXPORT ?= $(CURDIR)/build/testflight-export
ASC_KEY_ID ?= KEYID12345
ASC_ISSUER_ID ?= 00000000-0000-0000-0000-000000000000
ASC_KEY_PATH ?= $(HOME)/.appstoreconnect/private/AuthKey_$(ASC_KEY_ID).p8

testflight: ## Archives a Release build and uploads it to TestFlight (paid-team automatic signing)
	xcodebuild -project podcasts.xcodeproj \
	    -scheme pocketcasts \
	    -configuration Release \
	    -destination 'generic/platform=iOS' \
	    -archivePath "$(TESTFLIGHT_ARCHIVE)" \
	    -xcconfig "$(CURDIR)/config/fork-testflight.xcconfig" \
	    PRODUCT_BUNDLE_IDENTIFIER_ROOT=com.example.podcasts \
	    DEVELOPMENT_TEAM=ABCDE12345 \
	    CODE_SIGN_STYLE=Automatic \
	    "CODE_SIGN_IDENTITY=Apple Development" \
	    PROVISIONING_PROFILE_SPECIFIER= \
	    -allowProvisioningUpdates archive
	xcodebuild -exportArchive \
	    -archivePath "$(TESTFLIGHT_ARCHIVE)" \
	    -exportPath "$(TESTFLIGHT_EXPORT)" \
	    -exportOptionsPlist "$(CURDIR)/config/exportOptions.appstore.plist" \
	    -allowProvisioningUpdates \
	    -authenticationKeyPath "$(ASC_KEY_PATH)" \
	    -authenticationKeyID "$(ASC_KEY_ID)" \
	    -authenticationKeyIssuerID "$(ASC_ISSUER_ID)"
