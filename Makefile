.DEFAULT_GOAL := openvmm
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

CARGO ?= cargo
OPENVMM_ARGS ?=
OPENHCL_RECIPE ?= x64
OPENHCL_ARGS ?=

OPENVMM_STAGE := $(abspath stage/openvmm)
OPENHCL_STAGE := $(abspath stage/openhcl)

.PHONY: openvmm openhcl clean-openvmm clean-openhcl

openvmm:
	cd src/openvmm && \
		CARGO_TARGET_DIR="$(OPENVMM_STAGE)/target" \
		$(CARGO) build \
		-p openvmm \
		$(OPENVMM_ARGS)

openhcl:
	cd src/openvmm && \
		CARGO_TARGET_DIR="$(OPENHCL_STAGE)/target" \
		$(CARGO) xflowey \
		--out-dir "$(OPENHCL_STAGE)" \
		--persist-dir "$(OPENHCL_STAGE)/persist" \
		build-igvm \
		$(OPENHCL_RECIPE) \
		$(OPENHCL_ARGS)

clean-openvmm:
	rm -rf -- "$(OPENVMM_STAGE)"

clean-openhcl:
	rm -rf -- "$(OPENHCL_STAGE)"