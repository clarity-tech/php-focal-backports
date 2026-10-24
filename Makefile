# Local builds run in a container of the target series and architecture; the work tree is bind-
# mounted, so the build tree (several GB) lands on the host disk, not inside Docker's.
#   make build test package                       # focal: everything up to the bundle in dist/
#   make build test package TARGET=resolute       # the same for Ubuntu 26.04
#   make upload                                   # dry run; then  make upload APPLY=1  and  make presign
# CONTAINER=<name> names the build/test container, so a watchdog can stop it.
TARGET ?= focal
export TARGET
# Make before 4.4 (macOS ships 3.81) does not export variables to $(shell), so pass TARGET explicitly.
SERIES := $(shell export TARGET='$(TARGET)' ROOT=.; . ./config.env && echo $$TARGET_SERIES)
ifeq ($(SERIES),)
$(error no TARGET_SERIES for TARGET=$(TARGET): is there a targets/$(TARGET).env?)
endif
ARCH   ?= arm64
IMAGE  ?= ubuntu:$(SERIES)
RUN     = docker run --rm$(if $(CONTAINER), --name $(CONTAINER)) --platform linux/$(ARCH) -e TARGET=$(TARGET) -e ARCH=$(ARCH) -e BUILDER_IMAGE=$(IMAGE) -v "$(CURDIR)":/work -w /work $(IMAGE)

.PHONY: all fetch build test package upload presign clean
all: build test package

fetch:
	ARCH=$(ARCH) scripts/fetch.sh

build: fetch
	$(RUN) bash scripts/build.sh

# A fresh container, so the test sees what a real host would, not the build environment.
test:
	$(RUN) bash scripts/test.sh

package:
	ARCH=$(ARCH) BUILDER_IMAGE=$(IMAGE)@$$(docker image inspect -f '{{index .RepoDigests 0}}' $(IMAGE) 2>/dev/null | cut -d@ -f2) scripts/package.sh

upload:
	ARCH=$(ARCH) scripts/upload.sh $(if $(APPLY),--apply,)

presign:
	ARCH=$(ARCH) scripts/upload.sh --presign $(or $(EXPIRES),3600)

clean:
	rm -rf build dist
