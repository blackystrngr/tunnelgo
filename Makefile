# TunnelGate Makefile

BINARY_NAME=tunnelgate
BUILD_DIR=bin
GO=go

.PHONY: all build clean test install

all: build

build:
	mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 $(GO) build -ldflags="-s -w" -o $(BUILD_DIR)/$(BINARY_NAME) ./cmd/$(BINARY_NAME)

test:
	$(GO) test ./...

clean:
	rm -rf $(BUILD_DIR)

install: build
	cp $(BUILD_DIR)/$(BINARY_NAME) /usr/local/bin/

# Cross‑compile for multiple platforms
release:
	mkdir -p release
	GOOS=linux GOARCH=amd64 $(GO) build -ldflags="-s -w" -o release/$(BINARY_NAME)-linux-amd64 ./cmd/$(BINARY_NAME)
	GOOS=linux GOARCH=arm64 $(GO) build -ldflags="-s -w" -o release/$(BINARY_NAME)-linux-arm64 ./cmd/$(BINARY_NAME)
	GOOS=darwin GOARCH=amd64 $(GO) build -ldflags="-s -w" -o release/$(BINARY_NAME)-darwin-amd64 ./cmd/$(BINARY_NAME)
