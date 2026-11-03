# =============================================================================
# Makefile - build of the 121GW replacement firmware (DESIGN.md 9.1)
#
#   make                  image + all build checks (build/EEVBlog.bin, its SHA-256, check report)
#   make image            image only (assemble, link, convert, pad, size check, SHA-256)
#   make check            build checks of DESIGN.md 9.3 on the linked image (needs the original v2.05 image, inputs/)
#   make check-ci         the checks that do not need the original v2.05 image (what the GitHub workflow runs); every
#                         check it cannot run is named in the output as SKIPPED with the reason, never passed silently
#   make listing          objdump -d -S of the ELF (build/121gw.lst)
#   make clean            remove build/
#   make LOOP_V205=1      verification baseline (any switch of src/inc/config.inc can be given this way)
#
# Every switch set builds its objects and its ELF in its own directory build/obj/<switches> (make compares
# file times with a resolution of one second, so a shared object directory could keep objects of another switch
# set); the selected image is then copied to build/121gw.elf, build/121gw.map and build/EEVBlog.bin.
# Reproducible: no timestamps or paths enter the image (as/ld add none with these options), objects are linked in
# sorted path order (LC_ALL=C), the tool versions are checked and printed.
# =============================================================================

export LC_ALL := C

CROSS   ?= arm-none-eabi-
AS      := $(CROSS)as
LD      := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy
OBJDUMP := $(CROSS)objdump
PYTHON  ?= python3
PY      := $(PYTHON) -I

BINUTILS_VERSION := 2.46

# SHA-256 tool: shasum (macOS, Perl) or sha256sum (GNU coreutils)
SHA256  := $(shell command -v shasum >/dev/null 2>&1 && echo 'shasum -a 256' || echo sha256sum)

BUILD   := build
LDS     := link/121gw.ld

# switches: every line of config.inc with the marker "SWITCH <name> default <value>"
SWITCH_LINES := $(shell sed -n 's/.*@ SWITCH \([A-Z0-9_]*\) default \([0-9xA-Fa-f]*\).*/\1=\2/p' src/inc/config.inc)
SWITCH_NAMES := $(foreach s,$(SWITCH_LINES),$(firstword $(subst =, ,$(s))))
switch_default = $(word 2,$(subst =, ,$(filter $(1)=%,$(SWITCH_LINES))))
# a switch given on the make command line with a value other than its default is passed to the assembler (an
# environment variable of the same name is ignored, so an exported DEBUG cannot change the image); the set of these
# switches names the object directory
GIVEN_SWITCHES := $(foreach n,$(SWITCH_NAMES),$(if $(filter command line,$(origin $(n))),$(n)))
NONDEFAULT := $(foreach n,$(GIVEN_SWITCHES),$(if $(filter $($(n)),$(call switch_default,$(n))),,$(n)=$($(n))))
DEFSYMS := $(foreach s,$(NONDEFAULT),--defsym $(s))
empty :=
space := $(empty) $(empty)
SWKEY   := $(if $(NONDEFAULT),$(subst $(space),_,$(strip $(NONDEFAULT))),default)

OBJDIR  := $(BUILD)/obj/$(SWKEY)
OELF    := $(OBJDIR)/121gw.elf
OMAP    := $(OBJDIR)/121gw.map
ELF     := $(BUILD)/121gw.elf
MAP     := $(BUILD)/121gw.map
BIN     := $(BUILD)/EEVBlog.bin
SHA     := $(BUILD)/EEVBlog.bin.sha256
REPORT  := $(BUILD)/check_report.txt

# every source file of every module, in sorted path order
SRCS    := $(sort $(wildcard src/*/*.s))
OBJS    := $(patsubst src/%.s,$(OBJDIR)/%.o,$(SRCS))

ASFLAGS := -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings -I src/inc $(DEFSYMS)
LDFLAGS := -T $(LDS) --build-id=none -Map $(OMAP) --no-undefined -nostdlib

# build-check tools (DESIGN.md 9.3; firmware/tools, owners W7 and W10).  check_image.py (items 1, 2, 5) and check_gpio.py
# (item 4 and the brd_fe_table comparison of item 3) need Python 3 with Capstone; check_hy.py (items 3 and 4, HY3131
# write whitelist) needs Capstone and Unicorn.  Run `make PYTHON=<python with both modules>` when the default python3
# lacks Unicorn; a missing module stops the check with exit status 2, never a silent pass.  Each tool takes the ELF
# and finds the linker map (build/121gw.map) and DESIGN.md itself; tools/check_image.py --v205 runs the same
# instruction analysis on the original image (documented in its header).
CHECK_TOOLS := tools/check_image.py tools/check_hy.py tools/check_gpio.py tools/gen_nvm_allow.py \
               tools/gen_ram_symbols.py tools/extract_tables.py

.PHONY: all image check check-ci listing clean toolcheck switches

all: image check

toolcheck:
	@for t in $(AS) $(LD) $(OBJCOPY); do \
	  v=`$$t --version | head -1`; echo "$$v"; \
	  case "$$v" in *" $(BINUTILS_VERSION)"*) ;; *) echo "error: $$t is not binutils $(BINUTILS_VERSION)"; exit 1;; esac; \
	done

switches:
	@echo "build switches: $(if $(NONDEFAULT),$(NONDEFAULT),all at their defaults)"

# every object depends on every include file.  A source that tests a build switch of config.inc (LOOP_V205) must include
# config.inc: without it the assembler takes the undefined symbol silently and assembles the wrong branch of the .if
# (func/hold.s lacked the include until 2026-11-03), so such a file stops the build here.
$(OBJDIR)/%.o: src/%.s $(wildcard src/inc/*.inc) Makefile
	@mkdir -p $(dir $@)
	@if grep -q 'LOOP_V205' $< && ! grep -q '\.include "config.inc"' $<; then \
	  echo "$<: tests LOOP_V205 but does not .include \"config.inc\""; exit 1; fi
	$(AS) $(ASFLAGS) -o $@ $<

$(OELF): $(OBJS) $(LDS)
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

# the image of this switch set becomes build/121gw.elf, build/121gw.map and build/EEVBlog.bin: raw binary padded
# with 0x00 to a multiple of 4, at most 0x5A000 bytes (DESIGN.md 2.2); then its SHA-256
image: toolcheck switches $(OELF)
	@cp $(OELF) $(ELF)
	@cp $(OMAP) $(MAP)
	$(OBJCOPY) -O binary $(ELF) $(BIN)
	@size=`wc -c < $(BIN) | tr -d ' '`; pad=$$(( (4 - size % 4) % 4 )); \
	if [ $$pad -ne 0 ]; then head -c $$pad /dev/zero >> $(BIN); fi; \
	size=`wc -c < $(BIN) | tr -d ' '`; \
	if [ $$size -gt 368640 ]; then echo "error: $(BIN) is $$size bytes, limit 0x5A000"; rm -f $(BIN); exit 1; fi; \
	echo "$(BIN): $$size bytes"
	@cd $(BUILD) && $(SHA256) EEVBlog.bin > EEVBlog.bin.sha256 && cat EEVBlog.bin.sha256

# DESIGN.md 9.3: every check runs on every build; a missing tool is an error, never a silent skip
check: image
	@missing=0; for t in $(CHECK_TOOLS); do \
	  if [ ! -f $$t ]; then echo "error: build check tool $$t is missing"; missing=1; fi; done; \
	if [ $$missing -ne 0 ]; then exit 1; fi
	@echo "build switches: $(if $(NONDEFAULT),$(NONDEFAULT),all at their defaults)" > $(REPORT)
	$(PY) tools/check_image.py $(ELF) $(BIN) $(foreach s,$(NONDEFAULT),--switch $(s)) >> $(REPORT)
	$(PY) tools/check_hy.py $(ELF) >> $(REPORT)
	$(PY) tools/check_gpio.py $(ELF) >> $(REPORT)
	$(PY) tools/gen_nvm_allow.py --check >> $(REPORT)
	$(PY) tools/gen_ram_symbols.py --check >> $(REPORT)
	$(PY) tools/extract_tables.py --verify --elf $(ELF) >> $(REPORT)
	@cat $(REPORT)

# CI-safe variant of `check`: the original v2.05 image (inputs/binaries/EEVBlog2_05.bin) and the analysis/ files are not
# in the repository, so the checks that compare the port with them cannot run here.  What runs:
#   check_image.py (DESIGN.md 9.3 items 1, 2, 5, 6, 7: instruction-level never-brick analysis of the linked image)
#   check_hy.py --reference-data tools/hy_reference.txt (HY3131 write whitelist: the v2.05 sweep is read from the committed
#       reference data instead of being executed from the image; its check 1, tables equal the image, is SKIPPED by the tool)
#   check_gpio.py (pin policy, brd_fe_table against tools/fe_levels.txt)
# What does not run, and is printed as SKIPPED: gen_nvm_allow.py --check, gen_ram_symbols.py --check and
# extract_tables.py --verify, which regenerate or compare against the original image.  Run `make check` with the image
# before a release to cover them.  A failing check stops the build with its output shown.
CI_SKIPPED := tools/gen_nvm_allow.py --check|tools/gen_ram_symbols.py --check|tools/extract_tables.py --verify --elf $(ELF)

define runcheck
$(PY) $(1) > $(BUILD)/.check.tmp 2>&1; rc=$$?; tee -a $(REPORT) < $(BUILD)/.check.tmp; rm -f $(BUILD)/.check.tmp; \
if [ $$rc -ne 0 ]; then echo "check FAILED (status $$rc): $(PY) $(1)"; exit $$rc; fi
endef

check-ci: image
	@missing=0; for t in $(CHECK_TOOLS) tools/hy_reference.txt tools/fe_levels.txt; do \
	  if [ ! -f $$t ]; then echo "error: build check file $$t is missing"; missing=1; fi; done; \
	if [ $$missing -ne 0 ]; then exit 1; fi
	@echo "build switches: $(if $(NONDEFAULT),$(NONDEFAULT),all at their defaults)" > $(REPORT)
	@$(call runcheck,tools/check_image.py $(ELF) $(BIN) $(foreach s,$(NONDEFAULT),--switch $(s)))
	@$(call runcheck,tools/check_hy.py $(ELF) --reference-data tools/hy_reference.txt)
	@$(call runcheck,tools/check_gpio.py $(ELF))
	@echo "$(CI_SKIPPED)" | tr '|' '\n' | while read -r c; do \
	  echo "SKIPPED $$c: needs the original v2.05 image and the analysis/ files, which are not in the repository" | tee -a $(REPORT); done
	@echo "check-ci: 3 checks passed, 3 SKIPPED (listed above); the SKIPPED ones need the original image: run 'make check' with it before a release" | tee -a $(REPORT)

listing: image
	$(OBJDUMP) -d -S $(ELF) > $(BUILD)/121gw.lst

clean:
	rm -rf $(BUILD)
