.PHONY: build release sign

build:
	swift build
	$(MAKE) sign BIN=.build/debug/transcribe-mps

release:
	swift build -c release
	$(MAKE) sign BIN=.build/release/transcribe-mps

sign:
	codesign --force --sign - --identifier com.faucherd.transcribe-mps $(BIN)
