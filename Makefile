# https://stackoverflow.com/questions/18136918/how-to-get-current-relative-directory-of-your-makefile
ROOT_DIR := $(dir $(realpath $(lastword $(MAKEFILE_LIST))))
SELF ::= $(firstword $(MAKEFILE_LIST))

# https://tech.davis-hansson.com/p/make/
SHELL := bash
.ONESHELL:
# http://redsymbol.net/articles/unofficial-bash-strict-mode/
# https://vaneyckt.io/posts/safer_bash_scripts_with_set_euxo_pipefail/
.SHELLFLAGS := -Eeux -o pipefail -c
.DELETE_ON_ERROR:
MAKEFLAGS += --warn-undefined-variables
MAKEFLAGS += --no-builtin-rules

# todo: leave the default recipe prefix for now
ifeq ($(origin .RECIPEPREFIX), undefined)
$(error This Make does not support .RECIPEPREFIX. Please use GNU Make 4.0 or later)
endif
.RECIPEPREFIX =

IMAGE_REGISTRY   ?= quay.io/opendatahub/base-images
RELEASE	 		 ?= 2025a
RELEASE_PYTHON_VERSION	 ?= 3.11
# additional user-specified caching parameters for $(CONTAINER_ENGINE) build
CONTAINER_BUILD_CACHE_ARGS ?= --no-cache
# whether to push the images to a registry as they are built
PUSH_IMAGES ?= yes

# OS dependant: Generate date, select appropriate cmd to locate container engine
ifdef OS
	ifeq ($(OS), Windows_NT)
		DATE 		?= $(shell powershell -Command "Get-Date -Format 'yyyyMMdd'")
		WHERE_WHICH ?= where
	endif
endif
DATE 		?= $(shell date +'%Y%m%d')
WHERE_WHICH ?= which


# linux/amd64 or darwin/arm64
OS_ARCH=$(shell go env GOOS)/$(shell go env GOARCH)
BUILD_ARCH ?= linux/amd64

IMAGE_TAG		 ?= $(RELEASE)_$(DATE)
KUBECTL_BIN      ?= bin/kubectl
KUBECTL_VERSION  ?= v1.23.11
YQ_BIN      ?= bin/yq
YQ_VERSION  ?= v4.44.6
NOTEBOOK_REPO_BRANCH_BASE ?= https://raw.githubusercontent.com/opendatahub-io/notebooks/main
REQUIRED_BASE_IMAGE_COMMANDS="curl python3"
REQUIRED_CODE_SERVER_IMAGE_COMMANDS="curl python oc code-server"
REQUIRED_R_STUDIO_IMAGE_COMMANDS="curl python oc /usr/lib/rstudio-server/bin/rserver"

# Detect and select the system's available container engine
ifeq (, $(shell $(WHERE_WHICH) podman))
	DOCKER := $(shell $(WHERE_WHICH) docker)
	ifeq (, $(DOCKER))
		$(error "Neither Docker nor Podman is installed. Please install one of them.")
	endif
	CONTAINER_ENGINE := docker
else
	CONTAINER_ENGINE := podman
endif

# Build function for the notebook image:
#   ARG 1: Image tag name.
#   ARG 2: Path of Dockerfile we want to build.
define build_image
	$(eval IMAGE_NAME := $(IMAGE_REGISTRY):$(1)-$(IMAGE_TAG))
	$(eval BUILD_ARGS :=)

	$(info # Building $(IMAGE_NAME) image...)

	$(ROOT_DIR)/scripts/sandbox.py --dockerfile '$(2)' --platform '$(BUILD_ARCH)' -- \
		$(CONTAINER_ENGINE) build $(CONTAINER_BUILD_CACHE_ARGS) --platform=$(BUILD_ARCH) --label release=$(RELEASE) --tag $(IMAGE_NAME) --file '$(2)' $(BUILD_ARGS) {}\;
endef

# Push function for the notebook image:
# 	ARG 1: Path of image context we want to build.
define push_image
	$(eval IMAGE_NAME := $(IMAGE_REGISTRY):$(subst /,-,$(1))-$(IMAGE_TAG))
	$(info # Pushing $(IMAGE_NAME) image...)
	$(CONTAINER_ENGINE) push $(IMAGE_NAME)
endef

# Build and push the notebook images:
#   ARG 1: Image tag name.
#   ARG 2: Path of Dockerfile we want to build.
#
# PUSH_IMAGES: allows skipping podman push
define image
	$(info #*# Image build Dockerfile: <$(2)> #(MACHINE-PARSED LINE)#*#...)
	$(eval BUILD_DIRECTORY := $(shell echo $(2) | sed 's/\/Dockerfile.*//'))
	$(info #*# Image build directory: <$(BUILD_DIRECTORY)> #(MACHINE-PARSED LINE)#*#...)

	$(call build_image,$(1),$(2))

	$(if $(PUSH_IMAGES:no=),
		$(call push_image,$(1))
	)
endef

#######################################        Build helpers                 #######################################

# https://stackoverflow.com/questions/78899903/how-to-create-a-make-target-which-is-an-implicit-dependency-for-all-other-target
skip-init-for := all-images deploy% undeploy% test% validate% refresh-pipfilelock-files scan-image-vulnerabilities print-release
ifneq (,$(filter-out $(skip-init-for),$(MAKECMDGOALS) $(.DEFAULT_GOAL)))
$(SELF): bin/buildinputs
endif

bin/buildinputs: scripts/buildinputs/buildinputs.go scripts/buildinputs/go.mod scripts/buildinputs/go.sum
	$(info Building a Go helper for Dockerfile dependency analysis...)
	go build -C "scripts/buildinputs" -o "$(ROOT_DIR)/$@" ./...

####################################### Buildchain for Python using ubi9 #####################################

.PHONY: cpu-ubi9-python-$(RELEASE_PYTHON_VERSION)
cpu-ubi9-python-$(RELEASE_PYTHON_VERSION):
	$(call image,$@,base/ubi9-python-$(RELEASE_PYTHON_VERSION)/Dockerfile.cpu)

.PHONY: cuda-ubi9-python-$(RELEASE_PYTHON_VERSION)
cuda-ubi9-python-$(RELEASE_PYTHON_VERSION):
	$(call image,$@,base/ubi9-python-$(RELEASE_PYTHON_VERSION)/Dockerfile.cuda)

.PHONY: rocm-ubi9-python-$(RELEASE_PYTHON_VERSION)
rocm-ubi9-python-$(RELEASE_PYTHON_VERSION):
	$(call image,$@,base/ubi9-python-$(RELEASE_PYTHON_VERSION)/Dockerfile.rocm)

####################################### Deployments #######################################

# Download kubectl binary
.PHONY: bin/kubectl
bin/kubectl:
ifeq (,$(wildcard $(KUBECTL_BIN)))
	@mkdir -p bin
	@curl -sSL https://dl.k8s.io/release/$(KUBECTL_VERSION)/bin/$(OS_ARCH)/kubectl > \
		$(KUBECTL_BIN)
	@chmod +x $(KUBECTL_BIN)
endif

# Download yq binary
.PHONY: bin/yq
bin/yq:
	$(eval YQ_RELEASE_FILE := yq_$(subst /,_,$(OS_ARCH)))
ifeq (,$(wildcard $(YQ_BIN)))
	@mkdir -p bin
	@curl -sSL https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/${YQ_RELEASE_FILE} > \
		$(YQ_BIN)
	@chmod +x $(YQ_BIN)
endif

.PHONY: deploy9
deploy9-%: bin/kubectl bin/yq
	$(eval TARGET := $(shell echo $* | sed 's/-ubi9-python.*//'))
	$(eval PYTHON_VERSION := $(shell echo $* | sed 's/.*-python-//'))
	$(eval NOTEBOOK_DIR := base/ubi9-python-$(PYTHON_VERSION)/kustomize/base)
ifndef NOTEBOOK_TAG
	$(eval NOTEBOOK_TAG := $*-$(IMAGE_TAG))
endif
	$(info # Deploying notebook from $(NOTEBOOK_DIR) directory...)
	@arg=$(IMAGE_REGISTRY) $(YQ_BIN) e -i '.images[].newName = strenv(arg)' $(NOTEBOOK_DIR)/kustomization.yaml
	@arg=$(NOTEBOOK_TAG) $(YQ_BIN) e -i '.images[].newTag = strenv(arg)' $(NOTEBOOK_DIR)/kustomization.yaml
	$(KUBECTL_BIN) apply -k $(NOTEBOOK_DIR)

.PHONY: undeploy9
undeploy9-%: bin/kubectl
	$(eval TARGET := $(shell echo $* | sed 's/-ubi9-python.*//'))
	$(eval PYTHON_VERSION := $(shell echo $* | sed 's/.*-python-//'))
	$(eval NOTEBOOK_DIR := base/ubi9-python-$(PYTHON_VERSION)/kustomize/base)
	$(info # Undeploying notebook from $(NOTEBOOK_DIR) directory...)
	$(KUBECTL_BIN) delete -k $(NOTEBOOK_DIR)

# Verify the notebook's readiness by pinging the /api endpoint and executing the corresponding test_notebook.ipynb file in accordance with the build chain logic.
.PHONY: test
test-%: bin/kubectl
	$(info # Running tests for $* notebook...)
	@./scripts/test_jupyter_with_papermill.sh $*

# Validate that base image meets minimum criteria
# This validation is created from subset of https://github.com/elyra-ai/elyra/blob/9c417d2adc9d9f972de5f98fd37f6945e0357ab9/Makefile#L325
.PHONY: validate-base-image
validate-base-image: bin/kubectl
	$(eval NOTEBOOK_NAME := $(subst .,-,$(subst cuda-,,$*)))
	$(info # Running tests for $(NOTEBOOK_NAME) runtime...)
	$(KUBECTL_BIN) wait --for=condition=ready pod runtime-pod --timeout=300s
	@required_commands=$(REQUIRED_BASE_IMAGE_COMMANDS)
	fail=0
	if [[ $$image == "" ]] ; then
		echo "Usage: make validate-runtime-image image=<container-image-name>"
		exit 1
	fi
	for cmd in $$required_commands ; do
		echo "=> Checking container image $$image for $$cmd..."
		if ! $(KUBECTL_BIN) exec runtime-pod which $$cmd > /dev/null 2>&1 ; then
			echo "ERROR: Container image $$image  does not meet criteria for command: $$cmd"
			fail=1
			continue
		fi
		if [ $$cmd == "python3" ]; then
			echo "=> Checking notebook execution..."
			if ! $(KUBECTL_BIN) exec runtime-pod -- /bin/sh -c "curl https://raw.githubusercontent.com/opendatahub-io/elyra/refs/heads/main/etc/generic/requirements-elyra.txt --output req.txt && \
					python3 -m pip install -r req.txt > /dev/null && \
					curl https://raw.githubusercontent.com/nteract/papermill/main/papermill/tests/notebooks/simple_execute.ipynb --output simple_execute.ipynb && \
					python3 -m papermill simple_execute.ipynb output.ipynb > /dev/null" ; then
				echo "ERROR: Image does not meet Python requirements criteria in pipfile"
				fail=1
			fi
		fi
	done
	if [ $$fail -eq 1 ]; then
		echo "=> ERROR: Container image $$image is not a suitable Elyra runtime image"
		exit 1
	else
		echo "=> Container image $$image is a suitable Elyra runtime image"
	fi;

# This is used primarily for gen_gha_matrix_jobs.py to we know the set of all possible images we may want to build
.PHONY: all-images
ifeq ($(RELEASE_PYTHON_VERSION), 3.11)
all-images: \
	cpu-ubi9-python-$(RELEASE_PYTHON_VERSION) \
	cuda-ubi9-python-$(RELEASE_PYTHON_VERSION) \
	rocm-ubi9-python-$(RELEASE_PYTHON_VERSION)
else ifeq ($(RELEASE_PYTHON_VERSION), 3.12)
all-images: \
	cpu-ubi9-python-$(RELEASE_PYTHON_VERSION) \
	cuda-ubi9-python-$(RELEASE_PYTHON_VERSION) \
	rocm-ubi9-python-$(RELEASE_PYTHON_VERSION)
else
	$(error Invalid Python version $(RELEASE_PYTHON_VERSION))
endif

# This is used primarily for `konflux_generate_component_build_pipelines.py` to we know the build release version
.PHONY: print-release
print-release:
	@echo "$(RELEASE)"
