APP_NAME := Voxlocal
INSTALL_DIR := $(HOME)/Applications

.PHONY: build install run test clean

build:
	./scripts/bundle.sh

install: build
	@pkill -x $(APP_NAME) || true
	mkdir -p $(INSTALL_DIR)
	rm -rf $(INSTALL_DIR)/$(APP_NAME).app
	cp -R build/$(APP_NAME).app $(INSTALL_DIR)/

run: install
	open $(INSTALL_DIR)/$(APP_NAME).app

# The Command Line Tools ship the Swift Testing macro plugin in a subfolder SwiftPM doesn't search.
TESTING_PLUGINS := $(shell xcode-select -p)/usr/lib/swift/host/plugins/testing

test:
	swift test $(if $(wildcard $(TESTING_PLUGINS)),-Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS))

clean:
	rm -rf build .build
