# Data-EEPROM map of the 121GW (v2.05) and the port's EEPROM rules

Scope: the STM32L152ZD data EEPROM, 0x08080000..0x08082FFF (12 KB). "Offset" below is relative to 0x08080000.
Source of truth: the original image `inputs/binaries/EEVBlog2_05.bin` (base 0x08006000), read through
`analysis/decompile/EEVBlog2_05_listing.asm`. Every statement about v2.05 cites instruction or literal addresses of that
image. Literal values were read from the image bytes. "UNPROVEN" marks what the code does not establish.
Companion documents: `firmware/DESIGN.md` (6.20 CAL, 6.21 NVM, 7), `firmware/ORIGINAL_FIRMWARE_ISSUES.md`
(OF-07, OF-08, OF-09, OF-12, OF-23), `analysis/keys_setup.md` sections 3 and 5, `analysis/rotary.md` section 3.

Mode numbers (meter_mode, RAM 0x2000803C): 0 LowZ, 1 DCV, 2 ACV, 3 DCmV, 4 ACmV, 5 TEMP, 6 FREQ, 7 PULSE, 8 DUTY,
9 OHM, 10 BEEP, 11 DIODE, 12 CAP, 13 uVA, 14 mVA, 15 VA, 16 ACuA, 17 DCuA, 18 ACmA, 19 DCmA, 20 ACA, 21 DCA,
22 DCuVA, 23 DCmVA, 24 DCVA. Range = meter_range (RAM 0x2000803D). Ranges per mode = bytes at RAM 0x20000000
(`analysis/decompile/ram_init.txt`): 1,4,4,2,2,1,5,3,1,7,1,1,6,4,4,4,2,2,2,2,3,3,4,4,4.

---

## 1. Hardware facts the map depends on

- Erased data-EEPROM content is 0x00 (RM0038, data EEPROM byte-write section: "assuming that the word is already
  erased (0x00000000)").
- Byte write with FTDW = 0: when the addressed word is not 0x00000000 the controller erases the word automatically and
  then writes it (two programming times); when it is 0 it writes directly (RM0038, same section). The non-zero-byte
  restriction applies to Cat.1 devices only; the STM32L152ZD (384 KB) is Cat.4 (RM0038 Table 1).
- RM0038 does not state the content of a word after a power loss between the automatic erase and the write: UNPROVEN.

## 2. How v2.05 reads and writes the data EEPROM

### 2.1 The only EEPROM base reference

The literal 0x08080000 exists once as an address (pool 0x0801240C). It is read by `eeprom_read_byte` (0x08012050) and
`eeprom_program_byte` (0x080120F8). Other byte patterns 0x0808xxxx in the image (0x08012E81, 0x080193F5, 0x0802863C,
0x08028715, 0x08028729, 0x0802878D, 0x080287A1) are inside data tables or straddle two pool words; none is used as an
address. No MOVT with 0x0808 exists in the image.

### 2.2 Accessors

| Routine | Address | Behaviour |
|---|---|---|
| eeprom_read_byte | 0x0801204C | 0x08080000 + offset (0x08012050..0x08012054), 32-bit `ldr` (0x08012058), `uxtb` (0x0801205C): the byte at the address (little-endian core). The highest offset passed is 0x4FC, so no load crosses the end of the EEPROM |
| eeprom_read_u8 | 0x0801203A | read_byte, `uxtb` (0x08012048) |
| eeprom_read_u16_be | 0x08012000 | bytes off, off+1 -> b0*0x100 + b1 (0x0801200A..0x08012036). Big-endian, unsigned |
| eeprom_read_s16_be (FUN_08011FD4) | 0x08011FD4 | u16 BE, sign-extended when >= 0x8000 (0x08011FE4..0x08011FF0) |
| eeprom_read_u32_be | 0x08011F80 | b0<<24 + b1<<16 + b2<<8 + b3 (0x08011F8E..0x08011FCE). Big-endian |
| eeprom_write_u8 | 0x080120D0 | write_byte_retry(off, value & 0xFF) (0x080120DC) |
| eeprom_write_u16_be | 0x080120A8 | high byte to off (0x080120BC), low byte to off+1 (0x080120CA) |
| eeprom_write_u32_be | 0x08012068 | bits 31..24 to off (0x08012078), 23..16 to off+1 (0x08012086), 15..8 to off+2 (0x08012094), 7..0 to off+3 (0x080120A2). Four separate byte programs, not atomic |
| eeprom_write_byte_retry | 0x08012148 | up to 10 calls of program_byte (`cmp r8,#0xa` 0x08012158), stops when the status is 4 (complete, 0x0801216C). No read-back. Every caller discards the status |
| eeprom_program_byte | 0x080120F0 | address = 0x08080000 + off (0x080120F8..0x080120FC); unlock 0x0801F9FC (0x080120FE); program 0x0801FA2E (0x08012108); lock 0x0801FA1C (0x0801210E) |
| eeprom_read_u8_wrapper / eeprom_write_u8_wrapper | 0x080104F8 / 0x08010504 | used only by calbin_save (0x0801CD28) and calbin_load (0x0801D08A, 0x0801D09E) |

### 2.3 FLASH interface registers and keys used by v2.05

| Routine | Address | Registers and values |
|---|---|---|
| DATA_EEPROM_Unlock | 0x0801F9FC | if FLASH_PECR (0x40023C04) bit 0 PELOCK is set (0x0801FA02): FLASH_PEKEYR (0x40023C0C) <- 0x89ABCDEF (0x0801FA0E), then 0x02030405 (0x0801FA18) |
| DATA_EEPROM_Lock | 0x0801FA1C | FLASH_PECR \|= 1 (PELOCK) (0x0801FA22..0x0801FA2A) |
| DATA_EEPROM_ProgramByte | 0x0801FA2E | status = wait (0x0801FA3A); only if status == 4: FLASH_PECR &= ~0x100 (FTDW = 0, 0x0801FA4C..0x0801FA54), `strb` value to the address (0x0801FA56), status = wait (0x0801FA5C) |
| FLASH_WaitForLastOperation | 0x0801FB60 | polls while busy, at most 0x8000 polls (0x0801FB74..0x0801FB8A); timeout gives status 5 (0x0801FB90) |
| FLASH_GetStatus | 0x0801FB00 | FLASH_SR (0x40023C18): BSY -> 1, WRPERR (bit 8) -> 2, any of bits 9..12 (mask 0x1E00) -> 3, else 4 |
| FLASH_ClearFlag | 0x0801FAFA | FLASH_SR <- argument (write 1 to clear) |
| FLASH_OB_Unlock | 0x0801FA68 | if PECR bit 2 OPTLOCK: DATA_EEPROM_Unlock, then FLASH_OPTKEYR (0x40023C14) <- 0xFBEAD9C8 (0x0801FA80), 0x24252627 (0x0801FA8A) |
| FLASH_OB_BORConfig | 0x0801FAA0 | writes the USER option word at 0x1FF80004 (0x0801FADC), see 2.4 |
| FLASH_OB_Launch | 0x0801FA8E | FLASH_PECR \|= 0x40000 (OBL_LAUNCH, 0x0801FA94): option reload and system reset |

Complete list of FLASH register writes in v2.05 (`analysis/decompile/mmio_refs.txt` plus a raw literal scan; no other
0x40023Cxx literal exists): FLASH_ACR at 0x08026018/0x08026024/0x08026030 (clock set-up 0x08025FC2); FLASH_PECR at
0x0801FA2A, 0x0801FA54, 0x0801FA9C; FLASH_PEKEYR at 0x0801FA0E, 0x0801FA18; FLASH_OPTKEYR at 0x0801FA80, 0x0801FA8A;
FLASH_SR at 0x0801FAFC; option word 0x1FF80004 at 0x0801FADC.

Consequences:
- FLASH_PRGKEYR (0x40023C10) is never referenced and the program-memory keys 0x8C9DAEBF / 0x13141516 do not occur:
  v2.05 cannot unlock program flash itself.
- PECR bits ERASE (9), PROG (3), DATA (4), FPRG (10) are never set: no word erase, no fast write, no half-page write.
  Every EEPROM change is one byte program with FTDW = 0.
- RDP, WRP and PCROP option words are never written.
- A FLASH_SR error flag (WRPERR or bits 9..12) is cleared only in `FUN_0801BE76` (FLASH_SR <- 0x1F02 at
  0x0801BEA4..0x0801BEA8, every reset and wake; and FLASH_SR <- 0x0F02 at 0x0801BEC6 inside the option-byte branch). While such a flag is set, ProgramByte returns 2/3 from its first wait
  without writing (0x0801FA42..0x0801FA44), so every later EEPROM write fails silently until the next reset or wake.

### 2.4 The option-byte write in v2.05 (not an EEPROM write; the port removes it)

`FUN_0801BE76` (called from `main` 0x08024B4E and after STOP 0x08024EEE), 0x0801BEAC..0x0801BED4: if FLASH_OBR BOR_LEV
(bits 19:16, read by 0x0801FAEE) is not 0, it unlocks the option bytes (0x0801FA68), writes 0x1FF80004 =
(~u << 16) | u with u = (OBR bits 23:20) << 4 (BOR_LEV = 0, other USER bits kept) at 0x0801FADC, then sets OBL_LAUNCH
(0x0801FA8E), which resets the device. On the unit dump `inputs/binaries/option.bytes` USER = 0xF0 (BOR_LEV = 0), so the
branch is not taken there.

### 2.5 State left by the bootloader

The bootloader (`inputs/binaries/bootloader.bin`) unlocks the data EEPROM and program flash (its key values are literal
pool words: PEKEY at 0x0800467C/0x08004680, PRGKEY at 0x08004670/0x08004674, OPTKEY at 0x08004688/0x0800468C; unlock
routine called from 0x08004B7E inside 0x08004B7C) and never locks them again: the
application starts with FLASH_PECR = 0x00000004 (PELOCK = 0, PRGLOCK = 0, OPTLOCK = 1). v2.05 locks PECR only at the end
of its first EEPROM byte program (0x0801FA1C). The bootloader never accesses the data EEPROM.

## 3. Higher-level accessors (v2.05)

| Routine | Address | Behaviour |
|---|---|---|
| marker_1F_read | 0x080104BC | returns 0 if EEPROM[0x1F] == 0xA5 else 1 (0x080104C0..0x080104CC) |
| marker_1F_write | 0x080104D4 | up to 10 times: write 0xA5 to 0x1F, read back, stop when equal (0x080104DA..0x080104F4) |
| marker_26_read / marker_26_write | 0x08010F10 / 0x08010F28 | the same for offset 0x26 (0x08010F14..0x08010F20, 0x08010F2E..0x08010F48) |
| cal_record_base | 0x0801159C | T[meter_mode] + (meter_range << 4) (0x0801159E..0x080115BA); its argument is ignored. T = u16 table at 0x08028EE8 (pool 0x080120EC) |
| ac_words_base | 0x080115CC | (mode, sub): sub forced to 1 for modes 16 and 18 (0x080115D6..0x080115E8); returns T[mode] + 8 + 16*sub (0x080115EA..0x080115FC) |
| load_cal_record_from_eeprom | 0x0801167C | section 5.2 |
| cal_record_load_va | 0x08011950 | u32 R -> 0x20007E24; ui2f(u32 R+4)/1e6 -> 0x20007E2C; u32 R+8 -> 0x20007E28; ui2f(u32 R+12)/1e6 -> 0x20007E30 (0x08011952..0x080119EA) |
| ac_words_load (FUN_08011AA4) | 0x08011AA4 | R' = ac_words_base(2, 3) in mode 0, else ac_words_base(mode, range) (0x08011AA6..0x08011AD4); s16 BE at R', R'+2, R'+4, R'+6 -> 0x20007E4C, 0x20007E50, 0x20007E54, 0x20007E58, clamped by FUN_080119F4 (words 0, 1 kept if -20000..20000, words 2, 3 if -10000..10000, else 0; 0x08011A06..0x08011A9A) |
| cal_record_write | 0x08011B40 | (kind, value), section 7.3. Called only with kind 0, 1, 0x96, 0xC8 |
| cal_record_write_va (FUN_08011DCE) | 0x08011DCE | kind 0: u32 R <- 0x20007E24, u32 R+8 <- 0x20007E28; kind 1: R+4 <- f2iz(1e6*0x20007E2C), R+12 <- f2iz(1e6*0x20007E30) (0x08011DD8..0x08011E78) |
| ac_words_write (FUN_08011E88) | 0x08011E88 | (mode, range, sel): R' = ac_words_base(mode, range); sel 1 or 0x64: u16 R' <- 0x20007E4C (clamped); sel 2/0x64: R'+2 <- 0x20007E50; sel 3/0x64: R'+4 <- 0x20007E54; sel 4/0x64: R'+6 <- 0x20007E58 (0x08011EA0..0x08011F32) |
| ac_words_clear (FUN_08011F38) | 0x08011F38 | zeroes 0x2000809C..0x2000809F and 0x20007E4C..0x20007E58, then ac_words_write(mode, range, 0x64) (0x08011F68..0x08011F72) |
| current_extra_offset | 0x0801154E | mode 16..21 -> 0x4D0, 0x4D8, 0x4E0, 0x4E8, 0x4F0, 0x4F8 (0x0801156A..0x08011592); no range input |
| current_extra_load | 0x08011448 | 0x20007E0C <- 0 (0x0801144E..0x08011454); if mode 16..21 and range 0 and EEPROM[base] == 0xA5: 0x20007E0C <- u32 BE (base+1) (0x08011480..0x080114A6) |
| current_extra_store | 0x080114BC | (mode, range, value): if mode 16..21 and range 0: 0xA5 to base (0x080114FE), u32 BE value to base+1..base+4 (0x08011508) |
| current_extra_erase_all | 0x0801150E | current_extra_store(m, 0, 0) for m = 16..21 (0x08011510..0x08011548) |
| rotary_memory_store | 0x08011154 | dispatch on meter_mode (0x08011156..0x08011194) -> FUN_08011118(offset, value) -> eeprom_write_u8 (0x08011140); FUN_08011118 ORs 0x80 into value 2 at offset 8 when the AC+DC flag 0x200080BA is set (0x08011120..0x08011134) |
| calbin_save / calbin_load | 0x0801CD14 / 0x0801CF06 | section 8 |

## 4. Complete map

Formats: BE = big-endian, written MSB first, one byte program at a time. "Boot" = read by `FUN_08024DE0` (called from
`main` 0x08024B56 and after STOP 0x08024EF2). "Apply" = read on every mode/range application (`FUN_0800D81E(1)` via
`FUN_0800D80C` 0x0800D814, inside `meter_apply_mode_range` 0x0800D2D0). Port class: the write class of section 9.2.

| Offset | Size | Format | Meaning (RAM copy) | Readers | Writers | Write trigger in v2.05 | Validation / default on read | Port class |
|---|---|---|---|---|---|---|---|---|
| 0x000 | 1 | - | never accessed | calbin_save | calbin_load | cal.bin restore | - | RESTORE |
| 0x001..0x002 | 2 | u16 BE | date code year*100 + month (0x20007F9A; BLE packet, log ID token) | 0x08010F50 (Boot) | 0x08010F7E (FUN_08010F74) via FUN_08015F44 0x08015F64 | SETUP item 5 or 6 save, only if 0x2000808B != 0 (SETUP pressed in the power-on window, test 0x08015F46..0x08015F4E); value 0x200080D7*100 + 0x200080D8 (0x08015F50..0x08015F5A) | 0 -> 1708 (0x08010F60..0x08010F6C); other values accepted | IDENT |
| 0x003..0x006 | 4 | u32 BE | serial / ID number, setup item 8 (0x20007D14) | 0x08010F90 (Boot) | 0x08010FC2 (FUN_08010FB8) via FUN_08015F7C 0x08015F90 | SETUP item 8 save, value = edit buffer 0x20007D18 | >= 100000 (pool 0x08011AA0) -> 0 (0x08010FA6) | IDENT |
| 0x007 | 1 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x008 | 1 | u8 | rotary memory, V position: 1 DCV, 2 ACV, 0x82 ACV with AC+DC | FUN_08010FF0 0x08010FF6 (dial latch) | rotary_memory_store 0x0801119E | MODE short that changes the mode (single call 0x08014702) in modes 1, 2 | 0x82 -> mode 2 + 0x0801472C; 1 or 2 kept; else 1 (0x08010FFE..0x08011018) | SETTINGS |
| 0x009 | 1 | u8 | rotary memory, mV position: 3, 4, 5 | FUN_08011020 0x08011026 | 0x080111AC | MODE in modes 3..5 | 3/4/5 else 3 | SETTINGS |
| 0x00A | 1 | u8 | rotary memory, Hz position: 6, 7, 8 | FUN_08011046 0x0801104C | 0x080111BA | MODE in modes 6..8 | 6/7/8 else 6 | SETTINGS |
| 0x00B | 1 | u8 | rotary memory, Ohm position: 9..12 | FUN_0801106C 0x08011072 | 0x080111C8 | MODE in modes 9..12 | 9..12 else 9 | SETTINGS |
| 0x00C | 1 | u8 | rotary memory, VA position: 0x18 or 0x0F | FUN_08011098 0x0801109E | 0x080111F2 | MODE in modes 14, 15, 23, 24 (0x18 for 23/24, else 0x0F; 0x080111CE..0x080111EA) | 0x18/0x0F else 0x18 | SETTINGS |
| 0x00D | 1 | u8 | rotary memory, uA position: 0x11, 0x10, 0x0D, 0x16 | FUN_080110B8 0x080110BE | 0x08011200 | MODE in modes 13, 16, 17, 22 | those four else 0x11 | SETTINGS |
| 0x00E | 1 | u8 | rotary memory, A/mA position: 0x12..0x15 | FUN_080110E4 0x080110EA | 0x0801120E | MODE in modes 18..21 | 0x13/0x15 -> 0x13; 0x12/0x14 -> 0x12; else 0x13 | SETTINGS |
| 0x00F | 1 | - | never accessed by v2.05; port (production image only): thermocouple type code, section 4.1 | calbin_save; port: set_tc_load | calbin_load; port: set_tc_edit via nvm_write_setting | cal.bin restore; port: SETUP page tc save | port: 0..5 kept, else 0 (K) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x010 | 1 | u8 | temperature unit, 1 degC, 0 degF (0x200080AB) | 0x08011300 (Boot), FUN_0800D190 0x0800D264 | 0x0801133A (FUN_08011330) via FUN_08015BE0 0x08015C0C | SETUP item 0 save | < 2 kept else 0 (0x08011308..0x08011316) | SETTINGS |
| 0x011 | 1 | - | never accessed by v2.05; port (production image only): dBm reference code, section 4.1 | calbin_save; port: set_dbm_load | calbin_load; port: set_dbm_edit via nvm_write_setting | cal.bin restore; port: ACV page 11 save | port: 0..3 kept, else 0 (600 ohm) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x012 | 1 | u8 | DIODE 15 V flag (0x200080B3) | 0x08011344 (Boot) | 0x0801138E (FUN_08011384) via FUN_080159C8 0x080159EE | every RANGE short in DIODE | 0/1 kept, >= 2 -> 0 (0x0801134C..0x0801136C); then forced 0 at 0x08024E76..0x08024E78 (OF-23) | read only in the port (OF-23, section 10) |
| 0x013 | 1 | - | never accessed by v2.05; port (production image only): display level, section 4.1 | calbin_save; port: set_dsp_load | calbin_load; port: set_dsp_edit via nvm_write_setting | cal.bin restore; port: SETUP page dSP save | port: 0..1 kept, else 0 (level 1) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x014 | 1 | u8 | continuity threshold step 0..3 (0x200080B6) | 0x08011398 (Boot), FUN_0800D190 0x0800D27C | 0x080113D6 (FUN_080113CC) via FUN_08015C20 0x08015C7C | SETUP item 10 save in BEEP | < 4 kept else 0 (0x080113A0..0x080113AE) | SETTINGS (port value range 0..15: section 10, IMP-05) |
| 0x015 | 1 | - | never accessed by v2.05; port (production image only): Bluetooth frame rate code, section 4.1 | calbin_save; port: set_bt_load | calbin_load; port: set_bt_edit via nvm_write_setting | cal.bin restore; port: SETUP page bt save | port: 0..3 kept, else 0 (2 per second) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x016 | 1 | u8 | auto-power-off disable (0x20008039) | 0x080112A8 (Boot), FUN_0800D190 0x0800D244 | 0x080112F6 (FUN_080112EC) via FUN_08015A22 0x08015A5E | SETUP item 2 save | 1 -> 1, else 0 (0x080112B0..0x080112D0) | SETTINGS |
| 0x017 | 1 | - | never accessed by v2.05; port (production image only): backlight auto-off timer code (bits 6..0) and backlight state (bit 7), section 4.1 | calbin_save; port: set_bl_load | calbin_load; port: set_bl_store via nvm_write_setting | cal.bin restore; port: SETUP page bL save, MODE long press | port: 0xFF reads as OFF and dark; code 0..100 kept, else 0 (OFF) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x018..0x019 | 2 | u16 BE | logging interval in s (0x2000022C) | 0x0801121C (Boot) | 0x08011252 (FUN_08011248) via FUN_08015AC0 0x08015B30 | SETUP item 9 save | < 1000 kept, else 1 (0x08011224..0x08011234) | SETTINGS |
| 0x01A | 1 | u8 | LCD contrast (0x20000237, lcd_init argument at 0x08024B5C..0x08024B62) | 0x0801125C (Boot) | 0x0801129E (FUN_08011294) via FUN_08015B54 0x08015BB2 | SETUP item 4 save (values 10..17, 0x08015B64, 0x08015B8E) | 12..17 kept, else 14 (0x08011264..0x0801127C): a saved 10 or 11 becomes 14 after power-up (DESIGN.md NF-17, switch, default v2.05) | SETTINGS |
| 0x01B | 1 | u8 | VA "bd" option (0x200080A8) | 0x080113E0 (Boot) | 0x0801140A (FUN_08011400) via FUN_08016190 0x080161AC | SETUP item 11 save in modes 13, 14, 15, 22, 23, 24 | == 1 -> 1 else 0 | SETTINGS |
| 0x01C..0x01D | 2 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x01E | 1 | u8 | buzzer enable (0x20008078) | 0x08011414 (Boot), FUN_0800D190 0x0800D254 | 0x08011442 (FUN_08011438) via FUN_08015A74 0x08015AAA | SETUP item 3 save | == 1 -> 1 else 0 | SETTINGS |
| 0x01F | 1 | marker (hardware variant) | 0xA5 after an ACV range-0 calibration through FUN_0800F7B8; RAM 0x20008087 = (byte != 0xA5); flag 1 (byte not 0xA5) applies the second AC correction CORR70 in ACV range 0 (0x080074F8..0x08007506, 0x0800767A); part of cal.bin, so restoring another meter's cal.bin copies its marker; port: the flag is read back after the write (OF-62) | 0x080104C2 (Boot, store 0x08024DF2) | marker_1F_write 0x080104E4 (read-back verified), called at 0x0800F896; calbin_load | gain completion FUN_0800F7B8 in mode 2 range 0 (0x0800F882..0x0800F896) | != 0xA5 -> flag 1 | CAL |
| 0x020 | 1 | - | never accessed by v2.05; port (production image only): bit 0 REL view, bits 2..1 logging trigger, bit 3 clock, bit 4 CAP anti-hunting, section 4.1 | calbin_save; port: set_relp_load | calbin_load; port: set_b20_store via nvm_write_setting | cal.bin restore; port: SETUP pages rEL, CL and HUnt save | port: 0xFF reads as 0; bits 0, 2..1, 3 and 4 used, other bits kept | RESTORE; SETTINGS in the production image only (4.1) |
| 0x021 | 1 | - | never accessed by v2.05; port (production image only): continuity hold code, section 4.1 | calbin_save; port: set_bh_load | calbin_load; port: set_bh_edit via nvm_write_setting | cal.bin restore; port: SETUP page bH save | port: 0..3 kept, else 0 (100 ms) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x022 | 1 | - | never accessed by v2.05; port (production image only): logging change threshold, section 4.1 | calbin_save; port: set_ch_load | calbin_load; port: set_ch_edit via nvm_write_setting | cal.bin restore; port: SETUP page Ch save | port: 0 reads as 1 | RESTORE; SETTINGS in the production image only (4.1) |
| 0x023..0x025 | 3 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x026 | 1 | marker (hardware variant) | 0xA5 after an OHM range-6 calibration; RAM 0x20007FE0 = (byte != 0xA5); flag 1 (byte not 0xA5) clears bit 3 (PS0) of HY3131 register byte 10 in OHM range 6, flag 0 leaves PS0 closed (0x0800BE62..0x0800BE80); also read by 0x08007A92 (OHM) and 0x08008830 (VA); part of cal.bin like 0x01F; the writing branch is not reached (DEF-13), port: the flag is read back after the write (OF-62) | 0x08010F16 (Boot, store 0x08024DEA) | marker_26_write 0x08010F38, called at 0x0800F8AE; calbin_load | gain completion FUN_0800F7B8 in mode 9 range 6, which also sets RAM 0x20007FE0 = 1 (0x0800F8B2..0x0800F8B8) | != 0xA5 -> 1 | CAL |
| 0x027 | 1 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x028 | 1 | - | never accessed by v2.05; port (production image only): current-loop view code, section 4.1 | calbin_save; port: set_lp_load | calbin_load; port: set_lp_edit via nvm_write_setting | cal.bin restore; port: SETUP page LP save | port: 0..2 kept, else 0 (off) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x029 | 1 | - | never accessed by v2.05; port (production image only): RTD temperature view code, section 4.1 | calbin_save; port: set_rtd_load | calbin_load; port: set_rtd_edit via nvm_write_setting | cal.bin restore; port: SETUP page Pt save | port: 0..2 kept, else 0 (off) | RESTORE; SETTINGS in the production image only (4.1) |
| 0x02A | 1 | - | never accessed by v2.05; port (production image only): battery voltage trim, section 4.1 | calbin_save; port: set_btrim_load | calbin_load; port: set_btrim_edit via nvm_write_setting | cal.bin restore; port: SETUP battery page save | port: 50..150 kept (trim = byte - 100), else no trim | RESTORE; SETTINGS in the production image only (4.1) |
| 0x02B..0x02F | 5 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x030..0x2CF | | records | calibration records, 16 bytes per mode and range, section 5 | | | | | CAL (accessed bytes), RESTORE (all) |
| 0x2D0..0x2D7 | 8 | i32 BE, u32 BE | peak-hold record (table index 25): offset, gain | load path for modes 2/4 with peak_hold 0x200080B7 == 1 (0x08011798..0x080117AE) | cal_record_write 0x08011C4C (kind 0), 0x08011D38 (kind 1, address 0x2D4 at 0x08011CA0..0x08011CA6) | offset / gain calibration in modes 2, 4 with peak hold | none | CAL |
| 0x2D8..0x2DF | 8 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x2E0..0x2E1 | 2 | s16 BE | board (thermistor) temperature offset (0x20007FBE) | load_cal_record_from_eeprom(0xC8, 0) 0x08011698 (Boot, call 0x08024DFA) | cal_record_write(0xC8) 0x08011B8A from adc_ch4_process 0x08013A02 | MEM long in cal mode when not mode 9 range 6 (flag 0x20008096 set at 0x08016500) | `ldrsh` (0x080116A6); > 1000 or < -1000 -> 0 (0x080116AA..0x080116C4); the writer clamps the same way (0x08011B56..0x08011B78) | CAL |
| 0x2E2..0x2FF | 30 | - | never accessed | calbin_save | calbin_load | - | - | RESTORE |
| 0x300..0x47F | | records | VA records, 16 bytes, section 5 | | | | | CAL (accessed bytes), RESTORE (all) |
| 0x480..0x4AF | 48 | - | never accessed by code other than calbin_save / calbin_load | calbin_save | calbin_load | cal.bin restore | - | RESTORE |
| 0x4B0..0x4CF | 32 | - | never accessed by any code | - | - | - | - | never written by the port |
| 0x4D0, 0x4D8, 0x4E0, 0x4E8, 0x4F0, 0x4F8 | 1 each | marker | 0xA5 = user current-zero record valid for mode 16 ACuA, 17 DCuA, 18 ACmA, 19 DCmA, 20 ACA, 21 DCA | current_extra_load 0x0801148E (Apply, range 0 only) | current_extra_store 0x080114FE | REL long in modes 16..21 at range 0 (call 0x0801645C); erase-all at calibration-mode entry (0x0800EAF6) | != 0xA5 -> RAM 0x20007E0C = 0 | USERZERO, RESTORE (new cal.bin only) |
| record base+1..base+4 | 4 each | i32 BE | user current-zero value in display counts (0x20007E0C) | 0x0801149E | 0x08011508 | as above; value 0x20007D64 (REL long) or 0 (erase-all) | none | USERZERO, RESTORE (new cal.bin only) |
| 0x4D5..0x4D7, 0x4DD..0x4DF, 0x4E5..0x4E7, 0x4ED..0x4EF, 0x4F5..0x4F7, 0x4FD..0x4FF | 3 each | - | never accessed | - | - | - | - | never written by the port |
| 0x500..0x2FFF | 11008 | - | never accessed by any code | - | - | - | - | never written by the port |

Highest offset accessed by v2.05: 0x4FC (last byte of the 0x4F8 record: read at 0x0801149E, written at 0x08011508).

Every byte inside 0x000..0x4FF that no v2.05 routine other than calbin_save / calbin_load reads or writes:
0x000, 0x007, 0x00F, 0x011, 0x013, 0x015, 0x017, 0x01C..0x01D, 0x020..0x025, 0x027..0x02F, 0x078..0x07F,
0x088..0x08F, 0x098..0x09F, 0x0A8..0x0AF, 0x0B8..0x0BF, 0x0C8..0x0CF, 0x0F8..0x0FF, 0x108..0x10F, 0x118..0x11F,
0x128..0x12F, 0x138..0x13F, 0x148..0x14F, 0x158..0x15F, 0x168..0x16F, 0x17C..0x17F, 0x188..0x18F, 0x198..0x19F,
0x1A8..0x1AF, 0x1B8..0x1BF, 0x1C8..0x1CF, 0x1D8..0x1DF, 0x1E8..0x1EF, 0x1F8..0x1FF, 0x218..0x21F, 0x228..0x22F,
0x238..0x23F, 0x258..0x25F, 0x268..0x26F, 0x2A8..0x2AF, 0x2B8..0x2BF, 0x2C8..0x2CF, 0x2D8..0x2DF, 0x2E2..0x2FF,
0x480..0x4CF, 0x4D5..0x4D7, 0x4DD..0x4DF, 0x4E5..0x4E7, 0x4ED..0x4EF, 0x4F5..0x4F7, 0x4FD..0x4FF.
The supplied 1200-byte calibration backup of a real meter (the `.BIN` file in `inputs/binaries`) is 0x00 at every one
of these bytes (0x000..0x4AF part).

EEPROM words shared by several settings (word = 4 aligned bytes; every byte write to a non-zero word erases and
rewrites the whole word, section 1): 0x000..0x003 (date, ID MSB), 0x004..0x007 (ID), 0x008..0x00B, 0x00C..0x00F
(rotary), 0x010..0x013 (unit, DIODE), 0x014..0x017 (threshold, APO), 0x018..0x01B (interval, contrast, bd),
0x01C..0x01F (buzzer, marker 0x1F), 0x024..0x027 (marker 0x26). Calibration fields are 4-byte aligned (records
16-aligned, fields at +0, +4, +8, +0xC), so each u32 field is exactly one word; AC words (u16) share words pairwise.

### 4.1 Port-only settings (bytes v2.05 never accesses, used by the production image only)

Each byte below is in the never-accessed list above, so v2.05 neither reads nor writes it; the production port stores one
user setting in it. Every byte needs an owner decision before it is used (rule of 9.1 item 2), and every one is chosen so
that its 4-byte word holds no calibration, serial, date or marker byte: a byte write rewrites its whole word (section 1),
so an interrupted write can only damage the settings that share the word. The like-v2.05 build (branch `like-v2.05`) neither
reads nor writes these bytes and its `nvm_allow` table does not allow them. The table is read by `gen_nvm_allow.py` (first cell = offset, last cell = class).

| Offset | Meaning | Values | Invalid or blank (0x00) reads as | Class |
|---|---|---|---|---|
| 0x00F | thermocouple type (SETUP page tc in TEMP, SET/MTMP, FEATURES.md 2.8) | 0 = K (v2.05), 1 = J, 2 = T, 3 = N, 4 = R, 5 = S | K (a value above 5, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x011 | dBm reference of the ACV page 11 (SET, FEATURES.md 2.2) | 0 = 600 ohm (divisor 0.6, v2.05), 1 = 50 ohm (0.05), 2 = 75 ohm (0.075), 3 = dBV (1.0) | 600 ohm (a value above 3, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x013 | display level (SETUP page dSP, SET/FUNC, FEATURES.md 2.4) | 0 = level 1 (v2.05 smoothing), 1 = level 2 (a quarter of every smoothing depth) | level 1 (a value above 1, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x015 | Bluetooth frame rate (SETUP page bt, BLE/SET, FEATURES.md 2.5) | 0 = 2 frames per second (v2.05), 1 = 4, 2 = 10, 3 = 20 | 2 per second (a value above 3, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x017 | backlight auto-off timer (SETUP page bL, PWR/SET, FEATURES.md 2.9) and remembered backlight state | bits 6..0: 0 OFF (never), 1 = 30 s, 2..100 = 1..99 min (code - 1); bit 7: 1 = the backlight was on after the last MODE long press, restored at power-on and wake | OFF, dark (0xFF reads as OFF and dark; a code above 100 is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x020 | REL view (SETUP page rEL, SET/UI, FEATURES.md 2.3) in bit 0; clock (SETUP page CL, FEATURES.md 2.12) in bit 3; logging trigger (SETUP page tr, FEATURES.md 2.6) in bits 2..1; CAP anti-hunting (SETUP page HUnt, SET/MRES, FEATURES.md 2.19) in bit 4; bits 7..5 unused | bit 0: 0 = difference (v2.05), 1 = percent; bits 2..1: 0 = interval (v2.05), 1 = on change, 2 = on limit verdict, 3 reads as 0; bit 3: 0 = 24-hour (v2.05), 1 = 12-hour; bit 4: 0 = off, 1 = on | difference, off (0xFF, an erased byte, reads as 0 for every bit, so it never switches the anti-hunting on; the other bits are written back as loaded) | SETTINGS |
| 0x021 | continuity beep hold time (SETUP page bH in BEEP, SET/MRES, FEATURES.md 2.13) | 0 = 100 ms (v2.05), 1 = 50 ms, 2 = 25 ms, 3 = off (15 ms) | 100 ms (a value above 3, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x022 | logging change threshold (SETUP page Ch, LOG/SET, FEATURES.md 2.6) | 1..255 counts | 1 (0 reads as 1; 0xFF is 255) | SETTINGS |
| 0x028 | current-loop percent view of DCmA (SETUP page LP in DCmA, SET/UI, FEATURES.md 2.14) | 0 = off (the current, v2.05), 1 = 4..20 mA, 2 = 0..20 mA | off (a value above 2, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x02A | battery voltage trim (SETUP battery page, item 1, SET/PWR, FEATURES.md 2.16) | byte = t + 100, t = -50..+50: the battery value is scaled by (1000 + 2 t) / 1000 (0.2 % steps, +-10 %) | no trim (a value outside 50..150, 0x00 and 0xFF included, reads as t = 0 and the byte is left as found) | SETTINGS |
| 0x029 | RTD temperature view of OHM (SETUP page Pt in OHM, SET/UI, FEATURES.md 2.15) | 0 = off (the resistance, v2.05), 1 = Pt100, 2 = Pt1000 | off (a value above 2, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |
| 0x02B | auto power-off time (SETUP page APO, item 2, SET/PWR, FEATURES.md 2.23; on / off stays in 0x016) | 0 = 30 min (v2.05), 1 = 1 min, 2 = 15 min, 3 = 60 min; doubled while MIN/MAX is on | 30 min (a value above 3, 0xFF included, is replaced by 0 in RAM and the byte is left as found) | SETTINGS |

Owner decision for 0x017: approved (2026-11-02). Why this byte: the word 0x014..0x017 holds the continuity code 0x014
and the APO flag 0x016, both SETTINGS; v2.05's own setting saves already rewrite this word (0x014 at 0x080113D6, 0x016 at
0x080112F6), so 0x017 adds no new kind of exposure. 0x017 lies inside the cal.bin range 0x000..0x4AF: `calbin_save` writes it to
the file and `calbin_load` restores it; a v2.05 backup has 0x00 there (the supplied backup of a real meter does, see the
paragraph above), which reads as OFF. A meter flashed back to v2.05 ignores the byte; a v2.05 calbin_load of a backup made by the
port writes the stored value to 0x017, which v2.05 never reads. Further candidates for other port-only settings (words with SETTINGS bytes only: 0x00F, 0x011,
0x013, 0x015; words that are entirely free: 0x020..0x023, 0x028..0x02B, 0x02C..0x02F) are listed in FEATURES.md 3; none of
them is allowed until it appears in the table above. Owner decision (2026-11-02): the bytes 0x00F, 0x011, 0x013, 0x015,
0x020, 0x021, 0x022 and 0x028..0x02F are approved for the features of FEATURES.md 3; each enters the table above (and
`nvm_allow`) only with the code that uses it. The limits of FEATURES.md 2.1 are not kept over a power-off (owner, same day),
so 0x021 holds the continuity hold time of FEATURES.md 2.13 instead; 0x028 holds the current-loop view of FEATURES.md 2.14
(owner request 2026-11-03), 0x029 the RTD view of FEATURES.md 2.15 (owner request 2026-11-03), 0x02A the battery trim of FEATURES.md 2.16 (owner request 2026-11-03, GitHub issue 2), 0x02B the auto power-off time of FEATURES.md 2.23 (owner request 2026-11-07; its word 0x028..0x02B holds settings bytes only), 0x02C..0x02F stay unused.

## 5. Calibration records

### 5.1 Base table T (0x08028EE8, 26 u16 little-endian entries, index = mode, entry 25 = peak record)

| Mode | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10 | 11 | 12 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T | 0x030 | 0x070 | 0x030 | 0x0B0 | 0x0D0 | 0x0F0 | 0x100 | 0x100 | 0x100 | 0x110 | 0x120 | 0x180 | 0x190 |

| Mode | 13 | 14 | 15 | 16 | 17 | 18 | 19 | 20 | 21 | 22 | 23 | 24 | 25 (peak) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| T | 0x300 | 0x340 | 0x380 | 0x1F0 | 0x210 | 0x230 | 0x250 | 0x270 | 0x2A0 | 0x3C0 | 0x400 | 0x440 | 0x2D0 |

Entry 25 at 0x08028F1A is read with `ldrh r0,[r0,#0x32]` (0x080117A6, 0x08011C12, 0x08011CA4); 0x08028F1C starts
another object (reference from 0x0800BD90).

### 5.2 Loader `load_cal_record_from_eeprom(mode, range)` 0x0801167C, branches in code order

RAM 0x20007D5C holds the computed offset.
1. mode == 0xC8: s16 at 0x2E0 -> 0x20007FBE, clamp (section 4), return (0x08011684..0x080116C6).
2. cal mode 0x2000808A == 0 and mode == 9 and range 0x2000803D == 6: u32 at 0x178 -> 0x20007E14, kept if
   -3000..3000 (FUN_08011924, 0x08011924..0x08011946) else 0 (0x080116C8..0x080116F0). Continues.
3. global mode 0x2000803C in 13..15 or 22..24: cal_record_load_va, return (0x080116F4..0x0801173A).
4. mode == 6: u32 at 0x104 -> freq_reference 0x20007E18, kept if 40 000 000 <= v < 60 000 001 (literals 0x02625A00,
   0x03938701; pool 0x08012134 for the upper bound), else 49 152 050 (0x02EE0032); return (0x0801173C..0x08011788).
5. mode 2 or 4 with peak_hold 0x200080B7 == 1: R = 0x2D0 (0x0801178C..0x080117AE).
6. mode 0 (LowZ): R = 0x060 (T[2] + 0x30, ACV range 3) if 0x20008098 != 0, else 0x0A0 (T[1] + 0x30, DCV range 3); range
   ignored (0x080117B0..0x080117E8).
7. mode 2: R = T[1] + 16*range (DCV record) if AC+DC 0x200080BA != 0 and 0x200080BD != 0, else T[2] + 16*range
   (0x080117EA..0x08011846).
8. mode 10 (BEEP): R = T[9] + 0x10 = 0x120 (0x08011848..0x08011868).
9. otherwise R = T[mode] + 16*range (0x0801186A..0x0801188A).
Then (0x0801188C..0x0801190A): offset = i32 BE at R -> 0x20007E00; gain = ui2f(u32 BE at R+4) / D -> 0x20007E10 with
D = 1e4 (0x461C4000) in mode 12 range 4 when 0x20007FDF != 0, D = 1e5 (0x47C35000) in other mode-12 cases, else
D = 1e6 (0x49742400); then busy delay 0x0800ECF6(1). The gain word is converted as unsigned (ui2f 0x08012F74).

Callers: Boot 0x08024DFA (0xC8, 0); Apply 0x0800D844 (mode, range) and 0x0800D86C (6, 0) when mode != 6;
FUN_08006774(1) 0x0800678A (2, 0); FUN_080080C8(1) 0x080080E4 (1, 0) (burden-voltage channel of the current modes,
`analysis/hy3131_modes_ac_current.md` 7.8); 0x080067B4, 0x08008110, 0x0800A6A0 (current mode and range).

### 5.3 Records per mode and range (R = T[mode] + 16*range unless stated)

| Mode | Records | Bytes read | Notes |
|---|---|---|---|
| 0 LowZ | 0x060 (AC), 0x0A0 (DC); AC words 0x068..0x06F | R..R+7; 0x068..0x06F | shares ACV range 3 / DCV range 3 records |
| 1 DCV | 0x070, 0x080, 0x090, 0x0A0 | R..R+7 | also loaded by ACV with AC+DC |
| 2 ACV | 0x030, 0x040, 0x050, 0x060 | R..R+7, AC words R+8..R+0xF | peak 0x2D0 |
| 3 DCmV | 0x0B0, 0x0C0 | R..R+7 | |
| 4 ACmV | 0x0D0, 0x0E0 | R..R+7, AC words R+8..R+0xF | peak 0x2D0 (shared with ACV) |
| 5 TEMP | 0x0F0 | R..R+7 | |
| 6 FREQ | only 0x104..0x107 (frequency reference) | 4 | the slots T[6] + 16*r for r >= 1 are OHM records |
| 7 PULSE | 0x100, 0x110, 0x120 | R..R+7 | 0x110 / 0x120 are the OHM range 0 / 1 records; 0x104 is the frequency reference word |
| 8 DUTY | 0x100 | R..R+7 | |
| 9 OHM | 0x110..0x170 (7 ranges) | R..R+7; 0x178..0x17B range-6 weight (not in cal mode) | |
| 10 BEEP | 0x120 | R..R+7 | = OHM range 1 record |
| 11 DIODE | 0x180 | R..R+7 | |
| 12 CAP | 0x190..0x1E0 (6 ranges) | R..R+7 | gain divisor 1e5 / 1e4 |
| 16 ACuA | 0x1F0, 0x200 | R..R+7; AC words 0x208..0x20F (sub forced 1) | user zero 0x4D0 |
| 17 DCuA | 0x210, 0x220 | R..R+7 | user zero 0x4D8 |
| 18 ACmA | 0x230, 0x240 | R..R+7; AC words 0x248..0x24F | user zero 0x4E0 |
| 19 DCmA | 0x250, 0x260 | R..R+7 | user zero 0x4E8 |
| 20 ACA | 0x270, 0x280, 0x290 | R..R+7; AC words R+8..R+0xF | user zero 0x4F0 |
| 21 DCA | 0x2A0, 0x2B0, 0x2C0 | R..R+7 | user zero 0x4F8 |
| 13, 14, 15, 22, 23, 24 VA | 4 ranges each, 0x300..0x47F | R offset 1 (i32), R+4 gain 1 (u32 / 1e6), R+8 offset 2 (i32), R+0xC gain 2 (u32 / 1e6) | |

Meaning (consumers `cal_subtract_offset_clamp` 0x0800F368, `cal_divide_by_gain` 0x0800F3B8): displayed counts =
(raw - offset) / gain, the gain being raw counts per display count.

### 5.4 Example: the supplied calibration backup in `inputs/binaries` (1200-byte `.BIN` file; file offset = EEPROM offset)

ID 0x03..0x06 = 00 00 00 2A (42); date 0x01..0x02 = 0 (boot uses 1708); rotary 0x08..0x0E = 01 03 06 0A 18 16 13;
0x10 = 01; 0x12 = 00; 0x14 = 00; 0x16 = 01; 0x18..0x19 = 0; 0x1A = 0x0F; 0x1B = 0; 0x1E = 0; 0x1F = 0x00; 0x26 = 0x00.
Records (offset, gain): DCV r0..r3 86/60.774640, 355/62.390040, 286/62.487440, 121/62.585668; ACV r0..r3
19855/62.378900, 19998/62.316040, 19856/62.407200, 20828/622.966208; ACV AC words r0 601, -3069, -363, -3932; DCmV
-596/6.158820; TEMP 673/6.168380; OHM r0 431/7.471020 ... r6 59/124.190536; 0x178 = 271; DIODE 0/30.837266; CAP gains
14.6622, 148.2308, 1479.17232, 1727.0952, 17176.896 (/1e5), 1308.71304; ACuA r0 3815/125.341840; DCuA r0 486/75.104960;
DCA r0 -2900/72.989544; peak 964/1.008192; 0x2E0 = 205; 0x104 = 0 (outside 40e6..60e6, default used); uVA r0
18953/62.392100 and 5136/125.461880; 0x480..0x4AF all zero. All gains decode to positive values of consistent decade
per range family.

## 6. Boot reads and tolerance to blank or corrupted content (v2.05)

`main` 0x08024B40: VTOR; `FUN_0801BE76` (0x08024B4E); `sample_pf8_at_boot` 0x0800C28C; `FUN_08024DE0` (0x08024B56);
`lcd_init(0x20000237)` (0x08024B5C..0x08024B62). Inside `FUN_08024DE0`, after the NJU6350 time read `FUN_0800FF18`
(0x08024DE2, no EEPROM access), in order:

| # | Call | Offset | Blank (0x00) | Garbage |
|---|---|---|---|---|
| 1 | 0x08024DE6 FUN_08010F10 | 0x26 | 0x20007FE0 = 1 | 1 unless 0xA5 |
| 2 | 0x08024DEE FUN_080104BC | 0x1F | 0x20008087 = 1 | 1 unless 0xA5 |
| 3 | 0x08024DFA load_cal_record(0xC8, 0) | 0x2E0 | 0 | outside -1000..1000 -> 0 |
| 4 | 0x08024DFE FUN_08011218 | 0x018 | interval 0 | >= 1000 -> 1 |
| 5 | 0x08024E02 FUN_08011258 | 0x01A | 14 | 14 unless 12..17 |
| 6 | 0x08024E06 FUN_080112A4 | 0x016 | 0 | 0 unless 1 |
| 7 | 0x08024E0A FUN_080112FC | 0x010 | 0 | 0 unless < 2 |
| 8 | 0x08024E0E FUN_08011340 | 0x012 | 0 | 0, then forced 0 at 0x08024E78 |
| 9 | 0x08024E12 FUN_08011394 | 0x014 | 0 | 0 unless < 4 |
| 10 | 0x08024E16 FUN_080113DC | 0x01B | 0 | 0 unless 1 |
| 11 | 0x08024E1A FUN_08011410 | 0x01E | 0 | 0 unless 1 |
| 12 | 0x08024E1E FUN_08010F4C | 0x001 | 1708 | any value 1..65535 accepted; used only as decimal digits (0x0801B090, 0x0800C53C..0x0800C578, 0x0801F38A..0x0801F3C0) |
| 13 | 0x08024E22 FUN_08010F8C | 0x003 | 0 | 0 unless < 100000 |

After boot the first dial latch reads one rotary byte (0x08..0x0E); every reader maps unknown values to a fixed
default mode (section 4), so meter_mode is always 0..24 and T[mode] stays inside the table. Apply then reads the mode's
record, the user-zero record, the frequency reference and the AC words: offsets are not validated (blank gives 0);
gains are not validated (blank gives 0.0) and `cal_divide_by_gain` returns 0 for gain 0.0 (0x0800F3C6..0x0800F3D2);
the CAP branch 0x0800B456..0x0800B466 divides by the gain without a zero test, which in the software float divide gives
a signed infinity (0x08013038) and then f2uiz 0x0801BD24 (no trap, no hang); the frequency reference falls back to
49 152 050; 0x178 and the AC words are clamped; the user zero needs the 0xA5 marker. Integer division by zero cannot
trap (SCB_CCR DIV_0_TRP is never written). Conclusion: no EEPROM content can make v2.05 loop, hang, fault or index a
table out of range at boot or apply; it can only produce wrong readings (unvalidated offsets and gains) or default
settings. UNPROVEN: zero-gain handling in the calibration-time gain users 0x080086AE, 0x08008D46, 0x0800F4EA,
0x0800F610, 0x0800F764, 0x0800F850, and the interval readers 0x08010AD8, 0x0801571A, 0x08017EB4, 0x0801F2DA (not opened).

## 7. Every v2.05 write path and its trigger

### 7.1 Normal operation

| Offsets | Trigger |
|---|---|
| 0x08..0x0E | MODE short that changes the mode: cycle_mode_on_bit0 -> rotary_memory_store (single call 0x08014702). Dial changes and the jack swap never write |
| 0x10, 0x16, 0x1E, 0x1A, 0x18..0x19, 0x03..0x06, 0x14, 0x1B | long SETUP save of setup items 0, 2, 3, 4, 9, 8, 10 (BEEP), 11 (VA). Each save writes the bytes even when unchanged |
| 0x01..0x02 | year save (FUN_08015C94 -> FUN_08015F44 at 0x08015D16) and month save (call at 0x08015DC0), only if SETUP was pressed in the power-on window |
| 0x12 | every RANGE short in DIODE (FUN_080159C8 -> 0x080159EE) |
| one user-zero record 0x4D0..0x4FC | REL long in modes 16..21 at range 0: marker 0xA5, value 0x20007D64 (0x0801644A..0x0801645C) |

The setup-edit timeout `FUN_0800D190` (from main 0x08024C2C) re-reads 0x10, 0x14, 0x16, 0x1E and writes nothing.

### 7.2 Power-on window (`FUN_0800EA3A`)

- MODE then REL: calibration mode (0x2000808A = 1 at 0x0800EAE6..0x0800EAEC, its only store of 1) and
  current_extra_erase_all (0x0800EAF6): A5 00 00 00 00 at 0x4D0, 0x4D8, 0x4E0, 0x4E8, 0x4F0, 0x4F8.
- MEM, REL, MODE: calbin_save (0x0800EB8C), no EEPROM write. MEM, PEAK, MODE: calbin_load (0x0800EBBC).

### 7.3 Calibration mode (0x2000808A == 1)

Request flags: 0x2000808C set at 0x080157A8 (SETUP short, FUN_08015768(0) from 0x08014DCE); 0x2000808E at 0x080157B6
(MEM short, FUN_08015768(1) from 0x08014E54); 0x20008090 at 0x080164EE (MEM long in mode 9 range 6); 0x20008096 at
0x08016500 (MEM long, other modes). The three key branches test 0x2000808A first (0x08014DB2, 0x08014E24, 0x080164CE).
FUN_08015728 refuses (refusal beep) mode 0, 7, 8, and kind 0 (offset) in modes 6, 11, 12 at range >= 2
(0x08015728..0x0801575E). The countdown 0x20008095 (16 means, or 4 in modes 13, 14, 15, 22, 23, 24 and mode 9 range 6;
FUN_080157E8) steps once per 16-sample mean; the write happens in the measurement path when it reaches 0.

| kind | Target | Value | Call sites |
|---|---|---|---|
| 0xC8 | 0x2E0 u16 BE | 0x20007FBE clamped to +-1000 | adc_ch4_process 0x08013A02 (when 0x2000808A and 0x20008096; 0x080139C2..0x080139D4) |
| 0x96 | 0x178 u32 BE | 0x20007E14 after the FUN_08011924 clamp | FUN_0800F470 0x0800F50E (via FUN_0800F37E when 0x20008090) |
| 0, VA modes | R and R+8 (FUN_08011DCE) | 0x20007E24, 0x20007E28 | FUN_080084E0 0x0800866E, FUN_08008B8C 0x08008D0E |
| 1, VA modes | R+4 and R+0xC | f2iz(1e6*0x20007E2C), f2iz(1e6*0x20007E30) | 0x080086EA, 0x08008D78 |
| 0, mode 2/4 with peak hold | 0x2D0 | value | |
| 0, other modes | T[mode] + 16*range (no LowZ, BEEP or mode-6 case) | 0x20007E00 | FUN_0800EF44 0x0800F01A, FUN_0800F6C0 0x0800F738, FUN_0800F7B8 0x0800F824 |
| 1, mode 6 | 0x104 | freq_reference = cnt*150 000 000 / (T*100) (0x0800B6FA..0x0800B71A) | FUN_0800B6F0 0x0800B730 (from counter_compute_frequency 0x0800B612..0x0800B624 when 0x2000808E and mode 6) |
| 1, mode 2/4 with peak hold | 0x2D4 | f2iz(D*0x20007E10) | |
| 1, other modes | T[mode] + 16*range + 4 | f2iz(D*0x20007E10), D as in the loader (0x08011CDA..0x08011D38) | FUN_0800F470 0x0800F606, FUN_0800F6C0 0x0800F792, FUN_0800F7B8 0x0800F87E |
| 2 / 3 | R+8 / R+0xC | - | never called (all 15 call sites pass 0, 1, 0x96 or 0xC8) |

AC words: FUN_0800F8E4 -> ac_words_write (0x0800F9C8) in modes 2, 4, 16, 18, 20 (FUN_08007532 call sites
0x0800758A..0x080075F0); ac_words_clear (0x0800F2E4 in FUN_0800F13C, called from FUN_08015768 at 0x0801578E).
Markers 0x1F (mode 2 range 0) and 0x26 (mode 9 range 6) only from FUN_0800F7B8. FUN_0800F7B8 (called from
FUN_080067D6, FUN_080069B4, FUN_08006AEC, FUN_0800A7FC) writes both the offset (0x0800F824) and the gain (0x0800F87E).
The request flags are never cleared by a mode or range change (their only stores are the completion routines,
FUN_08015768 and the key branches), so a pending request completes in whatever mode is active when the countdown ends.
In cal mode a SETUP short continues into the MEM-short code (0x08014DD4 `bne 0x08014DEE`): a successful offset start
gives the refusal beep pattern (FUN_0800EE6C at 0x08014E68), and in the AC-band case the same reading also starts the
gain-slot step (FUN_08015728(1) at 0x08014E44, FUN_08015768(1) at 0x08014E54).

The user current zero 0x20007E0C is not contained in any value written in calibration mode: the DC offset is the raw
mean 0x20007DD4 (written at 0x0800F01A), the DC gain is built from 0x20007DD4 - 0x20007E00 (FUN_0800F470, written at
0x0800F606), the AC offset and gain are computed from raw means in FUN_0800F7B8 (0x0800F824, 0x0800F87E); the only
readers of 0x20007E0C are 0x080068AC/0x080068AE (AC currents, FUN_080067D6) and 0x08008192/0x08008194 (DC currents,
FUN_08008138), both after the calibration offset and gain and only at range 0; the AC band calibration, which reads
0x20007D64 after that subtraction, is refused for mode 20 (0x0800F288) and for modes 16/18 at range 0 (0x0800F29E,
0x0800F2B4).

### 7.4 What can damage stored calibration in v2.05

- calbin_load overwrites 0x000..0x4AF from an unvalidated file (section 8).
- A calibration completing in LowZ writes the ACV range-0 record 0x030/0x034 (LowZ loads 0x060/0x0A0). The request is
  refused in mode 0 (0x08015730 -> 0x08015746), so this needs a request started in another mode that is still counting
  when the dial reaches LowZ: FUN_08006540 -> FUN_08006AEC (0x0800654C) -> FUN_0800F7B8 (0x08006B60) and FUN_0800F0AC
  (0x08006B2A); or FUN_08007714 (0x08006552) -> FUN_08006418 (0x08007720) -> FUN_0800EEF0 -> FUN_0800EF44 ->
  cal_record_write(0) at 0x0800F01A (OF-07).
- A BEEP calibration writes 0x120 = the OHM range-1 record (BEEP has one range; loader and writer agree on 0x120).
- An offset calibration in FREQ is allowed for ranges 0 and 1 and would write 0x100 (PULSE/DUTY range 0) or 0x110 (OHM
  range 0) if an offset completion ran in mode 6; whether one does is UNPROVEN (the mode-6 path 0x0800AA40 ->
  0x0800AA5E -> frequency_select_range reaches none of the completion callers as far as traced).
- Calibration-mode entry rewrites all six user-zero records (OF-08).

## 8. cal.bin in v2.05 (calbin_save 0x0801CD14, calbin_load 0x0801CF06)

- File "cal.bin" in the card root (string 0x08029290), FatFs file object 0x20006A60, RAM buffer 0x20001240, length
  0x4B0 = 1200 bytes. Identity mapping: file byte i = EEPROM byte i, i = 0x000..0x4AF (save 0x0801CD20..0x0801CD34,
  load 0x0801D07C..0x0801D090). No header, checksum, length field or content check.
- Save: mount (0x0801F84C(10), error 1), open create-always + write (mode 0x0A, up to 10 tries in 0x0801D0D6, error 4),
  one write of 1200 bytes (0x08021F60, error 7 if short), close, reopen for reading, read back 0x200 + 0x200 + 0xB0 and
  compare (error 8 short read, 9 mismatch), set the file time (FUN_0801D37C(1)), unmount. No EEPROM write.
- Load: mount, open for reading (error 4), read 0x200 + 0x200 + 0xB0 into the buffer (any short read: error 8 and no
  EEPROM write, test 0x0801D072..0x0801D076; bytes beyond 1200 are ignored), close, SD off, then write all 1200 bytes,
  read all back and compare (0x0801D092..0x0801D0C6, error 9 at the first mismatch, no rollback).
- Not covered: 0x4B0..0x4FF (OF-12).

## 9. The port: compatibility and protection

### 9.1 Compatibility rules (binding for every module)

1. The port reads every location of section 4 at the same moment (Boot, Apply, dial latch, cal mode), with the same
   width, byte order, sign treatment and the same validation and defaults as v2.05 (sections 4 to 6), except where
   section 10 lists an approved change.
2. The port writes only the locations, values and formats of section 7, under the same user actions, except where
   section 10 lists an approved change. It adds no location (except the port-only settings of 4.1, production image only), erases nothing, never formats the EEPROM, never writes
   0x4B0..0x4CF, the unused bytes +5..+7 of the user-zero slots, or anything at 0x500 and above.
3. The port uses the same programming method: one byte at a time, FTDW = 0, PEKEYR keys 0x89ABCDEF then 0x02030405
   written only when PELOCK reads 1, PELOCK set again after every byte, at most 10 attempts per byte. It never sets PECR ERASE, PROG, DATA, FPRG or
   OBL_LAUNCH, never writes FLASH_PRGKEYR, FLASH_OPTKEYR, FLASH_ACR outside the clock set-up, the option bytes
   0x1FF80000..0x1FF800FF, program flash 0x08000000..0x0805FFFF, or FLASH_WRPRx.  (The one writer of program flash in the
   production image is outside this module: nvm/blinst.s, the first install of the two-part bootloader, limited to the
   starter 0x08000000..0x080003FF, slot A 0x08052000..0x08057FFF, the control records 0x0805E000..0x0805FEFF and the
   firmware mark 0x0805FF00..0x0805FFFF, after a check that the bootloader area is one of EEVblog's builds and the battery
   is at least 4.80 V; DESIGN.md 1, check_image.py role 'blinst'.)
4. Multi-byte values are written MSB first, as v2.05 does (same intermediate states on power loss).

### 9.2 Write classes and the allowed-write table

The NVM module (DESIGN.md 6.21) holds the only copy in the image of the EEPROM base address, the PEKEYR address and
the PEKEY values. The public writers (DESIGN.md Appendix C.2: `nvm_write_setting`, `nvm_write_ident`,
`nvm_write_userzero`, `cal_record_write`, `fn_08011DCE`, `fn_08011E88`, `fn_08011F38`, `nvm_marker_write`, `nvm_restore`)
each belong to one class and end in one internal routine, `nvm_write_bytes(class, offset, length, source)`, which
refuses (status 1, writes nothing) unless every byte offset..offset+length-1 is allowed for the class by a constant
table in flash, `nvm_allow`, generated at build time from this section (`firmware/tools/gen_nvm_allow.py`, DESIGN.md
9.3):

| Class | Bytes allowed | Additional condition checked inside NVM |
|---|---|---|
| SETTINGS | 0x008..0x00E, 0x010, 0x014, 0x016, 0x018..0x01A, 0x01B, 0x01E, and in the production image only the port-only settings of 4.1: 0x00F, 0x011, 0x013, 0x015, 0x017, 0x020, 0x021, 0x022, 0x028, 0x029, 0x02A, 0x02B | none beyond the class (user actions of 7.1; for 0x02B the SETUP page APO; for 0x02A the SETUP battery page; for 0x029 the SETUP page Pt; for 0x028 the SETUP page LP; for 0x022 the SETUP page Ch; for 0x021 the SETUP page bH; for 0x013 the SETUP page dSP, for 0x020 the SETUP pages rEL, CL and tr, for 0x00F the SETUP page tc, for 0x011 the save of the ACV page 11, for 0x015 the SETUP page bt, for 0x017 the SETUP page bL) |
| IDENT | 0x001..0x002 (date code), 0x003..0x006 (serial) | exactly length 2 at 0x001, only while RAM 0x2000808B != 0 (v2.05 gate 0x08015F46..0x08015F4E); exactly length 4 at 0x003 (setup item 8 save, 0x08015F90) |
| USERZERO | 0x4D0..0x4D4, 0x4D8..0x4DC, 0x4E0..0x4E4, 0x4E8..0x4EC, 0x4F0..0x4F4, 0x4F8..0x4FC | length 5 at a record base, first byte 0xA5 |
| CAL | 0x01F, 0x026, 0x104..0x107, 0x178..0x17B, 0x2E0..0x2E1, and the bytes R+0..R+7 of every (mode, range) record of section 5.3, R+8..R+0xF of the AC-word records (modes 2, 4, 16, 18, 20 per ac_words_base) and of the VA records, 0x2D0..0x2D7 | RAM 0x2000808A == 1 (calibration mode), and the target matches the (kind, mode, range) rule of 7.3 recomputed inside NVM from meter_mode and meter_range, with the section 10 refusals |
| RESTORE | 0x000..0x4AF, and the USERZERO bytes | only during `calbin_load` after the whole file has been read, its size accepted and the session armed (9.3) |

The DIODE flag 0x012 is in no class except RESTORE (a cal.bin restore writes it as v2.05 does; OF-23, section 10).
Nothing outside 0x000..0x4FC is in any class.

### 9.3 Defence in depth inside NVM (mechanisms)

1. Arming token: the calling module (not the writer) calls `nvm_arm(class key)` immediately before the writer; it
   stores the key XOR 0x4E564D21 in RAM `nvm_token` (port RAM). `nvm_write_bytes` refuses unless the token matches the
   writer's class and clears the token on return, so one arm allows one write call. A stray branch into a writer or
   into the middle of the write routine finds no valid token.
2. Range re-check at the store: the byte-program routine recomputes `address - 0x08080000`, compares it against
   0x4FC (unsigned, `bhi` to refuse) and looks the byte up in `nvm_allow` again immediately before the `strb`, with
   the address held in one register from the check to the store.
3. Unlock window: PEKEYR is written only inside the byte-program routine, after the checks, and only when FLASH_PECR
   PELOCK reads 1, with exactly the two key words once (as v2.05, 0x0801FA02..0x0801FA18; a key write while unlocked,
   a wrong key or a third write gives a bus error and keeps PELOCK set until reset, RM0038 FLASH_PECR bit 0); PELOCK is
   set again on every exit path, including refusal and timeout. At reset the start-up code sets PELOCK (RM0038 rev 15, FLASH_PECR
   bits 1 and 2: PRGLOCK and OPTLOCK are "set when PELOCK is set", so program memory and option bytes are locked too) before any other work, because the bootloader leaves PECR = 0x4
   (section 2.5).
4. Sticky errors: before each attempt NVM clears FLASH_SR error flags (write 0x1F00 to FLASH_SR bits 8..12) and after
   the write it reads the byte back; an attempt counts as done only when the status is complete and the read-back
   equals the value. At most 10 attempts per byte, as in v2.05.
5. Build-time checks (`make check`, DESIGN.md 9.3 item 2, at instruction level): data-EEPROM addresses, FLASH_PECR,
   FLASH_PEKEYR, FLASH_SR and the PEKEY values only inside the NVM objects; no load or store anywhere whose effective
   address is in 0x40023C10..0x40023C2F (PRGKEYR, OPTKEYR, OBR, WRPR) or 0x1FF80000..0x1FF800FF, no store to program
   flash, no base-plus-offset addressing of the FLASH block, no PRGKEY or OPTKEY value; stores to PECR only set PELOCK
   or clear FTDW; `nvm_allow` equals the table regenerated from this document.
6. Emulator checks: every scenario of `emulator/diff/` runs with the harness EEPROM assertions
   (`expect eeprom_unchanged`, `expect eeprom_written`) and the comparison of committed EEPROM changes against v2.05
   (`emulator/diff/compare.py`, stream `eeprom` and `eeprom_final`); a test build with a deliberate write to 0x030
   from the SETTINGS class must be refused (DESIGN.md section 9.4).

### 9.4 Start-up with any EEPROM content

The port keeps every read-side validation of section 6 and adds none that changes a reading. It contains no loop whose
bound depends on EEPROM content. Every value used as a table index (rotary bytes, setting bytes) passes the v2.05
range check before use, and every divisor read from EEPROM is checked for zero where v2.05 checks it; at the CAP branch
0x0800B456 the port reproduces the v2.05 result of the software float divide by 0.0 (signed infinity, then f2uiz),
so behaviour stays identical without a trap (the port's float routines are bit-exact copies of the v2.05 helpers,
DESIGN.md 6.5).

## 10. Changes to EEPROM behaviour (owner decisions, defect fixes, switches) and the reason for each

| ID | v2.05 | Port | Bytes affected |
|---|---|---|---|
| OF-07 | a calibration completing in LowZ writes the ACV range-0 record; a BEEP calibration writes 0x120, which BEEP loads and which is also the OHM range-1 record | SETUP short and MEM short in calibration mode are refused with the refusal beep in modes 0 and 10; a pending capture whose countdown ends while meter_mode is 0 or 10 is discarded with the refusal beep; NVM refuses CAL kinds 0 and 1 in modes 0 and 10; MEM long (board-temperature offset 0x2E0, mode-independent) is unchanged; LowZ and BEEP keep loading the records they load in v2.05 | no record written from modes 0 and 10 except 0x2E0 |
| NF-09, NF-16 (switches, default refuse) | an offset capture in FREQ, or a capture completing in PULSE/DUTY, would write 0x100/0x110/0x120 (reachability UNPROVEN) | NVM refuses kind 0 in mode 6 and kinds 0/1 in modes 7, 8 (DESIGN.md 7.2) | none |
| OF-08 | entering calibration mode writes A5 00000000 to all six user-zero records | calibration-mode entry writes nothing. When the range-0 offset calibration of a current mode m in 16..21 is saved (DC modes 17, 19, 21: the offset save corresponding to 0x0800F01A; AC modes 16, 18, 20: the MEM completion corresponding to 0x0800F824), NVM writes A5 00000000 to that mode's record only and RAM 0x20007E0C is set to 0, in the same step as the record save. Reason for "at save": the calibration measurement never contains the user zero (7.3) | one user-zero record, only with its own calibration |
| OF-09 | REL long stores the increment 0x20007D64 | REL long stores the accumulated value 0x20007E0C after the addition (same record, marker 0xA5, i32 BE) | base+1..base+4 of the current mode's record |
| OF-12 | cal.bin = EEPROM 0x000..0x4AF (1200 bytes); a longer file is accepted and its first 1200 bytes restored | save writes 1248 bytes: file bytes 0..1199 = EEPROM 0x000..0x4AF, file bytes 1200..1247 = EEPROM 0x4D0..0x4FF (the six 8-byte user-zero slots verbatim; 0x4B0..0x4CF, never used, is not saved). Load takes the size from the file object after opening and accepts exactly 1200 bytes (writes 0x000..0x4AF; 0x4D0..0x4FF untouched) or exactly 1248 bytes (writes 0x000..0x4AF and, for each slot, bytes +0..+4 only); any other size, longer files included, is refused before any EEPROM write with the v2.05 error display. Every byte goes through the RESTORE class | 0x000..0x4AF as v2.05; user-zero bytes only from a 1248-byte file |
| OF-23 | every RANGE press in DIODE writes 0x12, which boot reads and then overrides with 0 | the port does not write 0x12 (15 V selection behaves exactly as in v2.05: lost on mode change and power-up); 0x12 is still read at boot as v2.05 does, with no effect, as in v2.05 | 0x12 no longer written |
| NVM-1 | a sticky FLASH_SR error makes every later write fail silently until reset | error flags cleared before each attempt, read-back verify (9.3 item 4) | none (same contents) |
| NF-13 | v2.05 relies on the bootloader's unlocked PECR until its first write | PELOCK set at reset (9.3 item 3) | none |
| NVM-3 (switch, default off) | writes regardless of battery state | with the switch on, NVM refuses writes while the low-battery flag of `adc_ch5_process` is set (DESIGN.md Q10) | none |
| NF-17 (switch, default off = v2.05) | contrast 10 or 11 saved by the setup editor is replaced by 14 at boot (0x08011264..0x0801127C) | with the switch on, boot keeps 10..17 (DESIGN.md Q11) | none written; read validation of 0x01A only |
| IMP-05 | continuity threshold byte 0x14 holds 0..3; boot and the setup timeout keep < 4, else 0 (0x080113A0..0x080113AE) | codes 0..15 in the same byte (0..3 unchanged; 4..15 per `analysis/autorange_and_scheduler.md` section 9); boot and the setup timeout keep < 16, else 0; written only by the SETUP item 10 save in BEEP, as v2.05. If v2.05 is flashed back, its own < 4 test turns codes 4..15 into 0 | 0x14 values only |
| IMP-07 | 0x017 never accessed | production image only: 0x017 holds the backlight auto-off timer code (4.1); written only by the SETUP page bL save and the MODE long press (bit 7, backlight state) through the SETTINGS class, validated on read (0xFF reads as OFF and dark, a code above 100 as OFF); the strict image does not allow it in `nvm_allow` | 0x017 only |
| IMP-08 | 0x011 never accessed | production image only: 0x011 holds the dBm reference code (4.1); written only by the save of the ACV page 11 through the SETTINGS class, validated on read (above 3 reads as 600 ohm); the strict image does not allow it in `nvm_allow` | 0x011 only |
| IMP-09 | 0x015 never accessed | production image only: 0x015 holds the Bluetooth frame rate code (4.1); written only by the save of the SETUP page bt through the SETTINGS class, validated on read (above 3 reads as 2 per second); the strict image does not allow it in `nvm_allow` | 0x015 only |
| IMP-10 | 0x00F never accessed | production image only: 0x00F holds the thermocouple type code (4.1); written only by the save of the SETUP page tc through the SETTINGS class, validated on read (above 5 reads as K); the strict image does not allow it in `nvm_allow` | 0x00F only |
| IMP-11 | 0x020 never accessed | production image only: bit 0 of 0x020 holds the REL view, bit 3 the clock (IMP-13) (4.1); written only by the saves of the SETUP pages rEL and CL through the SETTINGS class (each changes only its bit), 0xFF reads as 0; the strict image does not allow it in `nvm_allow` | 0x020 only |
| IMP-12 | 0x013 never accessed | production image only: 0x013 holds the display level (4.1); written only by the save of the SETUP page dSP through the SETTINGS class, validated on read (above 1 reads as level 1); the strict image does not allow it in `nvm_allow` | 0x013 only |
| IMP-16 | 0x021 never accessed | production image only: 0x021 holds the continuity hold code (4.1); written only by the save of the SETUP page bH through the SETTINGS class, validated on read (above 3 reads as 100 ms); the strict image does not allow it in `nvm_allow` | 0x021 only |
| IMP-21 | 0x022 never accessed; 0x020 bits 2..1 | production only: 0x022 holds the logging change threshold, 0x020 bits 2..1 the logging trigger (4.1); written only by the saves of the SETUP pages Ch and tr through the SETTINGS class | 0x020, 0x022 only |
| IMP-45 | 0x020 bit 4 never accessed | production only: bit 4 of 0x020 holds the CAP anti-hunting setting (4.1; 1 = on, 0 and an erased 0xFF = off); written only by the save of the SETUP page HUnt (and a BLE settings PUT of id 0x020, value 0..31) through set_b20_store and the SETTINGS class, which changes only the bits of its page; bits 7..5 are kept as found | 0x020 only |

No other EEPROM behaviour changes. Changes not yet approved are listed as open questions in DESIGN.md section 12.
