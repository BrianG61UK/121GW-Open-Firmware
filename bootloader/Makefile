# =============================================================================
# Makefile - build of the two-part bootloader (bootloader/DESIGN.md)
#
#   make            build/starter.bin (1024 bytes, padded with 0x00 = erased flash) and build/bootloader.bin (the
#                   bootloader for 0x08000400), sizes and SHA-256; build/install.bin (first install file); the
#                   bootloader image for an update over Bluetooth is build/bootloader.bin itself (the release names it
#                   blimage.bin, .github/workflows/bootloader.yml)
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
FW_OBJS := $(addprefix $(FW_OBJ)/,sd/sdio.o brd/gpio.o sys/clock.o lcd/font.o)
# the SD driver of the firmware, assembled here read-only: SD_READ_ONLY 1 leaves out the card write path, which the
# bootloader never calls (block write, write wait, ACMD22, disk_write, the write-timeout diagnosis; about 1.3 KB)
SD_SRCS := $(addprefix $(FW)/src/sd/,diskio.s sdcard.s)
SD_OBJS := $(patsubst $(FW)/src/sd/%.s,$(BUILD)/rosd_%.o,$(SD_SRCS))
# FatFs R0.16 (exFAT, long names) of the firmware, assembled here read-only (DESIGN.md G4): FF_FS_READONLY 1, no mkfs,
# FF_FS_MINIMIZE 2 (no get_fileinfo / put_utf);
# not the directory functions (ff16_dirapi.s: f_opendir, f_readdir, f_stat, f_closedir), which the bootloader never
# calls (it opens EEVBlog.bin by name), nor sd/tables_v205.o, whose only table nothing here reads (2026-11-09)
FF_SRCS := $(addprefix $(FW)/src/ff16/,ff16_low.s ff16_dir1.s ff16_dir2.s ff16_file.s)
FF_OBJS := $(patsubst $(FW)/src/ff16/%.s,$(BUILD)/ro_%.o,$(FF_SRCS))
# the inflater of the firmware (IMP-63: packed updates), the same source file as the firmware's page Ld uses
ZI_OBJS := $(BUILD)/zinf.o
BL_SRCS := $(wildcard src/bl_*.s)
BL_OBJS := $(patsubst src/%.s,$(BUILD)/%.o,$(BL_SRCS))
# the version stamped into install.bin: src/bl.inc BL_VERSION (one place; the release workflow reads it there too)
BL_VERSION ?= 0x$(shell sed -n 's/^ *\.equ BL_VERSION, *0x\([0-9A-Fa-f]*\).*/\1/p' src/bl.inc)
PY      := $(PYTHON) -I

all: $(BUILD)/starter.bin $(BUILD)/bootloader.bin $(BUILD)/install.bin

$(BUILD)/bl_%.o: src/bl_%.s src/bl.inc | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings -I src -I $(FW)/src/inc -o $@ $<

$(BUILD)/zinf.o: $(FW)/src/sys/zinf.s $(FW)/src/inc/macros.inc | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings -I $(FW)/src/inc -o $@ $<

$(BUILD)/ro_%.o: $(FW)/src/ff16/%.s $(FW)/src/inc/ff16x.inc | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings --defsym FF_FS_READONLY=1 --defsym FF_USE_MKFS=0 --defsym FF_FS_MINIMIZE=2 \
	    -I $(FW)/src/inc -o $@ $<

$(BUILD)/rosd_%.o: $(FW)/src/sd/%.s $(wildcard $(FW)/src/inc/*.inc) | $(BUILD)
	$(AS) -mcpu=cortex-m3 -mthumb -mimplicit-it=never --fatal-warnings --defsym SD_READ_ONLY=1 \
	    -I $(FW)/src/inc -o $@ $<

$(BUILD)/bootloader.elf: $(BL_OBJS) $(ZI_OBJS) $(FF_OBJS) $(SD_OBJS) $(FW_OBJS) link/bootloader.ld
	$(LD) -T link/bootloader.ld -Map $(BUILD)/bootloader.map --no-warn-rwx-segments -o $@ $(BL_OBJS) $(ZI_OBJS) $(FF_OBJS) $(SD_OBJS) $(FW_OBJS)

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
