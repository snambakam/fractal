.DEFAULT_GOAL := build-openvmm
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

CARGO ?= cargo
PROTOC ?= protoc
export PROTOC

OPENVMM_ARGS ?=
OPENHCL_RECIPE ?= x64
OPENHCL_ARGS ?=

OPENVMM_PROFILE ?= $(if $(filter --release,$(OPENVMM_ARGS)),release,debug)
OPENHCL_PROFILE ?= $(if $(filter --release,$(OPENHCL_ARGS)),release,debug)
RPMBUILD ?= rpmbuild
RPM_VERSION ?= $(shell cd src/openvmm && $(CARGO) metadata --offline --no-deps --format-version 1 | jq -r '.packages[] | select(.name == "openvmm") | .version')
RPM_RELEASE ?= 2

REPO_ROOT := $(CURDIR)
OPENVMM_STAGE := $(abspath build/stage/openvmm)
OPENHCL_STAGE := $(abspath build/stage/openhcl)
DEVENV_STAGE := $(abspath build/stage/devenv)
RPM_OUT := $(abspath build/out)

.PHONY: build-openvmm build-openhcl package-openvmm package-openhcl clean-openvmm clean-openhcl

build-openvmm:
	cd src/openvmm && \
		CARGO_TARGET_DIR="$(OPENVMM_STAGE)/target" \
		$(CARGO) build \
		-p openvmm \
		-p ohcldiag-dev \
		--features openvmm/tpm \
		$(OPENVMM_ARGS)

build-openhcl:
	cd src/openvmm && \
		CARGO_TARGET_DIR="$(OPENHCL_STAGE)/target" \
		$(CARGO) xflowey \
		--out-dir "$(OPENHCL_STAGE)" \
		--persist-dir "$(DEVENV_STAGE)/persist" \
		build-igvm \
		$(OPENHCL_RECIPE) \
		$(OPENHCL_ARGS)

package-openvmm: build-openvmm
	$(RPMBUILD) \
		-bb \
		--target x86_64 \
		--define '_topdir $(OPENVMM_STAGE)/rpm' \
		--define '_sourcedir $(OPENVMM_STAGE)/target/$(OPENVMM_PROFILE)' \
		--define '_rpmdir $(RPM_OUT)' \
		--define 'repo_root $(REPO_ROOT)' \
		--define 'package_version $(RPM_VERSION)' \
		--define 'package_release $(RPM_RELEASE)' \
		build/package/RPM/openvmm/openvmm.spec

package-openhcl: build-openhcl
	case "$(OPENHCL_RECIPE)" in x64*) ;; *) printf '%s\n' 'RPM packaging requires an x64 OpenHCL recipe' >&2; exit 1 ;; esac
	$(RPMBUILD) \
		-bb \
		--target x86_64 \
		--define '_topdir $(OPENHCL_STAGE)/rpm' \
		--define '_sourcedir $(OPENHCL_STAGE)/artifacts/build-igvm/$(OPENHCL_PROFILE)/$(OPENHCL_RECIPE)' \
		--define '_rpmdir $(RPM_OUT)' \
		--define 'repo_root $(REPO_ROOT)' \
		--define 'recipe $(OPENHCL_RECIPE)' \
		--define 'package_version $(RPM_VERSION)' \
		--define 'package_release $(RPM_RELEASE)' \
		build/package/RPM/openhcl/openhcl.spec

clean-openvmm:
	rm -rf -- "$(OPENVMM_STAGE)"

clean-openhcl:
	rm -rf -- "$(OPENHCL_STAGE)"
