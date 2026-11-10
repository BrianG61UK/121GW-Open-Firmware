# Bootloader v2: design (owner go 2026-11-04; nothing is built or flashed yet)

The meter's bootloader occupies 0x08000000..0x08005FFF and starts the application at 0x08006000.  Until 2026-11-04 it was
out of scope (fixed in every meter).  The owner dumped his meter over SWD (OpenOCD, CMSIS-DAP; read-out protection off),
which makes a replacement possible.  This document is the design to be critiqued before anything is written.

## 1. The meter's present bootloader (facts)

Two builds are known, both 24576 bytes, both FatFs of the R0.0x generation (FAT12/16/32, no exFAT):

| Build | Source | SHA-256 |
|---|---|---|
| 2018 read-out | github.com/tpwrules/121gw-re `binaries/bootloader.bin` (analysed for FEATURES.md 2.10) | 2d80fb01... |
| owner's meter | SWD dump 2026-11-04 (`inputs/binaries/dump_2026-11-04_bootloader.bin`, not in git) | 1f0aa301... |

They differ in one function only: the owner's build drives PF15 (BT_CTL, the BLE module supply, DESIGN.md 2.x pin list)
high before the key test (0x0800443A..0x08004442, GPIOF BSRRL) and low again before the card is started
(0x08004936..0x0800493C, BSRRH), and makes PF15 an output (GPIOF mask 0x87C0 at 0x080043F2).  Everything else is the same
code moved by 0, 8, 16 or 20 bytes.  Behaviour of the owner's build (addresses of that build):

1. Update mode only by keys at reset: GPIOG IDR (0x40021C10) at 0x08004874..0x080048BA, MEM PG11 and HOLD PG13 low, then
   SETUP PG9 low within the wait loop 0x080048E4..0x08004912 (count compared with 201 at 0x08004906; the count is
   advanced by the TIM handler 0x08004DE8 through 0x200008A2).  No RAM, EEPROM, RTC backup register or reset flag decides.
2. File "EEVBlog.bin" (0x08004F08) in the card root, f_mount 0x08002D38 + f_open 0x08002D84 (FA_READ) in 0x08004A9A; card
   start retried 768 times (0x08004AC8).  A failed open returns to the wait loop: nothing is erased.
3. Erase 0x08006000..0x0805FFFF in 0x100 steps (0x08004BA0, loop while address < 0x0805FF01, literal 0x08004BC4), then f_read in 512-byte chunks and program (0x08004BC8).
   The erase and f_read results are ignored; only the program result is checked; the file size comes from FIL+12.
4. Image check: only `[0x08006000] & 0x2FFE0000 == 0x20000000` (0x080049A4..0x080049B0), else `b .` (hang, 0x080049D0).
   So a truncated file, or one whose reads failed, is programmed and started.  A file larger than the erased range is not
   refused.
5. Start: MSP from 0x08006000, branch to the reset vector at 0x08006004.
6. Texts on the LCD: "-IAP-", "douun", " Good", " FAIL".  No version string exists.
7. Nothing is ever erased or written below 0x08006000.
8. Option bytes: if the USER option byte's BOR level is not 0, it writes BOR level 0 and launches an option-byte reload
   (0x08004168..0x0800418E, `tst.w r0,#15`).  The owner's meter has USER byte 0xF0 (BOR 0, option-byte dump offset 4),
   so the branch is skipped there.  The data EEPROM is never addressed (no 0x0808xxxx literal, PECR DATA never set).
9. FLASH PELOCK and PRGLOCK are unlocked at every boot and left unlocked for the application.

### 1.1 Inventory and hand-over state

Complete inventory of the owner's build (231 functions, every vector, data region and the RAM programmer), static
analysis kept outside the repository (work folder `bootloader/inventory.md`).  Totals of the 24576 bytes: vector table
292, reachable code 19302 (library-style 13712: SD/SDIO/DMA, FatFs 8.3-only build, ST-style peripheral drivers;
bootloader's own 5590), RAM-resident half-page programmer 260 (copied from 0x08005048 to 0x20000000, entered through
0x08004B88), unreferenced trampolines 48, literal pools 708, tables and strings 157 (two LCD font tables at
0x08004E60/0x08004E7C/0x08004EFC, the five strings), padding 45, free 3764.  About 2.1 KB of the reachable code never
runs in the real flow (FatFs/SD write helpers; HSI and voltage branches behind flags main sets to constants).

State handed to the application at 0x08006000, which the original v2.05 relies on until it sets VTOR (0x08024B4A):
- SYSCLK = HSE direct, PLL on and not selected; VTOR = 0x08000000; interrupts enabled;
- TIM2 running, update interrupt on (IRQ28); its handler writes RAM byte 0x200008A2; NVIC IRQ28, IRQ45 (SDIO) and
  IRQ53 (DMA2 channel 4) enabled.  The 54 other vectors are `b.w .` loops;
- RCC_CSR.RTCRST pulsed and LSI selected as RTC clock at every boot (resets the RTC domain and its backup registers);
- FLASH_PECR unlocked (PELOCK, PRGLOCK clear);
- LCD with all segments on; PF15 high, or low if the update path ran;
- RAM 0x20000000..0x200008A7 overwritten at every boot (programmer copy, zeroed work area).

The strict port reproduces all of it bit for bit; the optimised build keeps every item of this list unless a numbered
entry changes it and its effect on v2.05 and on this project's builds is tested in the emulator.

## 2. Goals, in order

| # | Goal | Why |
|---|---|---|
| G1 | Never program a bad image: read the whole file and check size, header and every read before erasing; verify the flash against the file after programming; mark the application valid only then | the present bootloader programs truncated or unreadable files and starts them |
| G2 | Never start an invalid application: keep update mode (and show it) while the valid mark is missing | a power loss during programming then leaves a meter that waits for a good file, not a crashed one |
| G3 | Update without keys: the application leaves a request in an RTC backup register (non-zero magic, and for a card update the file's CRC; PWR clock and DBP needed) and resets by SYSRESETREQ (a system reset leaves the backup registers, RM0038 20.6.20, but RTCRST clears them, and the present bootloader and the application pulse RTCRST, DESIGN.md 2.1/3.1, so the new bootloader reads and clears the request before its own RTCRST); no card or no file: start the application if its mark is valid | the companion's "Update now" can end with the meter installing by itself |
| G4 | exFAT and large cards: FatFs R0.16 read-only with exFAT | cards of 64 GB and more are sold exFAT-formatted |
| G5 | Update over Bluetooth into the bootloader (no SD card) | later stage, needs G1/G2 first; largest code |
| G6 | Configurable key-window timeout | owner request |

Kept: the key sequence, the file name, the LCD texts, PF15 as in the owner's build, the data EEPROM never touched.
The bootloader is for the fast build (owner, 2026-11-04): it starts this project's firmware, which does not depend on
the old bootloader's hand-over state (emulator/app.py DIRECT_BOOT_NOTE, firmware/DESIGN.md 2.1); the original v2.05
application is not a target (it relies on that state until it sets VTOR).

## 3. Approach

Owner decision 2026-11-04 (replaces the strict port first planned): no strict port; the bootloader is written for the
fast build only, from this project's own modules.  What the old bootloader does is kept as behaviour, from the
inventory (section 1.1): the key sequence, the file name, the LCD texts, PF15 as in the owner's build; nothing of its
code is copied.  The new bootloader:
- reuses the project's SD driver (`src/sd`) and the FatFs R0.16 translation (`src/ff16`, read-only configuration plus
  the exFAT routines, translated and checked against ChaN's C with the existing differential harness);
- the "valid application" mark: the last 256-byte page of the application area (0x0805FF00..0x0805FFFF).  The present
  bootloader erases it with the rest, and today's linker limit (0x5A000, link/121gw.ld) still lets an image reach it, so
  the limit becomes 0x4C000 (slots above it, section 6.1) (link script, DESIGN.md 2.2, companion check_image, bft.s) and the bootloader refuses larger
  files.  The mark holds a non-zero magic, the image length, the image CRC-32 and a CRC of the mark itself (a power cut
  while the mark is written leaves a mark that fails its own check).  Order of an update: erase the mark page first, then
  the image pages, program, verify against the file, write the mark last.  At boot only the mark's own check is made
  (the full-image CRC would cost time and shift the hand-over timing, section 1.1);
- migration: no installed application has a mark (the owner's dump is 0x00 over 0x0805FE00..0x0805FFFF).  Before the new
  bootloader is flashed, the owner writes the mark for his installed application over SWD (length and CRC computed from
  dump_2026-11-04_firmware_app.bin and the image's real length); without that the meter would stay in update mode;
- source on its own branch `bootloader` (build, emulator tests, the restore procedure), so `main` stays the application.

Size budget (bytes, measured from the present builds; bootloader area 24576):

| Part | Estimate | Basis |
|---|---|---|
| SD driver (read only) | about 5500 | sdcard.o + sdio.o + diskio.o 7916 incl. write paths |
| FatFs R0.16 read-only | about 3500 | ff16 objects 6680 incl. write, unlink, rename |
| exFAT routines | unknown | the ff16 translation has FF_FS_EXFAT 0 and FF_USE_LFN 0; ChaN's exFAT needs LFN support and buffers: to be measured from ChaN's C before G4 is accepted |
| flash erase / program / verify, CRC-32 | about 1000 | half-page programming runs only from SRAM (RM0038), so this routine is copied to RAM; SDIO/DMA interrupts masked while it runs; erased flash reads 0x00, never test for 0xFF |
| clocks, GPIO, keys, LCD texts, timer | about 2500 | present bootloader's own parts |
| vector table, start-up | about 400 | |
| total without Bluetooth and exFAT | about 12900 | the present bootloader uses 0x514C = 20812 bytes |

The SD driver is not reusable unchanged: it uses fixed application RAM addresses (sdcard.s) and the application's clock routine; the bootloader version gets its own RAM map and keeps the card-start retries.

## 4. Safety

- Development and every test in the emulator first (it boots through a bootloader image at 0x08000000): all paths with
  induced faults (no card, no file, truncated file, read error at every chunk, power cut at every step of erase and
  program, invalid header, oversized file), with the original application and this project's builds.
- Before the first flash: the owner's restore drill, tested: write his own dump back over SWD and compare
  (`flash write_image erase dump_2026-11-04_bootloader.bin 0x08000000`, `verify_image`).  The option bytes are not changed
  (read-out protection stays off, no write protection), so SWD always works.
- Development builds are flashed by the owner over SWD first.  Users get it only through the companion with the
  two-part scheme of section 6 (owner decision 2026-11-04, section 5 item 5).
- The data EEPROM (calibration, serial, settings) is never written by the bootloader.
- SWD flashing rules: back up the EEPROM dump and re-read the EEPROM after every bootloader write (compare with the
  backup); never `mass_erase`, never an option-byte command; connect under reset if the core does not halt.  The
  bootloader never reconfigures PA13/PA14 (SWD), so a meter with a bad bootloader stays reachable over SWD.

## 5. Owner decisions (2026-11-04)

1. Order G1..G6 as in section 2; G5 (Bluetooth into the bootloader) is wanted.
2. G6: key window 30 s (today 201 TIM2 ticks of 161161 clocks, about 8 s if the crystal is 4 MHz as the schematic
   text says, unproven).  The window only runs after MEM + HOLD were held at reset, so a normal start is not slowed.
3. Source on its own branch `bootloader`.
4. Firmware update flow (owner): the companion asks the running firmware to restart into update mode (G3 request);
   the bootloader switches the BLE module on, the companion connects and sends the firmware over Bluetooth (G5); the
   bootloader programs it, checks it and restarts into the new firmware.  No card and no keys needed; the card and key
   path stays as it is.
   - Before the first data block arrives nothing is erased; if the companion does not connect within the window, the
     old firmware starts again (its mark is still valid).
   - The image cannot be held in RAM (48 KB against images up to 0x4C000), so it is written as it arrives: mark page
     erased first, every block checked (bft CRC-16 as ble/bft.s), whole-image CRC-32 compared with the companion's
     value at the end, flash read back, mark written last.  A transfer that breaks off leaves no mark: the bootloader
     stays in update mode (BLE on, "-IAP-") and the companion can simply send again, or a card can be used.  The
     bootloader itself is never touched by a firmware update, so this path cannot brick the meter.
5. Bootloader update from the companion as well (firmware, bootloader or both), the way users will do it: no SWD
   (SWD needs a cut-out in the case).  The one-time risk of the first install (a power cut during the starter write)
   is accepted with a battery check before it.  The owner tests it on his meter exactly that way; his SWD connection is
   only the fallback.  Design in section 6.
6. Accepted with section 6: firmware limit 0x4C000 (304 KB); the application may write flash only in slot A, slot B,
   the control area and, at the first install, 0x08000000..0x080003FF, bounds checked in code (DESIGN.md rule and
   build check 9.3 change with the implementation); BLE off after 10 minutes in update mode without a connection.
7. The meter formats the SD card as exFAT (owner, 2026-11-04).  The application gets FatFs R0.16 with FF_FS_EXFAT 1
   (needs FF_USE_LFN, ChaN's ff.c) and f_mkfs; the bootloader reads exFAT (G4).  A card formatted as exFAT cannot be
   read by EEVblog's bootloader, so the meter offers the format only when the new bootloader is installed (its mark
   valid), else the key / card update path of the old bootloader would be lost.  Formatting erases the card: it needs
   a confirmation on the meter.  The application's rule "no reformat without approval" (firmware/DESIGN.md) is changed
   by this decision.
8. Bluetooth transfer into the bootloader allows two packets in flight.  Measured on the owner's meter (page Ld,
   2026-11-04, 15 round trips each): 9-byte packet answered in 60..120 ms (median 90, 30 ms steps of the BLE link),
   240-byte packet in 209..240 ms (median 210); the 240 bytes take 125 ms on USART2 at 19200 baud.  Stop and wait gives
   232 bytes / 210 ms = 1.1 KB/s (as measured for 2.10: 155 kB in 159..172 s); two in flight are limited by USART2,
   232 bytes / 125 ms = 1.8 KB/s, about 85..90 s for 155 kB (calculated, to be measured).

## 6. Two-part bootloader and bootloader update from the companion

Facts used (copies on disk: RM0038, DS8576, PM0056 in the work folder):
- program and erase time per page, word or half-page: 3.28 ms typical, 3.94 ms maximum (DS8576 Table 35); page 256
  bytes, half-page 128 bytes; erased flash reads 0x00;
- half-page programming only from SRAM, from external memory, or from one bank into the other (RM0038 3.4.3); bank 1
  is 0x08000000..0x0802FFFF, bank 2 0x08030000..0x0805FFFF (192 KB each);
- VTOR: the table offset must be aligned to the number of entries, at least 128 words, so bits 8..0 are zero (PM0056
  4.4.4); the bootloader's table has 73 entries, so it needs a 512-byte boundary;
- the old bootloader's start without keys uses nothing in 0x08000100..0x080003FF: that range holds vector entries
  IRQ48..IRQ56 (none enabled on that path) and SD functions from 0x08000124 used only by the update path (inventory:
  SD_Init 0x08000124 called from 0x0800323E and 0x08004B06, SD_PowerON 0x08000232 from SD_Init);
- the old bootloader's reset handler is at 0x08004EEC, its code fills 0x08000124..0x0800514B (inventory), so changing
  any page of it breaks the old start.

### 6.1 Flash layout

| Area | Range | Written by |
|---|---|---|
| Starter | 0x08000000..0x080003FF (four pages, 688 bytes used) | first install only, never again |
| Bootloader | 0x08000400..0x08005EFF (23296 bytes), vector table at 0x08000400 | the starter, from a slot |
| Bootloader mark | 0x08005F00..0x08005FFF (length, CRC-32, self-CRC; erased first, written last) | the starter |
| Firmware | 0x08006000..0x08051FFF (limit 0x4C000 = 311296 bytes; v2.05 144616, F-1.02 155464) | the bootloader |
| Slot A, slot B | 0x08052000..0x08057FFF and 0x08058000..0x0805DFFF (24 KB each, image + header with length, CRC-32, version) | the bootloader (6.3) or, at the first install, the firmware (6.4) |
| Control area | 0x0805E000..0x0805FEFF: records of 16 bytes (magic, command, slot, CRC-32) appended into erased words, the last valid one counts: INSTALL slot, TRIAL previous slot, OK | bootloader, firmware, starter |
| Firmware mark | 0x0805FF00..0x0805FFFF | the bootloader |

The firmware erase range of the new bootloader stops at 0x08051FFF, so a firmware update never touches the slots, the
control area or the bootloader.  All marks and the request live in flash, so the starter needs no RTC code.

### 6.2 The starter (src/starter.s, 688 of 1024 bytes)

At every reset, with interrupts off and on the reset clock (MSI):
1. read the control area and the bootloader mark (the mark is checked, not a CRC over the 24 KB bootloader);
2. last record INSTALL and the slot's header and CRC-32 valid: erase the mark page, then 0x08000400..0x08005EFF, copy
   the slot with half-page programming from a routine copied to RAM (target bank 1, routine in SRAM: allowed),
   compare, write the mark (copy of the slot header) last, append TRIAL (previous = the other slot).  Slot invalid:
   append OK.  Time for a full 23296-byte image: 92 page erases + 182 half-pages, about 0.9 s typical, 1.1 s maximum;
   emulator, 12345-byte image: 0.95 s with 198 operations.  A power cut repeats it at the next reset;
3. last record TRIAL (the new bootloader never confirmed, see 6.3): install the previous slot the same way, append OK;
4. bootloader mark valid: lock FLASH_PECR, set VTOR to 0x08000400, start the bootloader (MSP and reset vector);
   else, with a valid slot: install it as in 2; with nothing valid: wait with the LCD off (only SWD helps; this needs
   both the bootloader and both slots to be bad).

### 6.3 Bootloader update from the companion (every time after the first install)

The companion restarts the meter into update mode (G3) and sends the image over Bluetooth with the bft protocol (new
transfer kind "bootloader image"; per-block CRC-16, end CRC-32).  The bootloader writes it into the slot not holding
the running bootloader (half-page programming from RAM, bank 2 target), checks it, appends INSTALL
with that slot to the control area (after erasing the area when fewer than 4 records are free; a full area makes the
starter ignore requests), resets.  The starter installs it (6.2).  The new bootloader
appends OK early in its start (bl_main.s bl_reset: after the clock, GPIO and LCD set-up and the lamp test, before the
key check and before the Bluetooth module is started): a bootloader that hangs before that point is replaced; one that
reaches it but whose Bluetooth path fails is kept (the card update with MEM + HOLD still works then); if it hangs, removing the
batteries makes the starter put the previous one back (6.2 step 3).  A power cut at any moment leaves either the old
bootloader, a repeated install, or a rollback.

"Both": bootloader first (6.3), then the firmware (section 5 item 4).  Firmware images also go to the bootloader
directly over Bluetooth, never through the slots.

### 6.3.1 Packed transfers (B-1.15, firmware IMP-63; GitHub issue 30; owner request 2026-11-09)

START kind | 0x80 (firmware or bootloader image) means the DATA bytes are a packed stream: pieces of raw length u16
(1..2048), packed length u16 (1..2064) and one final dynamic-code deflate block, or packed length 0x8000 | raw length and
the raw bytes.  The companion packs with zlib and sends a piece packed only when zlib gives that one block shorter than
the piece (every piece of the F-1.31 and B-1.14 images, 2026-11-09).  bl_zdata collects a piece in bl_zbuf, checks its
header as soon as it is complete (lengths in range, raw length at most the bytes still due, so nothing is ever
programmed outside the area START erased), unpacks it with the firmware's inflater (firmware/src/sys/zinf.s, assembled
into this build) into bl_zraw and feeds its bytes into the unchanged half-page path; bl_recv counts unpacked bytes.  END
is unchanged (CRC-32 of the flash, then the mark or slot header); a stream byte once the image is complete is refused
by bl_zdata when it arrives, so END never meets a partial piece.
Any stream error: LdE 7, status 0x17, back to waiting; the firmware mark was erased at START, so the bootloader stays
in update mode.  Older bootloaders refuse kind | 0x80 at START before anything is erased (kind check), so the companion
asks the version (STATUS 0x80) and sends B-1.14 and older the plain transfer.  RAM: bl_zbuf 2068 + bl_zraw 2048 +
zinf_work 1060 bytes.

### 6.4 First install on a meter with EEVblog's bootloader (once per meter, done by this project's firmware)

This adds flash writing to the application, against its rule "program flash is never written" (DESIGN.md 2.x, build
check 9.3, ble/bft.s header).  The rule changes to: the application writes only slot A, slot B, the control area and,
during the first install, 0x08000000..0x080003FF, each write checked against these bounds in code; DESIGN.md and the
build check are changed with it.

1. The companion sends the install image (starter + bootloader) over Bluetooth to the running firmware; the bootloader
   part goes to slot A and is checked (CRC-32), the starter part is kept in RAM.
2. The firmware refuses unless 0x08000000..0x08005FFF is byte-identical to a known EEVblog build (the two SHA-256 of
   section 1; the meter computes and compares them), and unless the battery measurement is above a limit (the
   firmware's battery measurement, DESIGN.md adc_ch5_process; limit to be set from measurements on the meter; BOR is
   off on the owner's meter, USER 0xF0, so the measured battery voltage is the only guard).
3. Just before writing: check slot A's CRC again.  Then, with interrupts off, from a routine in RAM: write pages 3, 2
   and 1 of the starter (erase, two half-pages, compare each).  The old bootloader still starts the firmware normally
   after a power cut here (section 6 facts: its start without keys uses nothing in 0x08000100..0x080003FF); only its key
   update mode is gone.  An emulator run of such a cut is not done (owner decision 2026-11-08: the writes take about
   10 to 12 ms, far too short for anyone to switch off in, and nobody cuts power on purpose during an install).  Last, page 0: erase and two half-pages, about 10 ms typical, 12 ms maximum (Table 35).  This is the only
   moment where a power cut bricks the meter (page 0 then holds no valid vector table).
4. Write the install request in the control area; reset.  The starter finds no valid bootloader mark, installs slot A
   (6.2), starts it.

### 6.5 Bluetooth in the bootloader

The BLE module is the same as for the application: PF15 (BT_CTL) high before PD5/PD6 become USART2 (AF7) (DESIGN.md
pin list), USART2 19200 8N1.  The bootloader runs on HSE (hand-over state), so its USART2 baud divider is computed for
its own clock, not copied from the application (the application's divider is for MSI, DESIGN.md NF-04).  Reception by
polling or a USART2 handler in the bootloader's own table (the old table has `b.w .` at IRQ38).  The module's start-up
time before the companion can connect is to be measured.  The block size of bft (232 bytes) is staged in RAM and
programmed in 128-byte half-pages.  After 10 minutes in update mode without a connection, BLE is switched off and the
meter stays in update mode, waiting for keys or a card (battery protection); a key press switches BLE on again.

### 6.5.2 The module's supply at a reset (B-1.16, GitHub issue 23)

A reset leaves every pin an input, so PF15 is undriven until the bootloader drives it.  Up to B-1.15 that was
bl_gpio_config, after the RAM zeroing: measured in the emulator (0x91 restart, both tags built from git) 21.025 ms
with B-1.14 and 23.495 ms with B-1.15, the 2.47 ms between them being the zeroing of the 1295 words the packed mode
added.  A report on Windows (B-1.15) shows the connection dropping at the restart into update mode and the meter
heard again only 22 s later, against the 30 s window; B-1.14 had worked there.  Whether the module browned out is
not measured on a meter.

B-1.16 drives the power pins as the first instructions of bl_reset, before the RAM zeroing: the same steps and order
as bl_gpio_seq (the old bootloader's GPIO_Config), only earlier: PE9 output (low), PE12 output (low), PE9 high, PF6
output (low), PF15 output (low), PF15 high, one pin per MODER store; PD1 is not touched (bl_gpio_seq does not touch
it).  PE12 and PF6 end low in bl_gpio_seq too.  bl_gpio_init keeps ODR, so bl_gpio_seq later changes none of these
levels.  PF15 is then undriven only during the starter: high 0.500 ms after the reset, measured in the emulator (its
cycle model is a lower bound).

bl_sysreset (the restart after a finished Bluetooth update) switches the module off and holds it off RESET_OFF_TICKS
(4 ticks of 10 ms: 30..40 ms) before the reset, so after an update the module restarts cleanly as it did with the
23.5 ms of B-1.15, instead of a 0.5 ms dip (test_bootloader.py B3: off 39.7 ms, high again 0.50 ms after the reset).  Installing a bootloader still leaves PF15 undriven during the starter's
flash write.

### 6.5.1 Bluetooth on after an update over Bluetooth (B-1.14, firmware F-1.22; GitHub issue 23; owner decision 2026-11-07)

A release firmware starts with Bluetooth off (config.inc BLE_AT_POWERUP 0), so after an update over Bluetooth the
companion could not reconnect to confirm it: the user had to hold PEAK.  The firmware cannot leave itself a note across
the update: the bootloader resets the RTC domain at every start (bl_lcd.s, rcc_lsi_as_rtc_lcd_clock: RTCRST) after
reading RTC_BKP0R, and the firmware resets it twice in sys_system_init (firmware sys/main.s: ck_run, sys/msical.s
RTCRST pulses, then rcc_lsi_as_rtc_lcd_clock).
So the note is relayed in RTC_BKP1R (0x40002854, not used by either before):
1. When a Bluetooth transfer has ended with END accepted (bl_reset_due, the restart after RESET_DELAY), the bootloader
   writes BKP_BT_MAGIC to RTC_BKP1R (DBP set) right before the system reset.  No other path writes it (card update, key
   update, an aborted transfer, a timeout start).  The firmware's own end of the first install (ble/bft.s,
   bft_sysreset) writes it in the same way (PWREN, DBP, store, as blcmd_update_mode does for RTC_BKP0R), so the
   bootloader just installed relays it.
2. At every start the bootloader reads RTC_BKP1R together with RTC_BKP0R, before the RTC domain reset, and keeps it
   (a second word beside bl_bkp, stored after the RAM zeroing).  Entering update mode (bl_update) clears the kept value,
   so a key or card update, or a 30 s timeout start, never relays an older note.
3. bl_start_app writes BKP_BT_MAGIC back to RTC_BKP1R (DBP set; the RTC domain is set up by then) when the value read in
   step 2 was BKP_BT_MAGIC, right before the jump to the firmware.  A bootloader update passes through the starter,
   which does not touch the RTC domain, and the new bootloader relays the note in the same way.
4. The firmware reads RTC_BKP1R in sys_system_init after sys_clock_select (PWREN on, clock.s) and before ck_run (the
   first RTCRST), keeps the result in a port RAM byte (.bss is zeroed before sys_main) and, when it was BKP_BT_MAGIC,
   switches Bluetooth on after the start, as a long PEAK does (blcmd_ble_on, the place of the BLE_AT_POWERUP call).  The
   RTC domain reset that follows clears the register, so the note acts once.  Emulator: the backup registers, DBP
   gating, RTCRST and their survival of a system reset are modelled (emulator rtc.py, rcc.py); access is not gated by
   PWREN or RTCEN there, so the PWREN precondition is checked on the meter.
RTC_BKPxR are reset by a power-on reset, not by a system reset (RM0038 20.3.13, as noted in firmware
ble/blcmd.s), so a note does not outlive a power cycle; it also lives only from step 1 to step 4.  An older bootloader
writes no note: the firmware then starts as before (Bluetooth off).  The update that installs B-1.14 is done by the
older bootloader, so after that one update Bluetooth still starts off.

### 6.6 Size

Starter 1024.  Bootloader (23296 bytes available): section 3 budget about 12900 + Bluetooth about 3000 (application's
usart.o 1608, bft.o 2164, commands.o 635 hold more than needed) + slot/control-page code about 600 = about 16500,
leaving about 6800 for exFAT, whose size is still unknown (FF_USE_LFN needed).  If exFAT does not fit, the owner decides.
B-1.15 (2026-11-09): 22172 of 23296 bytes with the inflater (772 bytes of code, 19 of data) and bl_zdata.  To fit, the
inflater takes only the one block kind the companion sends (6.3.1) and computes the length / distance bases by formula,
and code nothing in the bootloader references (found by a reference scan of the linked image) is no longer linked: the
FatFs directory functions (ff16_dirapi.s, 326 bytes, not assembled), sd/tables_v205.o (16 bytes, not linked),
get_fileinfo / put_utf (FF_FS_MINIMIZE 2, as FatFs's own option) and disk_ioctl / get_fattime (SD_READ_ONLY, the write
path).  Still in the image but unreferenced: three clock routines (230 bytes), sd_dma_start_tx (124), two gpio routines
(58), in firmware objects linked as built.

### 6.7 No other way back for users

ST's built-in loader cannot be reached without soldering: BOOT0 (pin 138) goes through R129 (0 R) to a node tied to VSS
by R90 (0 R); R89 from that node to VDD_P is marked "x", not fitted (circuit diagram 2018-01-15, MCU sheet).

## 7. Tests

- Emulator: program flash writes are modelled (emulator/emu/core.py routes CPU stores to flash into the FLASH model),
  and a read of the bank a half-page write runs in stops the run as a bus error (periph/flash.py, RM0038 3.4.3 note 2;
  checked once by pointing the starter's RAM call at the flash copy of the routine: stopped with "instruction fetch
  at 0x0800029A during a half page write").
- `make test` (tests/test_starter.py): every decision of the starter (S1..S9), and power cuts during an install and
  during a rollback, one at each kind of step (first, middle, last erase and half-page; first and last word of the
  mark and of the record), the cut operation ending not done, done or with random contents (S10, S11).  Result
  2026-11-04: all passed, the starter always ends in the expected bootloader, no bus error.

## 8. On the owner's meter (2026-11-04)

Verified working:
- first install through the firmware (F-1.03, page Ld, install file 22784 bytes): starter and bootloader B-1.00
  installed, the firmware starts through them, the meter reports "B-1.00" (key code 0x92);
- the firmware's update-mode request (0x91): the meter restarts into the bootloader, which answers its status
  request with version 1.0.0;
- firmware over Bluetooth into the bootloader, two packets in flight: 157352 bytes in 108 s including the erase at
  START (stop and wait on page Ld took 160 s for 157344 bytes); the meter restarted into the new firmware.
- bootloader update over Bluetooth through the slots: B-1.00 -> B-1.01 (21644 bytes in 15 s), the starter installed
  it, the meter reports "B-1.01"; then a firmware update through B-1.01 (109 s), with "Ld nn" and "Ld oK" on the main
  display (owner's request: progress and a confirmation before the restart).
Found and fixed: the first F-1.03 build restarted after the first install before its END answer had gone out (the
500 ms quiet time counted the ticks of the install itself); the companion now also accepts a missing END answer of
the first install when the meter reports the new bootloader after its restart.
