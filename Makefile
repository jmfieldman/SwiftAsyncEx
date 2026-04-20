.PHONY: build test format lint

build:
	swift build

test:
	swift test

format:
	swift format --in-place --recursive Sources Tests

lint:
	swift format lint --strict --recursive Sources Tests
