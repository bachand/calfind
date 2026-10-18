.PHONY: build debug release test format lint clean

build:
	swift build

debug: build

release:
	swift build -c release

test:
	swift test

format:
	swift package --allow-writing-to-package-directory format

lint:
	swift package --allow-writing-to-package-directory format --lint

clean:
	swift package clean
