# =============================================================================
# Makefile - build of the two-part bootloader (bootloader/DESIGN.md)
#
#   make            build/starter.bin (1024 bytes, padded with 0x00 = erased flash), its size report and SHA-256
#   make test       the starter tests in the emulator (tests/test_starter.py)
#   make clean      remove build/
# =============================================================================
export LC_ALL := C
CROSS   ?= arm-none-eabi-
AS      := $(CROSS)as
LD      := $(CROSS)ld
OBJCOPY := $(CROSS)objcopy
PYTHON  ?= python3
SHA256  := $(shell command -v shasum >/dev/null 2>&1 && echo 'shasum -a 256' || echo sha256sum)
BUILD   := build

all: $(BUILD)/starter.bin

$(BUILD)/starter.o: src/starter.s | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb --fatal-warnings -o $@ $<

$(BUILD)/starter.elf: $(BUILD)/starter.o link/starter.ld
	$(LD) -T link/starter.ld -Map $(BUILD)/starter.map --no-warn-rwx-segments -o $@ $<

$(BUILD)/starter.bin: $(BUILD)/starter.elf
	$(OBJCOPY) -O binary $< $@.raw
	@size=$$(wc -c < $@.raw | tr -d ' '); echo "starter: $$size of 1024 bytes"; \
	  test $$size -le 1024 || { echo "starter larger than 1024 bytes"; exit 1; }
	@{ cat $@.raw; head -c $$((1024 - $$(wc -c < $@.raw))) /dev/zero; } > $@ && rm $@.raw
	@cd $(BUILD) && $(SHA256) starter.bin | tee starter.bin.sha256

$(BUILD):
	mkdir -p $@

test: $(BUILD)/starter.bin
	$(PYTHON) -I tests/test_starter.py

clean:
	rm -rf $(BUILD)

.PHONY: all test clean
