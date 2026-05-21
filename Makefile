VERSION ?= $(shell git describe --always --dirty 2>/dev/null || echo "dev")
LDFLAGS := -X main.version=$(VERSION)

.PHONY: build clean

build:
	go build -ldflags "$(LDFLAGS)" -o healthcheck ./cmd/healthcheck/

clean:
	rm -f healthcheck
