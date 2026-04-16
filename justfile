lib_name := "joracle"
version := "0.1.0"

[private]
default:
    @just --list --unsorted

# Build Go shared library and copy to project root
build:
    go build -buildmode=c-shared -o lib{{lib_name}}.so .

# Vet Go sources
check:
    go vet ./...

# Run Go unit tests
go-test:
    go test ./...

# Run Janet tests (requires build first)
test: build
    jpm test

# Run all tests: Go vet + build + Janet
test-all: check build
    jpm test

# Remove build artifacts
clean:
    rm -f lib{{lib_name}}.so lib{{lib_name}}.h

# Install locally via jpm
install: build
    jpm install

# Update Go dependencies
deps:
    go mod tidy

# Bump version in project.janet
[group('release')]
bump new_version:
    sed -i 's/:version "[^"]*"/:version "{{new_version}}"/' project.janet
    @echo "Version bumped to {{new_version}}"
