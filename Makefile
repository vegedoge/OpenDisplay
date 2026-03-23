APP_NAME  = MyDisplay
BUILD_DIR = build
APP       = $(BUILD_DIR)/$(APP_NAME).app
SWIFT_SRC = Sources/main.swift Sources/AppDelegate.swift Sources/DisplayManager.swift
OBJC_SRC  = Sources/VirtualDisplay.m
OBJC_OBJ  = $(BUILD_DIR)/VirtualDisplay.o

.PHONY: all run install clean

all: $(APP)

$(OBJC_OBJ): $(OBJC_SRC) Sources/VirtualDisplay.h
	@mkdir -p $(BUILD_DIR)
	clang -c $(OBJC_SRC) -o $(OBJC_OBJ) -fobjc-arc -fmodules

$(APP): $(SWIFT_SRC) $(OBJC_OBJ) Resources/Info.plist
	@mkdir -p "$(APP)/Contents/MacOS"
	@mkdir -p "$(APP)/Contents/Resources"
	swiftc $(SWIFT_SRC) $(OBJC_OBJ) \
		-import-objc-header Sources/BridgingHeader.h \
		-o "$(APP)/Contents/MacOS/$(APP_NAME)" \
		-framework Cocoa \
		-swift-version 5 \
		-O
	@cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	@codesign --force --sign - "$(APP)"
	@echo "Build complete: $(APP)"

run: $(APP)
	@open "$(APP)"

install: $(APP)
	@cp -R "$(APP)" /Applications/
	@echo "Installed to /Applications/$(APP_NAME).app"

clean:
	@rm -rf $(BUILD_DIR)
