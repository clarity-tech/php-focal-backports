# Local builds run in a container of the target series and architecture; the work tree is bind-
# mounted, so the build tree (several GB) lands on the host disk, not inside Docker's.
#   make build test package                       # focal, PHP 8.1: everything up to the bundle in dist/
#   make build test package PHP_BRANCH=8.3        # another branch (branches/*.env)
#   make build test package TARGET=resolute       # the same for Ubuntu 26.04 (8.1 only)
#   make test-install                             # host/install.sh simulate against the bundle
#   make upload                                   # dry run; then  make upload APPLY=1  and  make presign
# CONTAINER=<name> names the build/test container, so a watchdog can stop it.
TARGET ?= focal
PHP_BRANCH ?= 8.1
export TARGET PHP_BRANCH
# Make before 4.4 (macOS ships 3.81) does not export variables to $(shell), so pass them explicitly.
SERIES := $(shell export TARGET='$(TARGET)' PHP_BRANCH='$(PHP_BRANCH)' ROOT=.; . ./config.env && echo $$TARGET_SERIES)
ifeq ($(SERIES),)
$(error no TARGET_SERIES for TARGET=$(TARGET) PHP_BRANCH=$(PHP_BRANCH): are there targets/$(TARGET).env and branches/$(PHP_BRANCH).env?)
endif
ARCH   ?= arm64
IMAGE  ?= ubuntu:$(SERIES)
# LOCAL_TAG and MAINTAINER pass through only when set, so config.env's defaults apply otherwise.
RUN     = docker run --rm$(if $(CONTAINER), --name $(CONTAINER)) --platform linux/$(ARCH) -e TARGET=$(TARGET) -e PHP_BRANCH=$(PHP_BRANCH) -e ARCH=$(ARCH) -e BUILDER_IMAGE=$(IMAGE) -e LOCAL_TAG -e MAINTAINER -v "$(CURDIR)":/work -w /work $(IMAGE)

.PHONY: all fetch build test package test-install upload presign clean
all: build test package

fetch:
	ARCH=$(ARCH) scripts/fetch.sh

build: fetch
	$(RUN) bash scripts/build.sh

# A fresh container, so the test sees what a real host would, not the build environment.
test:
	$(RUN) bash scripts/test.sh

# host/install.sh, in simulate mode, against the bundle that `package` made, in a fresh container.
test-install:
	$(RUN) bash scripts/test_install.sh

package:
	ARCH=$(ARCH) BUILDER_IMAGE=$(IMAGE)@$$(docker image inspect -f '{{index .RepoDigests 0}}' $(IMAGE) 2>/dev/null | cut -d@ -f2) scripts/package.sh

upload:
	ARCH=$(ARCH) scripts/upload.sh $(if $(APPLY),--apply,)

presign:
	ARCH=$(ARCH) scripts/upload.sh --presign $(or $(EXPIRES),3600)

clean:
	rm -rf build dist
