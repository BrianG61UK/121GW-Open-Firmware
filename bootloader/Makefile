# =============================================================================
# Makefile - build of the two-part bootloader (bootloader/DESIGN.md)
#
#   make            build/starter.bin (1024 bytes, padded with 0x00 = erased flash) and build/bootloader.bin (the
#                   bootloader for 0x08000400), sizes and SHA-256; build/install.bin (first install file) and
#                   build/blimage.bin (bootloader image for an update over Bluetooth)
#   make test       the emulator tests: starter, bootloader, first install (tests/test_*.py; the first-install test
#                   needs EEVblog's bootloader images, which are not in the repository)
# The bootloader links objects of the firmware build (SD driver, FatFs R0.16, GPIO, clock, LCD font): `make` in
# firmware/ first.
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

FW      := ../firmware
FW_OBJ  := $(FW)/build/obj/default
FW_OBJS := $(addprefix $(FW_OBJ)/,sd/diskio.o sd/sdcard.o sd/sdio.o sd/tables_v205.o brd/gpio.o sys/clock.o lcd/font.o)
# FatFs R0.16 (exFAT, long names) of the firmware, assembled here read-only (DESIGN.md G4): FF_FS_READONLY 1, no mkfs
FF_SRCS := $(addprefix $(FW)/src/ff16/,ff16_low.s ff16_dir1.s ff16_dir2.s ff16_file.s ff16_dirapi.s)
FF_OBJS := $(patsubst $(FW)/src/ff16/%.s,$(BUILD)/ro_%.o,$(FF_SRCS))
BL_SRCS := $(wildcard src/bl_*.s)
BL_OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(BL_SRCS))
BL_VERSION ?= 0x00010102
PY      := $(PYTHON) -I

all: $(BUILD)/starter.bin $(BUILD)/bootloader.bin $(BUILD)/install.bin

$(BUILD)/bl_%.o: src/bl_%.s src/bl.inc | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings -I src -I $(FW)/src/inc -o $@ $<

$(BUILD)/ro_%.o: $(FW)/src/ff16/%.s $(FW)/src/inc/ff16x.inc | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings --defsym FF_FS_READONLY=1 --defsym FF_USE_MKFS=0 \
	    -I $(FW)/src/inc -o $@ $<

$(BUILD)/bootloader.elf: $(BL_OBJS) $(FF_OBJS) $(FW_OBJS) link/bootloader.ld
	$(LD) -T link/bootloader.ld -Map $(BUILD)/bootloader.map --no-warn-rwx-segments -o $@ $(BL_OBJS) $(FF_OBJS) $(FW_OBJS)

$(BUILD)/bootloader.bin: $(BUILD)/bootloader.elf
	$(OBJCOPY) -O binary -j .text -j .ramcode $< $@
	@size=$$(wc -c < $@ | tr -d ' '); echo "bootloader: $$size of 23296 bytes"; test $$size -le 23296
	@cd $(BUILD) && $(SHA256) bootloader.bin | tee bootloader.bin.sha256

$(BUILD)/install.bin: $(BUILD)/starter.bin $(BUILD)/bootloader.bin tools/blimage.py
	$(PY) tools/blimage.py install $(BUILD)/starter.bin $(BUILD)/bootloader.bin $(BL_VERSION) $@


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

test: all
	$(PYTHON) -I tests/test_starter.py
	$(PYTHON) -I tests/test_bootloader.py
	$(PYTHON) -I tests/test_first_install.py

clean:
	rm -rf $(BUILD)

.PHONY: all test clean
