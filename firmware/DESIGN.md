# 121GW replacement firmware: design

Status: design, before implementation. No source code exists yet.

Target: EEVblog 121GW, STM32L152ZD (Cortex-M3, 384 KB flash, 48 KB RAM, 12 KB data EEPROM; datasheet
`inputs/docs/en.DM00034689`, device summary "48 Kbytes of RAM"). The new firmware is written by hand in Thumb-2 assembly
(GNU as, unified syntax, arm-none-eabi binutils 2.46 in /opt/homebrew/bin) and replaces the original application v2.05.
It is loaded by the unchanged bootloader at 0x08006000 and behaves like v2.05 except for the deviations listed in
section 10.

Sources of truth and how this document cites them:
- The original image `inputs/binaries/EEVBlog2_05.bin` (base 0x08006000) is the truth. Addresses such as 0x0800D2D0 are
  instruction or data addresses in that image; `FUN_xxxxxxxx` and names like `meter_apply_mode_range` are the function
  names of `analysis/decompile/EEVBlog2_05.c` and `analysis/verified_names.txt`.
- Behaviour specifications derived from the image: `analysis/keys_setup.md`, `rotary.md`, `ble_packet.md`,
  `lcd_map.md`, `hy3131_model.md`, `hy3131_modes_misc.md`, `hy3131_modes_ac_current.md`, `frontend_netlist.md`,
  `autorange_and_scheduler.md` (auto-ranging, boot time, beep latency, continuity thresholds, loop structure; cited
  below as ARS).
- Original defects: `firmware/ORIGINAL_FIRMWARE_ISSUES.md` (OF-01..OF-29).
- Data EEPROM: `firmware/EEPROM_MAP.md` (complete map, write paths, protection), cited as EMAP.
- Planned user-visible features and their key, display and storage design: `firmware/FEATURES.md` (the backlight auto-off
  timer, IMP-07, the selectable dBm reference, IMP-08, the Bluetooth frame rate, IMP-09, the thermocouple type, IMP-10, REL in percent, IMP-11, the display level, IMP-12, the 12-hour clock, IMP-13, the statistics, IMP-14, the continuity hold time, IMP-16, and the limit test, IMP-20, are implemented).
- Hardware documents: `inputs/docs` (RM0038 rev 15 reference manual, datasheet, PM0056, HY3131, NJU6350, schematic,
  manual).
- Anything not established by these sources is marked UNPROVEN. Times given as "estimate" are instruction counts, not
  measurements.

Contents
1. Non-negotiable requirements and how the design meets them
2. Image, bootloader contract, memory map
3. Start-up, clocks, interrupts, main loop, timing, low power
4. Hardware safety
5. RAM layout and ownership
6. Modules
7. Calibration, power-on window, cal.bin
8. Conventions (files, syntax, macros, naming, comments)
9. Build, checks and tests
10. Deviation table
11. Optimisation table
12. Risks, open questions
13. Implementation order and parallel work plan
Appendix A: every v2.05 function and its module. Appendix B: RAM variables by primary module.
Appendix C: cross-module interface routines (C.1 replaced v2.05 functions, C.2 new port routines).

---

## 1. Non-negotiable requirements and how the design meets them

| Requirement | Mechanism in this design | Where |
|---|---|---|
| Calibration, serial number and option/settings locations in data EEPROM preserved exactly | Same offsets, widths, byte order, validation and triggers as v2.05; one NVM module holds the only EEPROM write path; write classes with an allowed-byte table generated from EMAP; caller-side arming token; range re-check at the store; instruction-level build checks; emulator EEPROM comparison | EMAP 9-10; 6.21; 9.3 |
| No erase, no reformat, no new locations without approval | NVM sets only PELOCK and clears FTDW in FLASH_PECR, never ERASE/PROG/DATA/FPRG/OBL_LAUNCH; nothing outside 0x000..0x4FC is in any write class; the cal.bin extension (OF-12) adds no EEPROM location; the only new locations are the owner-approved port-only settings of EMAP 4.1 (production image only; so far 0x00F, IMP-10, 0x011, IMP-08, 0x015, IMP-09, 0x017, IMP-07, 0x020, IMP-11, 0x013, IMP-12, and 0x021, IMP-16) | EMAP 4.1, 9.1-9.2, 10 |
| RAM copies of calibration, serial and options keep their v2.05 RAM addresses | every v2.05 RAM variable keeps its address; port-only variables live at 0x20008100 and above | 5 |
| Never brick | program flash, the bootloader region 0x08000000..0x08005FFF, option bytes, RDP and WRP are never written (no instruction with a statically known address may address PRGKEYR, OPTKEYR, WRPR or 0x1FF8xxxx, and the FLASH
block may only be addressed through its own literal with offset 0: coding rule 8.2 and build check 9.3); PELOCK set at reset (the bootloader leaves FLASH_PECR = 0x4, EMAP 2.5); the v2.05 option-byte BOR rewrite (EMAP 2.4) is not carried over; every hardware wait is bounded; the bootloader update path (MEM+HOLD at power-up, then SETUP) works whatever the application does | 2, 3, 9 |
| Start-up tolerates any EEPROM content | v2.05 read-side validation kept byte for byte; no loop bound or table index taken from EEPROM without the v2.05 range check; float helpers are bit-exact copies, so the v2.05 divide-by-zero results are reproduced | EMAP 6, 9.4 |
| Clock set-up never leaves the device unbootable | same clock sequence as v2.05 with bounded waits and an MSI fallback at every step; no change of BOR, option bytes or boot configuration | 3.2 |
| Bootloader accepts the image as it accepts v2.05 | vector table at 0x08006000, initial SP 0x20001240 (passes the only check, `(SP & 0x2FFE0000) == 0x20000000` at bootloader 0x08004994), reset vector with bit 0 set, file size a multiple of 4 and at most 0x5A000 | 2.1 |
| The firmware can never damage hardware | HY3131 configuration only from a table of the v2.05 rows and sequences, checked at build time; pins driven by external devices never become outputs; power and analog-control outputs only in v2.05 combinations and order, with the listed safety improvements | 4 |
| Behaviour identical to v2.05 except documented deviations | port routines replace v2.05 functions one by one (Appendix A); a v2.05-equivalent run mode for strict differential testing; each deviation has an ID, a module, a scenario and an allowlist entry | 3.5, 9, 10 |

---

## 2. Image, bootloader contract, memory map

### 2.1 What the bootloader requires (from `inputs/binaries/bootloader.bin`, by disassembly; behaviour confirmed in the emulator)

- Run check: the bootloader jumps to the application only if `[0x08006000] & 0x2FFE0000 == 0x20000000`
  (0x08004994..0x080049A0). There is no checksum, CRC, magic word, size field, header or EEPROM flag. Jump:
  `msr MSP, [0x08006000]`, `blx [0x08006004]` (0x080049B6, 0x080049BE); the reset vector must have bit 0 set.
- State at application entry: interrupts enabled (PRIMASK 0), VTOR = 0x08000000, TIM2 running with its update
  interrupt IRQ28 enabled and the bootloader's handler 0x08004DD4 writing RAM byte 0x200008A2, NVIC IRQ28, 45 and 53
  enabled, SYSCLK = HSE with the PLL on but not selected, FLASH_PECR = 0x00000004 (data EEPROM and program flash
  unlocked, option bytes locked; key literals in the bootloader pool at 0x08004670..0x08004680, unlock routine called
  from 0x08004B7E, never re-locked), backup domain reset, LCD enabled with a lamp-test pattern. GPIO: PE9 high at
  0x08004324, then PF0..PF2 configured as outputs with PF1 (HY_CS) and PF2 (HY_DI) high at 0x080043E4/0x080043EA and PF0
  low at 0x080043F0, PE8 high, PE4..PE7, PE12, PE13 low, PF6..PF10 outputs (PF8, PF9 high), PD7 low.
- Update path: MEM+HOLD held at power-up, then SETUP within 201 bootloader TIM2 ticks (0x080048FE); file `EEVBlog.bin`
  in the card root; the bootloader erases 0x08006000..0x0805FFFF before reading the file (0x080049CE -> 0x08004B8C),
  programs half pages with read-back, drops the last 1..3 bytes of a file whose size is not a multiple of 4, has no
  upper size check, never writes below 0x08006000 and never touches the data EEPROM. The application cannot affect
  this path as long as it never writes 0x08000000..0x08005FFF or the option bytes.
- Option bytes of the supplied unit (`inputs/binaries/option.bytes`): RDP level 0, USER 0xF0 (BOR off, software
  watchdog, no reset on STOP/STANDBY), WRP all zero (no sector write-protected, the bootloader sectors included). Only
  the application's own discipline protects the bootloader: section 4.6 and the checks of 9.3.

### 2.2 Image rules for the port

| Item | Rule |
|---|---|
| Load address | 0x08006000 (linker script `firmware/link/121gw.ld`) |
| Vector table | 73 words at 0x08006000 (16 system + 57 IRQ, RM0038 Cat.4 table, same count as v2.05): word 0 = 0x20001240, word 1 = `sys_reset` with bit 0 set |
| Output file | `firmware/build/EEVBlog.bin` (raw binary from objcopy), padded with 0x00 to a multiple of 4, at most 0x5A000 bytes; the build fails otherwise |
| Header | none (the bootloader reads none) |
| Flash use | 0x08006000..0x0805FFFF only; nothing at a fixed address except the vector table |

### 2.3 Memory map

| Region | Address | Use in the port |
|---|---|---|
| Bootloader | 0x08000000..0x08005FFF | never executed by the application, never written |
| Application | 0x08006000..0x0805FFFF | vector table, code, constant tables, initial image of `.data_v205` |
| Data EEPROM | 0x08080000..0x08082FFF | EMAP; NVM module only |
| Option bytes | 0x1FF80000.. | never written, never read (v2.05 reads FLASH_OBR only for the BOR rewrite, which is not carried over) |
| RAM | 0x20000000..0x2000BFFF | section 5 |
| Peripherals | RM0038 memory map | GPIOA 0x40020000, B 0x40020400, C 0x40020800, D 0x40020C00, E 0x40021000, H 0x40021400, F 0x40021800, G 0x40021C00 (RM0038 memory map; the v2.05 literals agree, e.g. GPIOF IDR 0x40021810 read at 0x0800612A, GPIOG IDR 0x40021C10 in `sample_pg8_15`) |

---

## 3. Start-up, clocks, interrupts, main loop, timing, low power

### 3.1 v2.05 reset path (reference)

`Reset_Handler` 0x08029174 -> reset_preinit 0x08025F70 (SystemInit shape: MSION, CFGR prescalers /1 and SW = MSI,
HSI/HSE/CSS/PLL off, RCC_CIR = 0, SetSysClock 0x08025FC2, VTOR = 0x08000000 at 0x08025FBE) -> c_startup 0x0802919C ->
cmain 0x0802910C -> data_init 0x08028FE4 (zero-fill 0x20001240..0x200080FB, then lz77 unpack of 0x08029344 into
0x20000000..0x2000023D; the unpacked 574 bytes equal `analysis/decompile/ram_init.txt`) -> `main` 0x08024B40.
SetSysClock: HSEON, wait HSERDY at most 0x5000 polls (0x08025FF0); if ready: FLASH_ACR |= ACC64, PRFTEN, LATENCY
(0x08026018/0x08026024/0x08026030), PWREN, PWR_CR = 0x800 (VOS range 1), wait VOSF clear without bound (0x08026046),
PLL = HSE x12 /3 (CFGR 0x910000 at 0x08026076), PLLON, wait PLLRDY without bound (0x0802608A), SW = PLL, wait SWS
without bound (0x080260AA).
`main`: VTOR = 0x08006000 (0x080208E8 via 0x08024B4A); `FUN_0801BE76` system init (0x08024B4E); `sample_pf8_at_boot`
(0x08024B52); `FUN_08024DE0` state reset and EEPROM loads (0x08024B56); `lcd_init(contrast)` (0x08024B62);
`FUN_0800EA3A` power-on window (0x08024B66); endless loop 0x08024B6A..0x08024DDE.
`FUN_0801BE76`: PWR_CSR WUF test and CSBF (0x0801BE78..0x0801BEA2); FLASH_SR = 0x1F02 (0x0801BEA4); option-byte BOR
check (0x0801BEAC..0x0801BED4, EMAP 2.4); PWR_CR VOS range 1 and wait (0x0801BED8..0x0801BEE8); `FUN_0801BF1A(0)`
(0x0801BEEC); `rcc_lsi_as_rtc_lcd_clock` (0x0801BEF0); DBGMCU_CR |= 7 (0x0801BEF8); `board_gpio_init`,
`gpio_init_analog`, ADC init 0x08013DD4, NVIC 0x0801BFDE, TIM2 0x0801C486, TIM3 0x0801C4D4, AHBENR |= 0xFF
(0x0801BEFC..0x0801BF14).
`FUN_0801BF1A(0)`: HSION, wait HSIRDY without bound (0x0801BF2A); SW = MSI (no SWS wait); MSIRANGE = 6 (4.194 MHz) at
0x0801BF3A; LSE off; HSE off; test HSERDY at once and loop forever at 0x0801BF58 if still set; PLL left on.
`FUN_0801BF1A(1)` (SD card access, called from 0x0801CD38, 0x0801CF14, 0x0801D1B2): HSEON, wait HSERDY at most 0x5000
polls (0x0801FD8A), if ready SW = HSE and HSI off; else stay on MSI.
`rcc_lsi_as_rtc_lcd_clock` 0x0801BF92: DBP, RTCRST pulse (backup-domain reset at every boot and wake), LSION, wait
LSIRDY, RTCEN, RTCSEL = LSI (the LCD runs from RTCCLK).

### 3.2 Port start-up sequence (module SYS)

1. `sys_reset` (reset vector): `cpsid i`; NVIC_ICER0/1 = 0xFFFFFFFF and NVIC_ICPR0/1 = 0xFFFFFFFF (disables and clears
   the bootloader's IRQ28/45/53 sources); TIM2's own registers are left as the bootloader left them (counter running,
   UIE set), as in v2.05, so that the port's handler, once `sys_nvic_init` enables IRQ28, sees the same two start-up
   updates as v2.05 (bootloader period expiry, UG of the TIM2 set-up; boot_v: 35.885 ms and 36.971 ms) and every
   TIM2-derived flag keeps v2.05's phase (integration 2026-10-31: clearing DIER/SR put them 2 ticks, 20.04 ms, behind);
   `nvm_reset_lock` (NVM: FLASH_PECR PELOCK = 1;
   RM0038 rev 15 FLASH_PECR bits 1 and 2: PRGLOCK and OPTLOCK are "set when PELOCK is set", so program memory and option
   bytes are locked too). Reason: the bootloader leaves interrupts enabled with its own TIM2 handler active and the
   flash unlocked (2.1) (NF-12, NF-13).
2. VTOR = 0x08006000 (v2.05 sets it later, in `main`; doing it first removes the window in which a fault would use the
   bootloader's table).
3. Clock pre-init equal to reset_preinit 0x08025F70 and SetSysClock 0x08025FC2 (HSE attempt, ACR, VOS range 1, PLL x12
   /3). Every wait has a bound: HSERDY 0x5000 polls as v2.05; VOSF, PLLRDY and SWS 0x5000 polls each; on a timeout the
   sequence stops, SW is set to MSI and start-up continues on MSI. VTOR is not written back to 0x08000000.
4. RAM init: copy the 574-byte `.data_v205` image to 0x20000000..0x2000023D; zero 0x20001240..0x200080FB and
   `.bss_port`; write the stack canary (5.3). The image bytes equal `ram_init.txt` (build check). This replaces
   data_init + lz77 with identical RAM content at the entry of `main` (6.27).
5. `sys_main` (replaces `main` 0x08024B40): `sys_system_init` (replaces `FUN_0801BE76` without the option-byte block:
   PWR flags, `nvm_clear_errors` = FLASH_SR <- 0x1F02 where v2.05 does it at 0x0801BEA4, VOS range 1, clock select,
   LSI/RTC, GPIO, analog pins, ADC, NVIC, TIM2, TIM3, AHBENR; every wait bounded at 0x5000 polls, the HSERDY-clear wait
   included, which replaces the endless loop at 0x0801BF58), `sample_pf8_at_boot`, `set_state_reset` (`FUN_08024DE0`),
   `lcd_init(contrast, 1)`, `bootwin_start` (7.1; it calls `cal_cache_load` (6.20) just before the splash, whose wait
   for the end of lcd_init's display update absorbs the 1.78 ms copy, so the copy adds no time to the start-up), then
   the main loop (3.5).
6. `cpsie i` after the NVIC set-up inside `sys_system_init`. v2.05 never masks interrupts (no `cpsid`/`cpsie` in the
   image); its interrupts become live when `FUN_0801BFDE` enables them in the NVIC.

Not carried over from v2.05 start-up, with the reason:
- The option-byte BOR rewrite and OBL_LAUNCH (0x0801BEAC..0x0801BED4, including the FLASH_SR = 0xF02 clear at
  0x0801BEC6 inside that branch): forbidden by the never-brick requirement; a unit with BOR_LEV != 0 keeps its BOR level
  (NF-03).
- DBGMCU_CR |= 7 (0x0801BEF8): set only in debug builds (`DEBUG=1`), deviation NF-18. With DBG_STOP = 1 the internal
  RC oscillator stays active and FCLK/HCLK run in STOP (RM0038 rev 15 DBGMCU_CR bit 1), so a v2.05 meter never enters
  the low-current STOP state; the production image does. This changes STOP current and possibly wake-up timing on real
  hardware and is therefore a deviation tied to the hardware test (Q8), not an optimisation.
- Semihosting exit 0x0802912A..0x0802913C: unreachable (`main` never returns); `sys_main` never returns either.

### 3.3 Clock plan (identical to v2.05)

| Phase | SYSCLK | v2.05 source |
|---|---|---|
| Reset pre-init | HSE x12 /3 PLL if HSE starts (16 MHz with the 4 MHz crystal of the schematic text; crystal value UNPROVEN), else MSI reset range | 0x08025FC2 |
| Run | MSI range 6 = 4.194304 MHz nominal; HSI on (ADC clock); PLL left on | `FUN_0801BF1A(0)` |
| SD card access | HSE direct if it starts within 0x5000 polls, else MSI | `FUN_0801BF1A(1)` |
| Before STOP | MSI range 0 (65.536 kHz), VOS range 3 | `FUN_0801C522` |
| RTC/LCD | LSI, RTCSEL = LSI, backup domain reset at every init | 0x0801BF92 |

HCLK = PCLK1 = PCLK2 = SYSCLK. Timers: TIM2 PSC 260, ARR 160 -> 99.81 Hz (10.02 ms); TIM3 PSC 260, ARR 15 -> 1004.4 Hz
(0.996 ms) at nominal MSI (0x0801C490, 0x0801C49E, 0x0801C4DE, 0x0801C4EC; emulator measurement 10.019 ms / 0.996 ms).

### 3.4 Interrupt map and priorities

SCB_AIRCR PRIGROUP = 5 (2 preemption bits, 2 subpriority bits, 0x0801BFE4). The port enables exactly v2.05's set with
the same priorities and writes every priority explicitly. Handler modules follow Appendix A (all in worker W1 except
the USART2 and SD handlers).

| IRQ | Source | IPR byte (pre/sub) | v2.05 handler | Port handler (module) | Work (v2.05) |
|---|---|---|---|---|---|
| 28 | TIM2 update | 0xA0 (2/2) | 0x0802428C | `sys_tim2_isr` (SYS) | 10 ms flag 0x200080D0, countdowns, 100 ms flag 0x200080D1, 500 ms flag 0x200080D3, BLE frame request at count 40 and frame start at 50, logging tick, MEM-view timeout (`FUN_080153AC`), blink phase, jack-warning beep, setup page 7 blink drawing |
| 29 | TIM3 update | 0x50 (1/1) | 0x08024722 | `bzb_tim3_isr` (BZB) | power-on window counter 0x2000022E, buzzer countdown and repeat pulses on PE7; production only: countdown of the HY counter-restart wait `hy_restart_ticks` (6.13, IMP-06) |
| 38 | USART2 | 0x00 (v2.05 never writes it; reset value 0) | 0x080247D8 | `ble_usart2_isr` (BLE) | TXE: next byte of the 19-byte frame; RXNE: receive buffer 0x20007B80 |
| 45 | SDIO | 0x00 | 0x080248B8 -> 0x08023476 | `sd_sdio_isr` (SD) | SDIO status |
| 53 | DMA2 channel 4 | 0x00 | 0x080248C0 -> 0x08023524 | `sd_dma_isr` (SD) | DMA flags |
| 6..10, 23, 40 | EXTI | pre 0, sub = line & 3 | 0x080248E8..0x080249A8 | `brd_exti_isr` (BRD) | clear pending bits; armed only before STOP |
| SysTick, 3 (RTC WKUP), 18 (ADC) | - | never enabled by v2.05 | 0x080248B0, 0x080248C8, 0x08024A24 | ported as equivalent handlers (SYS; BRD) | unreachable in v2.05 (SysTick never started: no SYST_RVR/CVR literal; IRQ3 and IRQ18 never enabled); ported so that no v2.05 code is dropped |
| NMI, SVC, DebugMon, PendSV | - | - | `bx lr` | `bx lr` (SYS) | |
| HardFault, MemManage, BusFault, UsageFault, every unused IRQ | - | - | `b .` | `sys_fault_safe` (SYS, 4.7) | v2.05 hangs; the port makes the outputs safe and powers down (NF-14) |

Preemption order: USART2, SDIO, DMA2 CH4, EXTI (0) > TIM3 (1) > TIM2 (2) > main.

ISR context rules (binding for every module):
- An ISR calls only routines whose header says `Context: ISR-safe`. HY3131 SPI, EEPROM programming, SD card access
  and LCD commit are main-only (v2.05: no enabled handler reaches `hy3131_write_regs` 0x0800C03C or the read routine
  0x0800C0C0; the port keeps that).
- A variable written in an ISR and read-modify-written in main (for example 0x2000022E, 0x20007FB4, 0x20008079,
  0x2000807A) is changed in main only inside `CRIT_ENTER`/`CRIT_EXIT` (PRIMASK save, `cpsid i`, restore) or with
  `ldrex`/`strex`. Single byte and aligned halfword/word stores need no protection (single-copy atomic, PM0056).
- `FUN_080153AC` (end of MEM view, called by v2.05 from IRQ28 at 0x08024356) only stores bytes and calls `FUN_0800D718`
  (default setup item, byte stores) (0x080153AC..0x080153E2); both are ISR-safe (their headers say so) and the call
  stays in `sys_tim2_isr`.
- v2.05 draws on the LCD from the TIM2 handler (`FUN_0801896C(1)` at 0x080246FC when setup page 0x20008037 == 7) while
  main read-modify-writes the same shadow words 0x20007790: a lost-update race by construction (effect not
  demonstrated: UNPROVEN). The port moves that drawing to main: the ISR sets `rtc_blink_request` (port RAM, owner RTC)
  and main draws on its next pass (NF-11).

### 3.5 Main loop and timing

The loop body is v2.05's, step for step, with the same flags and order (0x08024B6A..0x08024DDE):

| Step | Condition | Work (v2.05 function -> port module) |
|---|---|---|
| 1 | every pass | `hy3131_poll` 0x08006124 -> HY (HY3131 event line PF3; CAP timeout `FUN_0800B540` when mode 12 and 0x20007FC4 < 5) |
| 2 | 0x2000805D | `FUN_0800DCFC` -> FUNC (post-processing, calls AR); mode 0: `FUN_08006558` -> MRES (LowZ AC/DC select); 0x20008061 = 1 |
| 3 | every pass | `FUN_08016D34` -> UI (display refresh, skipped in MEM view) |
| 4 | 10 ms flag 0x200080D0 | `FUN_08014948` DIAL, `FUN_0801680C` KEY, `sense_pe10_pe11` DIAL, `FUN_0800ED64` MFRQ, `FUN_0800D664` UI, `FUN_080100C4` RTC (seconds register, 1 s flag 0x200080D4), RTC blink request (NF-11) |
| 5 | 100 ms flag 0x200080D1 | `FUN_0800FF18` RTC, `FUN_0801349C` BRD (ADC alternation), `log_compose_mode_range` LOG |
| 6 | 0x200080D2 | clear (no setter exists in v2.05; kept) |
| 7 | 0x2000802C | clear; if BLE on 0x2000802B: `FUN_0800C5D2` BLE (build frame) |
| 8 | 500 ms flag 0x200080D3 | if setup edit 0x2000806E: `FUN_0800D190` SET |
| 9 | 1 s flag 0x200080D4 | `FUN_0800FF18`; 0x20007FFA = 0; logging interval; `pwr_apo_second` (3.6); production only: `pwr_bl_second` (IMP-07); 0x200080E6; `FUN_08019CBC` LCD |
| 10 | 0x20007FE1 and 0x20007FE2 | `FUN_08010B64` LOG |
| 11 | 0x20008030 | `FUN_0800C332` BLE |
| 12 | 0x2000801C | `FUN_0801D126` LOG (SD log write) and its error handling |
| 13 | 0x2000804A or 0x2000804B | `meter_apply_mode_range(1)` MODE, then the HOLD-stage-2 clears |
| 14 | 0x2000803A | `enter_stop_and_reinit` PWR |

Loop structure (decided; ARS section 10 verdict): no cooperative scheduler. The port has two run modes, selected by the
build switch `LOOP_V205` in `config.inc` until 2026-11-04; since then each mode is its own branch: the baseline
(`LOOP_V205 = 1`) is the like-v2.05 build on the branch `like-v2.05`, the production mode is the only build of `main`,
whose sources no longer contain the switch:

| Item | `LOOP_V205 = 1` (verification baseline) | `LOOP_V205 = 0` (production, IMP-06) |
|---|---|---|
| LCD commit | `lcd_commit_shadow` busy-waits on LCD_SR UDR as v2.05 (0x0801B304, 0x08020492); in v2.05 this locks the pass to the 13.84 ms LCD frame (ARS 11 item 1) | commit only when the shadow changed; deferred to a later pass while UDR is still set; never waits |
| Blocking routines | run to completion (counter restart delay(10000) 0x0800BFCE (17.1 ms in v2.05, ARS re-measured 2026-11-01), `pe7_on_blocking_100_ticks` 1 s, SD card operations, calibration-backup operations) | the same routines as state machines (`*_start`, `*_step` returning 0 = busy / 1 = done), stepped once per pass; a wait inside such a routine is measured in timer ticks, never in passes (a production pass lasts until the next interrupt): the counter-restart wait is 19 TIM3 ticks (17.92..18.92 ms, >= v2.05's 17.1 ms; 6.13); in baseline mode the loop calls `*_step` until it returns 1, which is the v2.05 order |
| HY3131 read | full 0x34-byte burst from register 0 per event (0x08006158) | per-event read sets (6.13) |
| Sleep | none (v2.05 never sleeps) | `wfi` at the end of each pass; wake-ups are the interrupts v2.05 already enables (TIM3 every 0.996 ms, TIM2, USART2, SDIO, DMA2); no new interrupt source |

Baseline mode exists to verify every module against v2.05 with the strict differential harness (lcd, spi, uart, gpio,
eeprom, sd streams with one-tick tolerance, `emulator/diff/compare.py`). Production mode is the shipped image; its
differences from v2.05 are deviations OF-31 and IMP-01..IMP-06 with their own scenarios. Every module routine called from the
loop is run-to-completion and returns, so both modes call the same code. ARS section 10.3: AD1 latency and beep
response are bounded by the 1 ms TIM3 wake in production mode; the MCU current gain comes from sleeping instead of
busy-waiting (datasheet Table 17/19 figures quoted there).

### 3.6 Low power: APO and STOP

v2.05 (reference):
- APO counter u16 0x20000230, initial 1800 (RAM image), reloaded by `FUN_0800ED26` (1800, or 3600 while MIN/MAX is
  active). Decremented on each 1 s flag only when APO is enabled (0x20008039 == 0), MIN/MAX off and logging off
  (0x08024CAE..0x08024CC4). At 60: five 0.5 s warning beeps (0x08024CEE..0x08024D1A). At 0: 0x2000803A = 1 (0x08024CDA).
- `enter_stop_and_reinit` 0x08024ECA: "-oFF-" with a 1 s beep (`pe7_on_blocking_100_ticks`); clear 0x2000803A and BLE
  0x2000802B; `FUN_0801C522`, which first calls `power_down_peripherals` 0x0801C584 (at 0x0801C524; PE7, PE8 low; LCD blank, disable, clock off;
  PB6/PB7; HY bus PF1/PF2 high and PF0 low; `FUN_0800FC60(0x64)`; PE12, PE13, PE5, PA11, PA12, PH2, PE15, PF6 low; USART2
  off with PF15 low; ADC off; PE9 low), then timers off, PVD off, ULP, minimal clocks, SysTick off, RCC_DeInit, VOS
  range 3, MSI range 0, RTC wake-up interrupt off, HSI/HSE/LSE off, all GPIO analog except PA13/PA14, GPIO clocks off,
  `FUN_0801C61C` (PG inputs with pull-up except the latched dial line, EXTI falling edge on those lines, NVIC enable);
  STOP by `FUN_080207CC(1, 2)` (LPSDSR, SLEEPDEEP, one `wfe` at 0x080207F6, interrupts unmasked: the image contains no
  `cpsid`). The EXTI interrupt wakes the core and its handler clears the pending bit. After wake: 0x20008038 = 1, full
  system init, state reset, `lcd_init`, power-on window.

Port (same sequence, with these changes, section 10):
- HW-08: the TIM2 and TIM3 update interrupts are disabled first (v2.05 stops the timers only at 0x0801C92E, after
  `power_down_peripherals`), then the buzzer state (0x20007FB4, 0x2000807A, 0x20008079) is cleared and PE7 set low
  (`bzb_silence`). In v2.05 two interrupt paths can raise PE7 after `power_down_peripherals` cleared it at 0x0801C58C:
  the TIM3 repeat pulse (0x080247D4, when a repeat count is pending) and the TIM2 jack-warning beep
  `pe7_on_with_timeout(500)` (0x08024690..0x0802469E, when 0x20008077 and 0x20008076 or 0x200080B2 are set); with the
  timers then stopped, PE7 can stay high into STOP (reachability not demonstrated: UNPROVEN).
- HW-02: PF0..PF2 analog immediately before PE9 low.
- NF-05 (wake mechanism, race-free): SCB_SCR.SEVONPEND = 1 and SLEEPDEEP = 1; `cpsid i`; loop { if (EXTI_PR & armed
  mask) != 0: leave; `wfe` }; then clear SLEEPDEEP and SEVONPEND and `cpsie i`, after which `brd_exti_isr` runs and
  clears the pending bits as v2.05's handlers do. With SEVONPEND, a pending interrupt sets the event register even while
  masked (ARMv7-M SCR.SEVONPEND; PM0056 SCR), so an edge that arrives between the test and the `wfe` ends the `wfe`; an
  event without an armed pending line (v2.05 would wake and re-initialise) sends the core back to STOP.
- NF-06: after wake the EXTI lines and their NVIC enables are disabled (v2.05 leaves them enabled; the handlers only
  clear pending bits).

---

## 4. Hardware safety

Goal: no firmware state can damage the meter. Evidence is from the v2.05 image and the schematic. MCU pin-to-net
assignments come from the position of the net label next to the pin number in
`inputs/docs/121GW_circuit_diagram.pdf` (text alignment) unless `analysis/frontend_netlist.md` traced the wire, so they
are UNPROVEN as wiring unless stated. BRD owns every GPIO configuration; HY owns every HY3131 transaction.

### 4.1 HY3131 write whitelist (table-driven, build-time checked)

v2.05 writes the HY3131 only through `hy3131_write_regs` 0x0800C03C, from exactly 8 call sites:

| Call site | Function | Registers, bytes | Condition |
|---|---|---|---|
| 0x0800616C | `hy3131_service_irq` | 0x1E <- 0x00 | after every 0x34-byte burst read (0x08006158) |
| 0x0800A872, 0x0800A88C | `FUN_0800A7FC` (peak restart) | 0x29 <- rx29 & 0xFB, delay(10), 0x29 <- rx29 | rx[0x29] bit 2 set and AC+DC off; not in modes 13..15 |
| 0x0800BE94 | `hy3131_load_config_regs` 0x0800B994 | 0x20..0x33 <- one 20-byte row | every `FUN_0800B974(mode, range)` |
| 0x0800BF74 | `hy3131_set_irq_enable` 0x0800BEAC | 0x1E <- 0x00, 0x1F <- INTE in {0x01, 0x04, 0x05, 0x11} | right after the row |
| 0x0800BFC6, 0x0800BFF0, 0x0800C036 | `hy3131_counter_restart` 0x0800BF8C | 0x20 <- c & 0xFD (modes 6..8) or c & 0xF9; delay(10000); 0x1B..0x1D <- 00 00 E0 or 00 00 80; read back; 0x20 <- c \| 0x02 | after every row, and on every counter result |

Rows: 41 distinct 20-byte rows (47 distinct row/INTE pairs) in the flash tables 0x080285BC, 0x080286D0, 0x08028748,
0x080288A0, 0x08028904, 0x080289C8, 0x08028D1C, 0x08028D58, 0x08028D94, 0x08028F1C, 0x08028F44, 0x08028F6C,
0x08028F94, 0x08028FBC, 0x08029150, selected by mode, range and the flags 0x20008098 (LowZ AC), 0x200080BA (AC+DC),
0x200080BD, 0x200080B9 (1 kHz filter), 0x200080B7 (peak), 0x20007FDF (CAP variant), 0x200080C4/C6/C7 (VA channel and
sub-ranges) and 0x20007FE0 (OHM range 6: byte 10 &= 0xF7); LowZ AC modifies row 3 of 0x080289C8 (byte 10 |= 0x20,
byte 14 = (byte 14 & 0x7F) | 0x20) (selector 0x0800B9B6..0x0800BE5C; `analysis/hy3131_model.md` 3,
`hy3131_modes_misc.md` 3, `hy3131_modes_ac_current.md` 2). Never written by v2.05: registers 0x00..0x1A and 0x34..0x3F,
in particular no soft reset (0x37 = 0x60). Datasheet-hazardous settings never used by v2.05: ENXI = 1, ENOSC = 0,
SAGND = 11, ENREFO/ENBIAS/ENVS = 0, ENOP2 = 1, SMODE bit 6, bits documented as 0.

Port mechanism:
1. `hy_rows`: the port's row tables hold the v2.05 tables byte for byte (copied by `firmware/tools/extract_tables.py`
   into `firmware/src/hy/hy_rows.s`, each row commented with its v2.05 address and users). The row selector
   (`hy3131_load_config_regs`) only indexes these tables; the only byte modifications are the two v2.05 ones above,
   coded as constants.
2. Mode and range are bounds-checked before selection (mode <= 24, range < range_count[mode]); out of range means no
   HY3131 write (v2.05 would send 20 uninitialised stack bytes for a mode > 24, 0x0800BA2E, and an uninitialised INTE,
   0x0800BF06; unreachable as far as traced) (NF-15).
3. INTE comes from a table of the v2.05 cases (0x0800BEB8..0x0800BF6A). The counter-restart and peak-restart bytes are
   computed from the current row (v2.05 uses the SPI read-back copies 0x2000807D, 0x2000807E); the values are equal
   whenever the read-back is correct, and a corrupted read can no longer produce a value outside the whitelist (HW-05).
   The peak restart moves from MAC into HY as `hy_peak_restart` (Appendix C.2).
4. `hy_write_frame(r0 = first register, r1 = pointer, r2 = count)` is internal to HY and refuses any (first register,
   count) shape not in {(0x20, 20), (0x1E, 2), (0x1E, 1), (0x20, 1), (0x1B, 3), (0x29, 1)}.
   The one-byte INTF acknowledge (0x1E, 1) after an event service carries 0 for the flags read as set and 1 for the
   others (OF-53, decision 12.2), where v2.05 writes 0x00: any value with bits 6:5 clear is accepted. INTF is a flag
   register, not a configuration register: a written 0 clears a flag, a written 1 has no effect ("INTF register can be
   written as 0 by SPI Interface, but not 1", DS p19 10.2 (7)); bits 6:5 carry no flag ("-", DS p19) and stay 0 as in
   v2.05's value. `check_hy.py` (INTF_ACK) and the emulator whitelist (`emulator/diff/run.py` INTF_ACK_PAIRS) allow
   exactly these values; no configuration register value is added.
5. OF-17 is fixed by refusing the second key (PEAK while the 1 kHz filter is on, or the filter while PEAK is on), so
   row and INTE always form a v2.05 pair; no combined row is created. OF-16 changes no HY3131 write.
6. Reads are not configuration writes: the per-event read sets of production mode (6.13) change only which registers
   are read; the whitelist (writes) is unaffected. Read side effects per the datasheet (INTF cleared by reading, DS p19;
   CTBOV cleared by reading CTSTA, DS p36) are respected by the read-set rules of 6.13.
7. Build check (`make check`): every row in `hy_rows` equals the v2.05 image bytes at its cited address; the set of
   (row, INTE) pairs reachable through the port selector (enumerated by `firmware/tools/check_hy.py` over all modes,
   ranges and flag values) equals the v2.05 set (47 pairs); no code outside `hy_write_frame`/`hy_read_frame` writes
   GPIOF BSRR bit 0 (HY_CK) high, so no other code can clock a bit into the HY3131; outside HY, BSRR bits 1..2 and the
   clear of bit 0 are written only by the BRD idle-level code (board init 0x0801C196..0x0801C1A6, power-down
   `FUN_0801C8EC`, fault-safe state) (instruction-level scan).
8. Run-time check in the emulator: `emulator/emu/safety.py` compares every HY3131 write frame with
   `emulator/diff/hy3131_whitelist` (generated from v2.05 runs by `emulator/diff/run.py --make-whitelist`) and stops the
   machine on any other write.
9. Order and timing: the v2.05 frame order (row, INTE, restart phase 1, delay, presets, read-back, phase 3) and bit
   timing (delay(10) after each byte, delay(1) around each clock edge, `FUN_0800ECF6`) are kept. The 20-byte row has no
   break-before-make step in v2.05; harm UNPROVEN; the port produces exactly the v2.05 transitions and adds none.

### 4.2 Pins driven by external devices

| Pin | Net (source) | External driver | v2.05 configuration | Port rule |
|---|---|---|---|---|
| PF3 | HY_DO, HY3131 pin 32 (frontend_netlist.md 2.1) | HY3131, always (datasheet 7.2 (4)) | input pull-up (0x0801C170..0x0801C18C), analog before STOP | input pull-up or analog only |
| PE10, PE11 | FUSE_mA, FUSE_A (U5 TLC272 via R56/R63 10 kohm) | comparator outputs | input no pull (`gpio_init_pe10_pe11_inputs` 0x0801C368), analog | input or analog only |
| PD6 | BT_RX (BLE module TX via R71 100 ohm) | BLE module when PF15 is high | AF7 USART2_RX with pull-up (0x0801C3A6..0x0801C3E0), analog | AF7 or analog only |
| PC8, PD2 | SD_D0, SD_CMD | SD card | AF12 under SDIO control (`sdio_gpio_init` 0x08023D56), input after `sdio_gpio_deinit` 0x08023CD8, analog | AF12, input or analog only |
| PB7 | EE_DO, NJU6350 pin 7 DATA | NJU6350 in read mode, from the 4th command clock falling edge until CE falls (NJU6350 datasheet, data reading) | push-pull output except between `rtc_data_pin_input_pullup` (0x0801025E) and `rtc_data_pin_output` (0x080102A4, while CE is still high): two windows of about 50 us (estimate) per RTC read, the seconds register being read every 10 ms; current UNPROVEN | open-drain output with the internal pull-up for the whole NJU6350 transaction; the MCU writes 1 (released) from the rising clock edge of command bit 4 until CE is low (HW-01). Rise time with the internal pull-up against the v2.05 bit timing (delay(5) per half clock, about 10 us estimate): derived from RM0038/datasheet pull-up and pin capacitance values, UNPROVEN until measured |
| PH0, PH1 | OSC_IN/OSC_OUT | crystal | never GPIO except analog after HSE off (0x0801CA0C before 0x0801CA22) | same |
| PA13, PA14 | SWD | debugger | never reconfigured (analog mask 0x9FFF) | same |
| PG0..PG15 | dial contacts and keys to VSS | switches | input pull-up; EXTI before STOP | input pull-up only |

Mechanism: BRD is the only module that writes MODER/OTYPER/OSPEEDR/PUPDR/AFR (v2.05 configures pins only through
`gpio_init` 0x0801BD48 and `gpio_set_alternate_function` 0x0801BE04). `brd_gpio_init` checks every request against
the constant table `brd_pin_policy` (per port: masks of pins allowed as push-pull output, open-drain output, AF with the
allowed AF number, input, analog) and refuses any request outside it. It writes the output level (BSRR) before
switching MODER to output, so no pin drives a stale ODR value (v2.05 writes MODER first, 0x0801BD86) (HW-04). Exception:
PE9 keeps the level it has when port E becomes an output and is set high after the other port E pins, as in v2.05: at a
cold start the bootloader has left it high (no change); at the wake from STOP it goes Z -> 0, PE12 (SHDN_A) goes low with
the HY3131 supply still off, and PE9 rises at the v2.05 step 0x0801C0CE (4.3 rule 1; scenario `apo_stop_wake_short`;
setting PE9 high first made PE12 fall with PE9 high, a power step v2.05 never makes). Build check 9.3 item 4 decodes every `brd_gpio_init` call.

### 4.3 Power sequencing

Supply and enable outputs (nets by text alignment): PE9 PWR_CTL (U1 NJM2870F-36, VDD), PD1 PWR_CTL2 (U13 NJU7741F04,
+4.0 V for U17 AD8436), PF15 BT_CTL (BLE module supply), PF6 ENB (U10 RT9271 boost), PE12 SHDN_A (U8 MAX4238). The
emulator's safety monitor compares the change sequence of these five pins with v2.05 (`emulator/emu/safety.py`
check 3).

v2.05 order:
- Cold boot: PE9 high and the HY bus driven by the bootloader (PE9 at 0x08004324, PF1/PF2 high at 0x080043E4/0x080043EA
  within microseconds); `board_gpio_init`: PD1 high 0x0801C094, PE9 high 0x0801C0CE (no edge), PE8 low, PE7/PE12/PE13/PE5
  low, HY bus PF1/PF2 high, PF0 low 0x0801C196..0x0801C1A6, PF15 low 0x0801C240, PE15 low 0x0801C2A2, PF6 low
  0x0801C2AA; first HY3131 transaction at 0x0800EA8A (TEMP row) in the power-on window, after `lcd_init`.
- LCD: `lcd_init` 0x0801B450: pins AF11, LCD clock, FCR PS = 3 DIV = 0, wait FCRSF (bounded 0x8000), CR 1/4 duty, 1/3
  bias, internal step-up, contrast CC 0..7 for settings 10..17, DEAD 0, PON 4, LCDEN, wait ENS and RDY without bound
  (0x0801B4A6..0x0801B4B8); before STOP the display RAM is cleared and committed, LCDEN cleared, wait ENS clear without
  bound (0x0801C918), clock off.
- BLE: PF15 high (0x0801C39C) before PD5/PD6 become AF7; PF15 low first at deinit (0x0801C95C).
- STOP: PE7, PE8 low; LCD off; PB6/PB7; HY bus PF1/PF2 high, PF0 low (0x0801C5B4); `FUN_0800FC60(0x64)`; PE12, PE13,
  PE5, PA11, PA12, PH2, PE15, PF6 low; PF15 low; ADC off; PE9 low (0x0801C618); PD1 is never cleared (it floats at the
  all-analog step 0x0801CA22, about 80 ms later, estimate at 65.536 kHz). PF1/PF2 stay driven high from 0x0801C618 to
  0x0801CA22.
- Wake: `board_gpio_init`: PD0/PD1/PD7 drive their pre-STOP ODR (high) before PE9 rises (0x0801C08A); PE9 high
  0x0801C0CE; HY bus driven about four `gpio_init` calls later (about 0.3 ms, estimate); no wait for VDD.

Port rules:
1. The five-pin power vector changes in the same order as v2.05 at boot, BLE on/off, DIODE 15 V on/off, STOP and wake.
2. HW-02: immediately before PE9 goes low, PF0/PF1/PF2 are set to analog (high impedance), so no MCU output drives an
   HY3131 input while VDD decays. Whether PE9 removes the HY3131 supply while the MCU stays powered is UNPROVEN (the
   capacitors next to U4 carry VDD_P labels; U4 supply pins not wire-traced); the change is harmless either way.
3. HW-03 (wake only): after PE9 goes high, the HY bus pins are configured last in `board_gpio_init` (after every other
   pin), then held off for `HY_VDD_SETTLE_US` more microseconds. The value is not settled by the sources: the NJM2870
   start-up time is not in the supplied documents, and on cold boot the bootloader drives the bus within microseconds of
   PE9 (above), which the port cannot change. Default `HY_VDD_SETTLE_US` = 0, so the wake order is never earlier than
   v2.05's; the owner may set a value from the regulator datasheet (Q3).
4. HW-06: on leaving DIODE 15 V the port writes PF6 low first, then PE15 high (v2.05: PE15 high at 0x0800FD6E about 3
   instructions before PF6 low at 0x0800FD76). PF6 is high only in mode 11 with 0x200080B3 = 1, entered by PE15 low then
   PF6 high (as v2.05, 0x0800FD48, 0x0800FD50).
5. PD1 keeps the v2.05 order (left high until the analog step) unless the owner approves releasing it before PE9 (Q4);
   releasing it earlier changes the power order compared by the safety monitor.
6. HW-07: all LCD waits are bounded (0x8000 polls); on a timeout `lcd_init` returns and the meter runs without a
   display instead of hanging with the LCD enabled (v2.05 hangs, 0x0801B4A6).

### 4.4 MCU-driven analog-side outputs

v2.05 writes these pins only through `FUN_0800FBE8` (mode, range) and its parts `FUN_0800FE00` (PD1 high),
`FUN_0800FC60` (PD0, PF4, PF5, PC11, PD7), `FUN_0800FD30` (PE15, PF6), `FUN_0800FDD0` (PA12), `FUN_0800FD80` (PA11),
`FUN_0800FDB0` (PH2), `FUN_0800FE14` (PE12), `FUN_0800FE74` (PE5), plus board init, the power-on window (pins as mode 0
without `FUN_0800FC60`) and `power_down_peripherals`. Steady-state levels per mode:

| Mode | PD0 | PC11 | PF4 | PF5 | PE15 | PF6 | PA12 | PH2 | PE12 | PE5 | PD7 | PA11 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0 LowZ | L | H | H | L | H | L | H | L | L | H | H | H |
| 1 DCV, 3 DCmV, 10 BEEP, 11 DIODE 3 V, 12 CAP | H | H | H | H | H | L | H | L | L | H | H | H |
| 2 ACV, filter off (also AC+DC) | L | H | H | L | H | L | H | L | L | H | L | H |
| 2 ACV, filter on | L | H | L | H | H | L | H | L | L | H | L | H |
| 4 ACmV, filter off / on | L | H | H / L | L / H | L | L | H | L | L | H | H | H |
| 5 TEMP | H | H | H | H | H | L | H | H | L | H | H | H |
| 6 FREQ, 7 PULSE, 8 DUTY | H | H | H | H | H | L | L | L | L | H | H | H |
| 9 OHM | H | L | H | H | H | L | H | L | L | H | H | H |
| 11 DIODE 15 V (only `FUN_080159C8` -> `FUN_0800FD30`) | H | H | H | H | L | H | H | L | L | H | H | H |
| 13 uVA, 14 mVA, 15 VA | L | H | H | L | H | L | H | L | H | H if 0x200080C7 = 0 else L | H | H (13) / L (14, 15) |
| 16, 18, 20 AC current | L | H | H | L | H | L | H | L | H | H at range 0 else L | H | H |
| 17, 19, 21 DC current | H | H | H | H | H | L | H | L | H | H at range 0 else L | H | H |
| 22, 23, 24 DC VA | H | H | H | H | H | L | H | L | H | H if 0x200080C7 = 0 else L | H | H |

PD1 is high in every mode. Never produced by v2.05 in steady state: PF6 high outside DIODE 15 V (the boost would drive
about 15..17 V, derived from the RT9271 feedback divider and UNPROVEN, through R39/R82 onto the input node shared by
OHM/BEEP/DIODE/CAP); PF6 high with PE15 high (except the 3-instruction exit transient); PF4 = PF5 = L (boot transient
only); PE12 high in modes 0..12; PE5 low in modes 0..12; PH2 high outside mode 5; PC11 low outside mode 9; PA12 low
outside modes 6..8 while running; PD1 low while running.

Port mechanism: BRD implements the drivers as one table `brd_fe_table` indexed by (mode, filter flag 0x200080B9, DIODE
flag 0x200080B3, range == 0, 0x200080C7) giving the 12 levels; `brd_fe_apply(mode, range)` (= `fn_0800FBE8`) writes them
in the v2.05 order (FE00, FC60, clear 0x200080B3, FD30, FDD0, FD80, FDB0, FE14, FE74). The build check compares
`brd_fe_table` with `firmware/tools/fe_levels.txt`, transcribed from the v2.05 drivers. The order against the HY3131 is
kept: HY3131 first, then pins (`meter_apply_mode_range` 0x0800D55C before 0x0800D594; burden alternation 0x08006782
before 0x08006792); in the power-on window pins first, then the HY3131 (0x0800EA40..0x0800EA8A).

### 4.5 Buzzer, backlight

PE7 (buzzer) and PE8 (backlight) are plain GPIO levels in v2.05 (no timer output). BZB keeps every writer and timing
(TIM3 countdown 0x20007FB4, repeat count 0x2000807A, enable 0x20008078; `pe7_on_with_timeout` 0x0800EED0 not gated by
the enable, kept for continuity and the jack / high-voltage warnings, while the diode, auto-hold, auto power-off warning and
power-off beeps follow the enable since OF-63; `pe7_on_blocking_100_ticks` 0x08024F06). v2.05 clears PE7 in `power_down_peripherals` (0x0801C58C) while
the TIM2 and TIM3 handlers still run until 0x0801C92E; they can raise PE7 again (TIM3 repeat 0x080247D4, TIM2
jack-warning beep 0x08024690..0x0802469E; UNPROVEN whether reachable at that moment); the port stops both interrupts and
clears the buzzer state first (HW-08).

### 4.6 Flash and option-byte safety

EMAP 9 and section 9.3: PELOCK at reset; NVM holds the only PEKEY values and EEPROM base; keys are written only when
PELOCK reads 1 (as v2.05, 0x0801FA02), once per unlock, because a key write while unlocked or a third write gives a bus
error (RM0038 FLASH_PECR bit 0); no instruction may address PRGKEYR, OPTKEYR, WRPR, OBR or the option bytes; no data
EEPROM erase or fast-write bit is ever set.

### 4.7 Fault-safe state

`sys_fault_safe` (HardFault, MemManage, BusFault, UsageFault and every unused IRQ vector; it never returns): `cpsid i`;
MSP = 0x20001240 (the stack may be the cause of the fault); buzzer state
cleared and PE7 low; PF6 low then PE15 high (boost off); PF0..PF2 analog; PB7 input; USART2 off and PF15 low; LCD
blank and off (bounded waits); then the STOP sequence of 3.6 (HW-02 order, PE9 low, analog pins, EXTI wake lines);
after a wake (key or dial edge) a system reset through SCB_AIRCR SYSRESETREQ, so the bootloader runs and the update
path stays reachable. v2.05 hangs in `b .` with the outputs as they were (0x0802427E.., 0x08029298..) and PE9 high; it
has no dial-OFF handling (`analysis/rotary.md` 4), so whether removing power by the dial stops a hung v2.05 is UNPROVEN.
A fault that recurs at every start therefore costs one STOP per key press, not a reset loop (NF-14).

---

## 5. RAM layout and ownership

### 5.1 Layout

| Range | Section | Content |
|---|---|---|
| 0x20000000..0x2000023D | `.data_v205` | the v2.05 initialised variables, 574 bytes, initial values = `analysis/decompile/ram_init.txt` (range counts at 0x20000000, CSV strings, counter preset 0x2000001C = 0x0000E000, errno 0x20000228, logging interval 0x2000022C, APO 0x20000230, contrast 0x20000237, ...) |
| 0x2000023E..0x2000123F | `.stack` (NOLOAD) | main stack, 4098 bytes, initial SP 0x20001240 (as v2.05; v2.05 static worst-case estimate about 1820 bytes with nested ISR frames, UNPROVEN, deepest path through `calbin_load`, frame 0x4B0 bytes at 0x0801CF08) |
| 0x20001240..0x200080FB | `.bss_v205` (zeroed) | every v2.05 zero-initialised variable and buffer at its v2.05 address (log/cal.bin buffer 0x20001240, FatFs objects 0x20006830 and 0x20006A60, HY3131 mirror 0x200077D0, LCD shadow 0x20007790, BLE frame 0x20007AE0, calibration words 0x20007E00.., meter_mode 0x2000803C, ...) |
| 0x20008100..0x200097FF | `.bss_port` (zeroed) | port-only state, each item owned by one module (6): `cal_cache` 0x500 bytes (EEPROM 0x000..0x4FF image), NVM token and refusal counter, smoothing states (OF-28), BLE second frame buffer and queue (OF-10), `mtmp_temp_result` (OF-19), `rtc_blink_request` (NF-11), state-machine contexts (IMP-06), AR state (IMP-01) |
| 0x20009800..0x2000BFFF | unused | not referenced |

Reason for keeping every v2.05 address: the owner's rule that the RAM locations of calibration data, serial number and
options are preserved; the specifications cite these addresses; differential debugging can compare RAM directly. Every
v2.05 RAM variable gets a symbol in `firmware/src/inc/ram_v205.inc`, generated once by `firmware/tools/gen_ram_symbols.py`
from the literal pools of the listing (660 distinct base addresses) and the access widths; the name is the verified name
(`analysis/verified_names.txt`, e.g. `meter_mode` = 0x2000803C) or `v_XXXXXXXX`.

### 5.2 Ownership

Appendix B lists every v2.05 RAM base address under the module whose functions load it most often. The owner module
documents the symbol (meaning, width, writers). Other modules read it, and write it where the v2.05 function they port
writes it (the port keeps v2.05's data flow); 226 of the 660 addresses are referenced by functions of more than one
worker. Fixed owners that override the Appendix B count: meter_mode 0x2000803C, meter_range 0x2000803D (MODE);
calibration words 0x20007E00..0x20007E58 and request/state flags 0x20008088..0x2000808F, 0x20008095, cal mode
0x2000808A (CAL); user zero 0x20007E0C (MVA; read by MAC and MDC); PF8 flag 0x20007FDF (BRD, written by
`sample_pf8_at_boot`); APO state 0x200080E6..0x200080E9 (PWR); settings bytes (SET); HY3131 mirror 0x200077D0 (HY);
LCD shadow 0x20007790 (LCD); BLE buffers 0x20007AE0, 0x20007B80 (BLE).

### 5.3 Stack

4098 bytes as v2.05. `sys_reset` writes the pattern 0x5354434B to the four words 0x20000240..0x2000024F (the first
word-aligned addresses of the stack region). The emulator tests report the deepest stack use per scenario (write watch
on the region); a test fails above 3072 bytes or when the canary changes. No dynamic allocation exists.

---

## 6. Modules

Every v2.05 function is assigned to exactly one module (Appendix A: 800 functions, 119 222 bytes of code) and is
carried over as a port routine with the same behaviour, or as a documented deviation (10), or replaced by equivalent
code with proof (6.27). Nothing is dropped silently.

Conventions for all modules:
- Calling convention: AAPCS (r0..r3 arguments and scratch, r0/r0:r1 result, r4..r11 preserved, r12 scratch, lr
  return, 8-byte stack alignment at public calls). A routine that replaces a v2.05 function called from another module
  keeps the v2.05 register signature of `analysis/decompile/params.txt` (Appendix C.1). The v2.05 functions clobber at
  most r0..r3 and r12 (`analysis/decompile/regeffects.txt`), so callers depend on nothing else.
- Canonical global symbol of a cross-module routine: its verified name (`analysis/verified_names.txt`) or
  `fn_XXXXXXXX` with the v2.05 address in upper-case hex; new port routines `<mod>_<name>` (Appendix C.2). Aliases with
  `.set` are allowed.
- Exception (justified): the RT helpers keep the v2.05 helper conventions (float in r0/r1, double in r0:r1 and r2:r3,
  result r0 or r0:r1, compare results in the CPSR flags only for `fn_0801BD08`, `fn_08020390`, `fn_0802035C`,
  `fn_08023F2C`), because their callers are ported line by line and flag-returning compares have no AAPCS form.
- Context: "main" = main loop or start-up only; "ISR-safe" = may be called from TIM2/TIM3/USART2 handlers.

### 6.1 SYS: start-up, clocks, NVIC, timers, main loop (W1)

- Replaces: Reset_Handler, reset_preinit, SetSysClock, c_startup, cmain, data_init, zero_init, lz77_init, `main`
  0x08024B40, `FUN_0801BE76`, `FUN_0801BF1A`, RCC/PWR/NVIC/TIM/DBGMCU helpers, IRQ28 0x0802428C, SysTick handler, the
  default handlers (Appendix A SYS; the FLASH driver functions listed there move to NVM).
- New routines: Appendix C.2 (`sys_reset`, `sys_main`, `sys_system_init`, `sys_clock_select`, `sys_tim2_isr`,
  `sys_fault_safe`, `sys_crit_enter`, `sys_crit_exit`).
- RAM: tick counters and flags 0x20007F00..0x20007F08, 0x200080D0..0x200080D3, 0x2000802C, 0x20008031 (Appendix B SYS).
- Context: `sys_tim2_isr` calls only ISR-safe routines: `pe7_on_with_timeout` (BZB), `fn_080153AC` (UI, 3.4),
  `ble_tx_start_frame` (BLE), and sets `rtc_blink_request` (NF-11); in production it also increments `ar_freq_tmo_count`
  (AR) at the FREQ / PULSE / DUTY no-signal timeout (OF-32 decision, 12.2).
- Depends on: NVM (reset lock, error clear), BRD, PWR, and every module called from the loop.
- Deviations: NF-02, NF-03, NF-11, NF-12, NF-13, NF-14, NF-18, IMP-02 (window during measuring), IMP-06 (loop modes).

### 6.2 BRD: board, GPIO, ADC, front-end pins, EXTI (W1)

- Replaces: `gpio_init`, `gpio_set_alternate_function`, `board_gpio_init` 0x0801C056, `gpio_init_pg_inputs`
  0x0801C2C6, `gpio_init_pe10_pe11_inputs`, `gpio_init_analog`, `sample_pf8_at_boot` 0x0800C28C, `power_down_peripherals`
  0x0801C584, `FUN_0801C522`, `FUN_0801CA22`, `FUN_0801C61C`, `FUN_0801C8EC`, the front-end drivers `FUN_0800FBE8`..
  `FUN_0800FE74`, busy delay `FUN_0800ECF6`, ADC drivers (`FUN_08013DD4`, `adc_select_channel_4_or_5`,
  `adc_ch4_average_10`, `FUN_0801349C`, `FUN_0801C97E`), `FUN_080207CC` (STOP entry), the EXTI, IRQ3 and IRQ18 handlers.
- New routines: `brd_gpio_init`, `brd_fe_apply`, `brd_exti_isr` (Appendix C.2). SD calls `brd_gpio_init` for its pins.
- RAM: 0x20008086, 0x20007FDF.
- Context: `FUN_0800ECF6` ISR-safe (pure loop); everything else main.
- Deviations: OF-06, OF-13, NF-01, NF-05, HW-01 (pin policy for PB7), HW-02, HW-03, HW-04, HW-06.

### 6.3 PWR: APO, battery, power-off (W1)

- Replaces: `enter_stop_and_reinit` 0x08024ECA, `FUN_0800ED26` (APO reload), battery processing `adc_ch5_process`
  0x080134DA, `FUN_080135B0`, `FUN_0801368A`, `FUN_08013728`; the APO block of `main` (0x08024CAE..0x08024D1A) becomes
  `pwr_apo_second`, called at the same place in loop step 9.
- RAM: APO 0x20000230, 0x200080E6..0x200080E9, other Appendix B PWR addresses.
- Deviations: NF-06, HW-08 (with BZB).
- Production image only (not in the like-v2.05 build): `src/pwr/backlight.s`, the
  backlight auto-off timer of IMP-07 (FEATURES.md 2.9): `pwr_bl_second` (called by `sys_main` in loop step 9 after
  `pwr_apo_second`), `pwr_bl_restart` (called by KEY at every tick with a key down, by DIAL at a latched position change,
  by `fn_08014AE6` for an injected key, by the MODE long press that switches the backlight on, and by the SET edit),
  `pwr_bl_reset` and `pwr_bl_restore` (called by `set_state_reset`; `pwr_bl_restore` switches the backlight on again when
  0x017 bit 7, written by `pwr_bl_remember` after each MODE long press, says it was on). RAM `pwr_bl_setting` (u8) and `pwr_bl_count` (u16) in `.bss_port`.

### 6.4 BZB: buzzer, backlight, TIM3 handler (W1)

- Replaces: `FUN_0800EE50` (accept beep), `FUN_0800EE5E` (long-press beep), `FUN_0800EE6C` (refusal), `FUN_0800EEA8`,
  `pe7_on_with_timeout` 0x0800EED0, `pe7_on_blocking_100_ticks` 0x08024F06, IRQ29 0x08024722 (`bzb_tim3_isr`, which also
  decrements the power-on window counter 0x2000022E as v2.05 does).
- New routines: `bzb_tim3_isr`, `bzb_silence` (clears the buzzer state in a critical section and sets PE7 low; HW-08).
- RAM: 0x20007FB4..0x20007FB6, 0x20008079, 0x2000807A, 0x200080CF; backlight state 0x2000807B (written by KEY in v2.05).
- Context: `pe7_on_with_timeout`, `bzb_tim3_isr` ISR-safe; the beep routines main.
- Deviations: HW-08, IMP-06 (`pe7_on_blocking_100_ticks` as a state machine in production mode).

### 6.5 RT: run-time numerics (W2)

- Replaces: the 38 helper entries of Appendix A RT: i2f 0x08012F60, ui2f 0x08012F74/0x08012F78, fdiv 0x08012F94, fmul
  0x08013090, f2d 0x08013168, dadd 0x080131B8/0x080131CC, d2iz 0x080132A0/0x080132CC, fadd 0x080132EC/0x080132FC, f2iz
  0x08013370, fsub 0x080133B4/0x080133C4, i2d 0x08013EC4, ui2d 0x08013ED8/0x08013EDC, dsqrt 0x08013EF4 (tail
  0x08020380), ldivmod 0x08013FE4, uldivmod 0x08014028 (return-only tail 0x0802038C), l2f 0x08014118 (with 0x08014134, 0x08014140,
  0x08014158, 0x0801415A), ddiv 0x0801B874, d2f 0x0801BACC, dmul 0x0801BB64, log10 0x0801BB5C/0x080204C4, dsub
  0x0801FB9C/0x0801FBB0, f2uiz 0x0801BD24, compares 0x0801BD08, 0x08020390, 0x0802035C, 0x08023F2C, subnormal
  normaliser 0x08023EE8, errno 0x08023EDC, strlen 0x08023CA0.
- Rule: bit-exact with v2.05 for every input, including the non-IEEE cases observed by executing the original helpers
  during the inventory (to be re-verified by W2's tests, 9.4): fdiv returns +-inf for any quotient whose biased exponent
  would be >= 254 (0x08012FEA); fadd/fsub and dadd/dsub differ from IEEE when exactly one operand is subnormal; ddiv
  differs for subnormal quotients; log10 is not always the correctly rounded value; NaN results have helper-specific
  bit patterns; dsqrt of a negative writes 0x21 to errno 0x20000228, log10(0) writes 0x22; uldivmod and ldivmod by 0
  return the dividend with remainder 0. Because the subnormal behaviour is not fully characterised, RT re-expresses
  each helper's algorithm instruction by instruction from the listing, fully commented.
- Context: ISR-safe (no state except errno). Depends on nothing.

### 6.6 FUNC: smoothing, HOLD, MIN/MAX/AVG, REL, PEAK, post-processing (W2)

- Replaces: `FUN_0800B754` (thresholded history), `FUN_0800B888` (mean of 3), `FUN_08008344` (moving average),
  `FUN_0800DCFC` (per-reading post-processing: auto-range call, HV flags, HOLD, MIN/MAX, REL), `FUN_0800E278`,
  `FUN_0800E758`, `FUN_0801584C`, `FUN_080158D4`, `FUN_08015974`, `FUN_0801A028` and the rest of Appendix A FUNC.
- OF-28: `func_smooth_hist` and `func_smooth_avg` take a state pointer (Appendix C.2); `fn_0800B754` and `fn_08008344`
  keep their v2.05 signatures and use the v2.05 state for callers that share it with nobody; the callers named in
  OF-28 pass their own state block in `.bss_port` (AC+DC DC phase, AC+DC combined, VA voltage, VA current, burden
  current, burden voltage).
- RAM: smoothing histories 0x200070A8, 0x20007238, 0x20007CD8, 0x20007DF8, 0x20008084, 0x20008085 (OF-28 evidence),
  minmax_state 0x2000804E, hold_active 0x2000804F, hold_stage2 0x20008050, rel_active 0x20008058, other Appendix B FUNC
  addresses.
- Deviations: OF-28.

### 6.7 LCD: LCD driver, font, low-level drawing (W3)

- Replaces: `lcd_init` 0x0801B450, `lcd_commit_shadow` 0x0801B304, `lcd_commit_shadow_partial` 0x0801B396,
  `lcd_draw_glyph` 0x0801A950 (font 0x0801AFFC, tables 0x08029184 digits, 0x080290B8 A..Z, 0x080290D4 a..z, strings
  0x080291A8..0x08029270), `lcd_draw_5char`, value drawers 0x08017100, 0x08017F28, bargraph 0x08018B14..0x08019408,
  annunciator setters (0x080172A8.., 0x08019B48..0x0801A370, 0x0801A3A4, 0x0801A440, 0x0801A6D8, 0x0801A760),
  number-to-digit 0x0801B090, 0x0801B130, `FUN_0801B77A` (contrast to FCR), LCD StdPeriph helpers (`lcd_map.md` 1..4).
- RAM: shadow 0x20007790 (v2.05 commits words 0..7 to LCD_RAM 0x40002414..0x40002430), 0x20007DB0..0x20007DB8,
  0x20008041 (bar count), 0x2000804D.
- Context: drawing into the shadow and committing are main-only (NF-11).
- Deviations: OF-05 (`FUN_0801B77A`: no FCR write for contrast values outside 10..17), HW-07, NF-11, IMP-06 (commit without UDR
  busy-wait in production mode).

### 6.8 UI: display composition and messages (W3)

- Replaces: `FUN_08016D34` (refresh dispatcher), `FUN_08016E08` (main value), MEM-view drawing `FUN_080170AC`,
  `FUN_080153AC`, refresh helpers, every message screen (SdCAL, SdSAv, SdSEt, SAvEd, -Err-, CAL1, CAL, LoBAt, SdEnd,
  SdExx, OFL, OPEN, LEAD, -----, -oFF-, calibration step texts, V-205 splash `FUN_0801A854`), `FUN_0800D664`,
  `FUN_0800D6E0`, `FUN_0800E848` (Appendix A UI).
- RAM: Appendix B UI addresses (among them 0x20008091..0x20008094, calibration-step display flags, and 0x20008076, jack
  warning flag read by 0x080199B4).
- Deviations: OF-19 (carried by MTMP: UI keeps drawing 0x20007D64, which MTMP now converts once per mean and also stores in `mtmp_temp_result`), OF-30 (LowZ: dashes on the main digits, never a numeric 0,
  until the AC/DC decision), OF-32 (BEEP and FREQ blank until the first valid value), OF-33 (CAP blank across the
  timeout range jump), IMP-01 display rules (ARS 5.2 P5).

### 6.9 KEY: keys (W4)

- Replaces: `sample_pg8_15` 0x08016BCA, `process_pg8_15_press_release` 0x0801688C, `handle_pg8_15_short_press`
  0x08014C3C, `handle_pg8_15_long_press` 0x0801622C, `FUN_0801680C`, `FUN_08014AE6` (remote key mapping), `FUN_08016A64`
  (auto-repeat), `FUN_08016B7C` (one-hot check, also used by DIAL), `FUN_08016B4C`, `FUN_08016BB8` (`keys_setup.md` 1, 2).
- RAM: 0x20008067..0x2000806D, 0x20008072, 0x20008073, 0x200080ED..0x200080F3, 0x20007FAA, 0x20007FB8, 0x20008044.
- Deviations: OF-17 (PEAK and the 1 kHz filter refused together, either order: refusal beep, nothing changes), OF-07
  key-side refusal (7.2), NF-07 switch, IMP-07 (production: key activity restarts the backlight auto-off countdown).

### 6.10 DIAL: dial and jack sense (W4)

- Replaces: `sample_pg0_7` 0x08014A14, `debounce_pg0_7_onehot` 0x0801496E, `FUN_08014948`, `FUN_08014954`, position
  handler `FUN_080143EE`, `sense_pe10_pe11` 0x0801417C (`rotary.md` 1, 2, 5).
- RAM: 0x20008064..0x20008066, 0x200080EA..0x200080EC, 0x2000023B, 0x2000023C, 0x20008075.

### 6.11 MODE: mode and range state machine (W4)

- Replaces: `meter_apply_mode_range` 0x0800D2D0, `load_full_scale` 0x0800D5F4 (table 0x08025A3C),
  `decimal_position_for_mode_range` 0x0800D920, `cycle_mode_on_bit0` 0x08014500, `FUN_08014708`, `FUN_0801472C` (AC+DC),
  `FUN_08014796` (RANGE key), `FUN_08006774`, `FUN_080080C8` (burden-voltage re-apply), `FUN_0800D80C`, `FUN_0800D81E`,
  `FUN_0800DB48`, `FUN_08019DA2` (auto-range predicate) and the rest of Appendix A MODE except the AR functions.
- RAM: meter_mode 0x2000803C, meter_range 0x2000803D, range_count 0x20000000, settle count 0x20000238, full scale
  0x20007D60, 0x20008042, 0x2000804A, 0x2000804B, 0x20008050, 0x2000805A..0x2000805C, 0x20008074, 0x200080F8.
- Calls `ar_apply` at every apply and `cal_cache` loaders instead of EEPROM reads (OPT-08).
- Deviations: OF-20 (through AR).

### 6.12 AR: auto-range (W4)

A module with a narrow interface, so that the faster auto-ranging (IMP-01, ARS section 5) lives inside it.
- Replaces: `autorange_step` 0x0800DE24, `FUN_0800E2A0` (OHM direction guard), `frequency_select_range` 0x0800AC1C.
- Interface (main context; Appendix C.2):
  - `ar_apply(r0 = mode, r1 = range)`: called by MODE inside `meter_apply_mode_range` where v2.05 sets the settle count
    0x20000238; resets AR state, clears the OL latch 0x200080F8 (OF-20).
  - `autorange_step()` (alias `ar_step`): called where v2.05 calls it (`FUN_0800DCFC` after a new mean, 0x2000805D).
    Inputs (v2.05 RAM): reading 0x20007D64, full scale 0x20007D60, meter_mode, meter_range, range_manual 0x20008042,
    range_count 0x20000000, settle count 0x20000238, cal mode 0x2000808A. Outputs: new meter_range with request 0x2000804B
    = 1 (applied by loop step 13), overload flag 0x20008046, OL latch 0x200080F8, settle count 0x20000238 (while non-zero
    `FUN_08016E08` blanks the main digits with five spaces, string 0x080291B0: the display blanking state).
  - `ar_sample(r0 = calibrated per-sample value, r1 = raw AD1 code)` (production mode only, IMP-01): per-sample
    over/under detection with K = 2 confirmation and saturation test (ARS 5.2 P2), called by MDC/MAC/MRES after each
    conversion; it may set the same outputs earlier than `autorange_step` and chooses the target range by ARS 5.2 P3
    (same final range as v2.05).
  - `frequency_select_range` (alias `ar_freq_select`; v2.05 0x0800AC1C, same signature: 64-bit frequency against
    decade thresholds) for MFRQ.
- Settle profiles (ARS 5.2 P4): `AR_PROFILE` = CP (conservative, default) or TP (target); TP is enabled per mode family
  only after the hardware step tests H1..H8 of ARS section 12 pass (build switch per family in `config.inc`, default
  off). The like-v2.05 build uses the v2.05 algorithm only.
- Deviations: OF-20, OF-25 (with MAC), IMP-01.

### 6.13 HY: HY3131 driver (W5)

- Replaces: `hy3131_write_regs` 0x0800C03C (internal in the port), `hy3131_read_regs_to_rxbuf` 0x0800C0C0,
  `hy3131_spi_read_byte`, `hy3131_spi_write_byte`, `hy3131_spi_clock_pulse`, `hy3131_poll` 0x08006124,
  `hy3131_service_irq` 0x0800614E, `ad1_ready_dispatch` 0x080061E4, `hy3131_load_config_regs` 0x0800B994,
  `hy3131_set_irq_enable` 0x0800BEAC, `hy3131_counter_restart` 0x0800BF8C, `FUN_0800B974`; the two register writes of
  the peak restart in `FUN_0800A7FC` (as `hy_peak_restart`).
- Mechanism: 4.1.
- Read sets (production mode, IMP-06): v2.05 reads 0x34 bytes from register 0 on every event (0x08006158), about
  3.26 ms at its bit timing (7.8 us per bit, ARS 5.2 P1, re-measured 2026-11-01), too long for the 640 sps rows (BEEP, ACV r3, DCmV r1, LowZ AC; period
  1.5625 ms). The port reads per event only the registers consumed for that event, as auto-increment bursts with the
  same read command format: INTF/INTE 0x1E..0x1F on every event (v2.05 computes the event mask rx[0x1E] & rx[0x1F] in
  `hy3131_service_irq` 0x0800614E; reading INTF has the side effect of clearing it, DS p19, as in v2.05's burst), AD1
  0x00..0x02 on AD1F, the counter block 0x14..0x1D on CTF (0x15..0x1D are parsed by `counter_parse_and_restart`
  0x0800AB48; 0x14 CTSTA has no reader but reading it clears CTBOV, DS p36, so it is read with the block), the peak block on the peak
  event (registers read by `FUN_0800A7FC`), 0x20 and 0x29 on every event (`hy3131_service_irq` copies rx[0x20] to
  0x2000807D at 0x08006190 and tests rx[0x29] bit 2 at 0x08006196..0x080061C4 on every event), and every other mirror byte that a consumer of that event reads (W5 tabulates the consumers per
  event from the listing; `hy3131_modes_misc.md` 8 lists the register-mirror readers). The RMS block is not read (OF-16).
  Bit timing stays v2.05's. Baseline mode keeps the full burst.
- Counter restart (production mode, IMP-06): `hy3131_counter_restart` sends phase 1 (R20 with ENCTR cleared) and arms
  `hy_restart_ticks` = 19, which `bzb_tim3_isr` counts down; `hy_counter_restart_step` (called by `hy3131_poll` every
  pass) sends phases 2 and 3 (CTA preset, read-back, R20 | 0x02) in the first pass after the count reached 0. The wait
  replaces v2.05's delay(10000) at 0x0800BFCE (17.1 ms, ARS 5.2 P6): armed at any phase of the 0.99564 ms TIM3 period,
  19 ticks last 17.92..18.92 ms, never less than v2.05. No event is serviced while the restart is pending, as v2.05
  services none during its blocking delay (4.1 item 8). Baseline mode keeps the blocking delay.
- RAM: mirror 0x200077D0 (52 bytes), 0x20007DC4, 0x20007DCC, 0x2000807D..0x2000807F, 0x200080BD.
- Context: main only.
- Deviations: OF-16 (the RMS event is serviced with the INTF clear only; no square root, average or hooks; their results
  have no reader, OF-16 evidence), NF-15, HW-05, IMP-06.

### 6.14 MDC: AD1 decode, averaging, DC chains, calibration arithmetic (W5)

- Replaces: AD1 decode `FUN_080062F8`, `ad1_accumulate_average` 0x08006342, `FUN_08006418`, `FUN_080064D6`,
  `FUN_08007714`, `FUN_080077F0`, `FUN_08007FA8`, `FUN_08008138` (DC currents with user zero), `cal_subtract_offset_clamp`
  0x0800F368, `cal_divide_by_gain` 0x0800F3B8, `FUN_0800F2FC`, `FUN_0800EEF0`, `FUN_0800F648`.
- RAM: sum 0x20007DD0, mean 0x20007DD4, count 0x20008080, 0x20007DC8, va_channel 0x200080C4; port: `mdc_ps_done`,
  `mdc_first_mean`, `mdc_acdc_dc_state`.
- Deviations: OF-14 (sign-extend bit 23), OF-15 (round half away from zero in `cal_divide_by_gain`: +0.5 for positive
  and -0.5 for negative quotients before the truncating d2iz, the helper sequence otherwise unchanged), OF-26 (1/10
  scale of the 1 kHz filter on every path, with MAC), OF-28 (`mdc_dc_state`: the AC+DC DC phase, the DC VA voltage and
  current and the burden-display voltage and current each smooth through a state block of their own, FUNC `func_st_*`),
  IMP-01 (`ar_sample` calls through `mdc_sample_precheck`, which `ad1_ready_dispatch` calls before `mac_sample_precheck`
  of MAC; the first displayed value after a configuration change is the mean of 4 clean samples, ARS 5.2 P5:
  `fn_0800B974` arms `mdc_first_mean`, `ad1_accumulate_average` publishes the mean at the 4th sample of a block when
  the v2.05 settle count 0x20000238 is 0 and goes on to the v2.05 N), IMP-04 (BEEP displays a block of 64 samples,
  ARS 8.2).

### 6.15 MRES: ohm, continuity, diode, capacitance, LowZ (W5)

- Replaces: Appendix A MRES (LowZ select `FUN_08006540`, `FUN_08006558`, `FUN_0800662C`; OHM/BEEP/DIODE chains
  `FUN_080078B8`, `FUN_080078D8`, `FUN_08007940`, `FUN_080079C4`, `FUN_08007D1E`, `FUN_08007E84`; CAP `FUN_0800B33C`,
  `FUN_0800B540`, `FUN_0800EC28`; DIODE range toggle `FUN_080159C8`; `hy3131_modes_misc.md` 5.5, 6).
- RAM: 0x20007CC0..0x20007CD4, 0x20007FC4..0x20007FC8, 0x2000807C, 0x20008098, 0x200080A3, 0x200080A4, 0x200080B4,
  0x200080B5, 0x20000239, 0x2000023A.
- Deviations: OF-01 (`FUN_08007D1E`: when the table search fails, the routine returns with the uncorrected value
  instead of indexing with a stale register), OF-23, OF-30 (LowZ detector `FUN_08006558`: the moment a mean exceeds the
  LowZ threshold, the HV symbol is lit where v2.05 would light it for that value and the main digits show dashes until
  the AC/DC decision; the AC/DC auto-selection logic is otherwise kept), OF-32 (BEEP), OF-33 (`FUN_0800B540` marks the
  value invalid across the jump), IMP-01 (`ar_sample` calls), IMP-03 (faster resistance readings, ARS 7), IMP-04 (BEEP decision
  on every conversion, DIODE tone on K = 2 confirmed samples, ARS 8.2), IMP-05 (continuity codes 4..15, ARS 9).

### 6.16 MFRQ: frequency, duty, pulse, counter (W5)

- Replaces: `FUN_0800AA00`, `counter_parse_and_restart` 0x0800AB48, `counter_compute_frequency` 0x0800B610 (reference
  0x20007E18, default 49 152 050), `FUN_0800B67C` (period), `FUN_0800B6D4` (duty), `FUN_0800B6F0`, `FUN_0800AEE8`,
  `FUN_0800ED64` (counter preset 0x2000001C), `FUN_08012F28`.
- RAM: 0x20007C40, 0x20007C48, 0x20007E18, 0x20007E34..0x20007E48, 0x20008045, 0x2000809B, preset 0x2000001C.
- Deviations: OF-02 (defined values on every path; case 9 uses the measured frequency), OF-18 (pulse width
  W = CTC*10^8 / (ref*CTB) in 0.1 us, rounded), OF-32 (FREQ: value invalid until the first counter result).

### 6.17 MTMP: temperature (W5)

- Replaces: `FUN_08007840` (TEMP handler), `adc_ch4_process` 0x0801385A (thermistor, cold junction, board offset,
  cal-mode write of 0x2E0), `FUN_08013B76` (degC to degF), `FUN_08013CF8` (cold junction), `FUN_08018AD8`, the thermistor
  table (0x08013AAC region).
- RAM: 0x20007E7C..0x20007E88, 0x20007FCE..0x20007FD6, 0x20008096, 0x20008097, 0x200080AC..0x200080B0, 0x20007BA8;
  port: `mtmp_temp_result`.
- Deviations: OF-19, OF-21, OF-22, OF-24 (below the conversion range the existing cold-junction fault path is taken:
  CJ = 0 and fault flags 0x200080AF, 0x200080AC set, as for raw >= 3673).

### 6.18 MAC: AC chains, RMS, AC+DC, filter, peak, AC current (W6)

- Replaces: Appendix A MAC (27 functions: `FUN_0800664A`, `FUN_080067D6` (AC currents with user zero), `FUN_080069B4`,
  `FUN_08006AEC`, RMS handler `FUN_08008208`, peak `FUN_0800A7FC` (its register writes through `hy_peak_restart`), AC+DC
  `FUN_0800A6A8`, dBm `FUN_0800A74C`, corrections `FUN_08006D40`, `FUN_080070CC`, `FUN_0800742C`, `FUN_080075FA`,
  `FUN_080124F4`, `FUN_080129EE`; `hy3131_modes_ac_current.md` 4..7).
- RAM: Appendix B MAC (0x20007C5C..0x20007CBC, reading 0x20007D64, 0x20007DD4..0x20007DF4, 0x20007E08, AC words
  0x20007E5C.., 0x20007F0C..0x20007F94, flags 0x200080B7..0x200080BE, ...).
- Deviations: OF-04 (`FUN_0800A74C`: defined multiplier 1.0 for mode byte > 3), OF-16, OF-25 (64-bit sum of squares),
  OF-26, OF-28 (through FUNC), IMP-01 (`ar_sample` calls).

### 6.19 MVA: VA modes, burden correction, user current zero (W6)

- Replaces: `FUN_080084E0`, `FUN_08008B8C`, `FUN_080087F8`, burden correction `FUN_08008ED0` (table fetch `FUN_08009364`,
  33 tables 0x080260E4..0x080284C0), `FUN_0800A560`, `FUN_0800D8C2`, `FUN_0801485A`, `current_extra_load` 0x08011448,
  `current_extra_store` 0x080114BC, `current_extra_erase_all` 0x0801150E, `current_extra_offset` 0x0801154E.
- New routine: `current_extra_clear(r0 = mode)` (Appendix C.2).
- RAM: user zero 0x20007E0C, 0x20007C10..0x20007C28, 0x20007CDC..0x20007D04, 0x20007D7C, 0x20007D80,
  0x20007E24..0x20007E30, 0x20007EAC..0x20007EC4, 0x200080BF..0x200080CC, 0x2000804C.
- Deviations: OF-08 (`current_extra_erase_all` kept as code but no longer called at calibration entry), OF-09, OF-27
  (column index clamped to 6 and row index to the table's last row in `FUN_08009364`), OF-28, OF-29.

### 6.20 CAL: calibration mode, records, cal.bin, power-on window (W7)

- Replaces: Appendix A CAL except the EEPROM byte layer (NVM): capture `FUN_0800EF44`, `FUN_0800F034`, `FUN_0800F0AC`,
  `FUN_0800F470`, `FUN_0800F6C0`, `FUN_0800F7B8`, `FUN_0800F9F0`, `FUN_0800FB1E`..`FUN_0800FBB8`; AC-band calibration
  `FUN_08007532`, `FUN_0800F13C`, `FUN_0800F8E4`, `FUN_080119F4`; refusal/start `FUN_08015728`, `FUN_08015768`,
  `FUN_080157E8`; loaders `load_cal_record_from_eeprom` 0x0801167C, `cal_record_load_va` 0x08011950, `FUN_08011AA4`;
  markers `FUN_080104BC`, `FUN_080104D4`, `FUN_08010F10`, `FUN_08010F28`; serial/date `FUN_08010F4C`, `FUN_08010F74`,
  `FUN_08010F8C`, `FUN_08010FB8`; `calbin_save` 0x0801CD14, `calbin_load` 0x0801CF06; power-on window `FUN_0800EA3A`
  (7.1).
- Calibration cache (OPT-08, ARS 5.2 P6): `cal_cache_load` copies EEPROM 0x000..0x4FF into `cal_cache` at boot and
  wake (in `bootwin_start`, after `set_state_reset` and `lcd_init`, just before the splash); the loaders read the
  cache with the v2.05 formats and validation; NVM updates the cache after every verified byte write. The cache holds exactly the EEPROM content, so readings are identical; v2.05
  reads the EEPROM at every apply (up to 13.8 ms, ARS 5.2 P6).
- RAM: calibration words 0x20007DFC..0x20007E20, 0x20007E4C..0x20007E58, flags 0x20008088..0x2000808F, 0x20008095,
  0x2000809C..0x2000809F, cal mode 0x2000808A, 0x20007C38, 0x20007D5C, date code 0x20007F9A, board offset 0x20007FBE;
  port: `cal_cache`.
- Deviations: OF-07, OF-08, OF-12, NF-07, NF-08, NF-09, NF-10, NF-16 (7.2), IMP-02 (7.1), IMP-06 (cal.bin and window
  as state machines in production mode).

### 6.21 NVM: data-EEPROM layer (W7)

- Replaces: `eeprom_read_byte` 0x0801204C, `eeprom_read_u8` 0x0801203A, `eeprom_read_u16_be` 0x08012000,
  `FUN_08011FD4`, `eeprom_read_u32_be` 0x08011F80, `eeprom_write_u8/u16_be/u32_be` 0x080120D0/0x080120A8/0x08012068,
  `eeprom_write_byte_retry` 0x08012148, `eeprom_program_byte` 0x080120F0, wrappers 0x080104F8/0x08010504,
  `cal_record_base` 0x0801159C, `ac_words_base` 0x080115CC, `cal_record_write` 0x08011B40, `FUN_08011DCE`, `FUN_08011E88`,
  `FUN_08011F38`, and the FLASH driver `FUN_0801F9FC`, `FUN_0801FA1C`, `FUN_0801FA2E`, `FUN_0801FAFA`, `FUN_0801FB00`,
  `FUN_0801FB60`. Not carried over: `FUN_0801FA68`, `FUN_0801FA8E`, `FUN_0801FAA0`, `FUN_0801FAEE` (option bytes, NF-03).
- Public interface (Appendix C.2; EMAP 9.2/9.3 describe the protection):
  - Readers `eeprom_read_u8`, `eeprom_read_u16_be`, `fn_08011FD4`, `eeprom_read_u32_be`: v2.05 signatures; read the
    cache after `cal_cache_load`, the EEPROM before it; offsets > 0x4FF return 0 (v2.05 never passes one).
  - Arming: the calling module calls `nvm_arm(r0 = class key)` immediately before a writer; the key is a per-class
    constant (`NVM_KEY_SETTINGS`, `NVM_KEY_IDENT`, `NVM_KEY_USERZERO`, `NVM_KEY_CAL`, `NVM_KEY_RESTORE` in `config.inc`).
    Writers do not arm themselves, so a stray branch into a writer finds no token.
  - Writers (each one corresponds to v2.05 writers, EMAP 7): `nvm_write_setting` (SETTINGS), `nvm_write_ident`
    (IDENT: serial at 0x003 length 4 from the setup item 8 save, date code at 0x001 length 2 only while 0x2000808B != 0),
    `nvm_write_userzero` (USERZERO), `cal_record_write`, `fn_08011DCE`, `fn_08011E88`, `fn_08011F38`,
    `nvm_marker_write` (CAL), `nvm_restore` (RESTORE).
  - Start-up: `nvm_reset_lock` (PELOCK, from `sys_reset`), `nvm_clear_errors` (FLASH_SR <- 0x1F02, from
    `sys_system_init`).
  - Status in r0: 0 written and verified (or OPT-03 skip), 1 refused (nothing written), 2 programming failed after 10
    attempts; `nvm_restore` returns the `calbin_load` codes 0, 8 (size refused, nothing written), 9 (read-back
    mismatch). v2.05 callers ignore the status except `calbin_load`; the port does the same. Refusals increment
    `nvm_refusals` (port RAM), read by the tests.
- Byte program (internal): key write only if FLASH_PECR PELOCK reads 1, exactly the two PEKEYR words once (v2.05
  0x0801FA02..0x0801FA18; a third or wrong write gives a bus error, RM0038 FLASH_PECR bit 0); clear SR error flags;
  FTDW = 0; `strb`; wait (0x8000 polls); PELOCK = 1 on every exit; read back.
- Context: main only (v2.05 writes EEPROM from the measurement path, which runs in main through `hy3131_poll`).
- Deviations: OF-07, OF-12, NF-09, NF-13, NF-16 (refusals and restore inside NVM), NVM-1, NVM-2 (switch), OPT-03,
  OPT-07.

### 6.22 LOG: logging and MEM view data (W8)

- Replaces: Appendix A LOG (55 functions): in-RAM record slots (60), `FUN_080109EA`/`FUN_08010AF8` logging start/stop,
  `FUN_08010B64`, `log_compose_mode_range` 0x08010516, `log_write_csv_token` 0x0801E82E, header 0x0801E330, rows
  0x0801DBF0, name builders 0x0801D838/0x0801D79C, directory scan 0x0801D640, session 0x0801D126/0x0801D1A8, file time
  0x0801D37C, verify pass 0x0801F6B4.
- Byte for byte as v2.05: file names YYMMDDnn.csv, CSV tokens and header lines, record format, write and verify
  sequence (the harness compares SD commands, blocks and final files).
- RAM: Appendix B LOG.
- Deviations: OF-35 (`FUN_08010908` stores the displayed averaged value 0x20007D64 in every mode instead of the
  per-sample value 0x20007D68; v2.05 already does so in modes 5..9 and 12, 0x0801097A..0x080109A4), IMP-06 (state
  machines).

### 6.23 SD: SDIO driver and FAT file system (W8)

- Replaces: the FatFs-equivalent library 0x08020B84..0x08022942 (f_mount 0x08021B80, f_open 0x08021BCC, f_read
  0x08021D72, f_write 0x08021F60, f_sync 0x08022188, f_close 0x0802224C, f_lseek 0x08022268, f_opendir 0x0802242C,
  f_readdir 0x080224B6, f_stat 0x08022526, f_utime 0x0802256E and internals), disk glue 0x08023F5C..0x08024038 (v2.05 get_fattime
  constant 2006-02-09 22:30:00; the port's get_fattime uses the clock chip, OF-58; 64-bit byte addresses, OF-57; SD errors
  passed on, OF-59; the FatFs R0.10a..R0.10c error-path fixes, OF-64), the SDIO card driver (CMD8 0x1AA, ACMD41 with HCS, 1-bit bus, CMD16 before every
  transfer, CMD17 single-block read, one CMD25 + CMD12 per sector write, CMD13 polling at most 20000), DMA2 channel 4,
  SDIO/DMA ISRs, `sdio_gpio_init` 0x08023D56 / `sdio_gpio_deinit` 0x08023CD8 (pins through `brd_gpio_init`),
  `FUN_0801F84C` bring-up retries, `FUN_08022932` power-off.
- Same command and block sequence as v2.05 for the same file operations (FAT12/16/32, 8.3 names, one drive, `disk_read`
  reads one sector per call).
- Context: SD ISRs at priority 0; file operations main-only, under `sys_clock_select(1)` as v2.05.
- Deviations: IMP-06 (state machines).

### 6.24 SET: setup menu and settings (W9)

- Replaces: `FUN_08015410`, `FUN_080165F4`, item editors (`FUN_08015BE0`, `FUN_08015A22`, `FUN_08015A74`,
  `FUN_08015B54`, `FUN_08015AC0`, `FUN_08015C20`, `FUN_08015F7C`, `FUN_08016190`, `FUN_080160E8`), page drawers
  0x08017F94..0x080189B0, 0x08018A00, 0x08018590, page dispatcher `FUN_0801797C`, settings loaders/storers
  (`FUN_08011218`..`FUN_08011438`), rotary memory readers `FUN_08010FF0`..`FUN_080110E4`,
  `rotary_memory_store` 0x08011154, `FUN_08024DE0` (`set_state_reset`), `FUN_0800D190`, `FUN_0800D718`
  (`keys_setup.md` 4).
- EEPROM writes through `nvm_write_setting` / `nvm_write_ident` only (offsets of EMAP 7.1); 0x12 not written (OF-23).
- RAM: settings bytes (0x20008039, 0x20008078, 0x200080A5..0x200080BA), setup item 0x20008037, edit 0x2000806E..
  0x20008071, interval 0x2000022C, contrast 0x20000237, ID 0x20007D14/0x20007D18.
- Deviations: OF-23, NF-17 (switch), IMP-05 (continuity codes 4..15 in setup item 10 of BEEP).
- Production image only: `src/set/dbm.s` (`set_dbm_load`, `set_dbm_edit`, `set_dbm_draw`): item 11 of ACV becomes editable
  (the dBm reference, EEPROM 0x011, IMP-08); `fn_080165F4` dispatches it from `.Lse_port`, `fn_0801797C` draws the reference
  text instead of `fn_08018590` while `set_edit` is set.
- Production image only: `src/set/bt.s` (`set_bt_load`, `set_bt_edit`, `set_bt_draw`) and the setup item 21 (page bt, the
  Bluetooth frame rate, EEPROM 0x015, IMP-09), `src/set/tc.s` and the setup item 23 (page tc, the thermocouple type,
  EEPROM 0x00F, IMP-10): SETUP short on item 20 goes to item 21, on item 21 to item 23 in TEMP and to item 0 otherwise,
  on item 23 to item 0; `src/set/relp.s` and the setup item 22 (page rEL, REL in percent, EEPROM 0x020 bit 0, IMP-11) sit
  between items 21 and 23; `src/set/dsp.s` and the setup item 24 (page dSP, display level, EEPROM 0x013, IMP-12) and the
  setup item 25 (page CL, 12-hour clock, EEPROM 0x020 bit 3, IMP-13, in `src/set/relp.s`) close the chain
  (21 -> 22 -> 23 in TEMP -> 24 -> 25 -> 0); the edit timeout re-reads items 20 to 25 and 11 of ACV from the EEPROM.
- Production image only: `src/set/bl.s` (`set_bl_load`, `set_bl_edit`, `set_bl_draw`) and the setup item 20 (page bL, the
  backlight auto-off setting, EEPROM 0x017, IMP-07). Item 20 follows the last v2.05 item of every mode: the wrap of
  `fn_08015410` to item 0 lands on item 20, and SETUP short on item 20 goes to item 0; `fn_080165F4`, `fn_0801797C` and
  `fn_0800D190` dispatch item 20 to the three routines. Items 0..12 and 100 are unchanged. Every reader of the item byte
  0x20008037 outside SET tests it for equality with 1, 7, 10, 11, 12 or 100 (checked in ui/refresh.s, mdc/dc.s, mac/ac.s,
  mva/va.s, sys/isr_tim2.s, pwr/battery.s, lcd/annun.s, ble/packet.s), so item 20 is treated like items 3, 4, 8 and 9
  there (BLE packet: sub display zeros).

### 6.25 RTC: NJU6350 driver and date/time editing (W9)

- Replaces: `rtc_ce_high`, `rtc_ce_low`, `rtc_write_reg`, `rtc_read_reg`, `rtc_read_byte`, `rtc_data_pin_output`,
  `rtc_data_pin_input_pullup`, `FUN_08010204`, `FUN_080102B8`, `FUN_0800FF18`, `FUN_080100C4`, `FUN_0801016C`,
  `FUN_080103D8`, `FUN_08015C94`, `FUN_08015D40`, `FUN_08015E74`, `FUN_08015F44`, pages `FUN_08018788`, `FUN_080187D8`,
  `FUN_080188A0`, blink `FUN_0801896C`.
- RAM: 0x2000023D, 0x20007DBC..0x20007DC0, 0x200080D4, 0x200080D5, 0x200080D7..0x200080DC, 0x200080E7; port
  `rtc_blink_request`.
- Deviations: HW-01, NF-11.

### 6.26 BLE: USART2 link, status packet, commands (W9)

- Replaces: `usart2_init_19200_pf15_high` 0x0801C390, `usart2_deinit_pf15_low` 0x0801C954, `FUN_0800C51A`,
  `build_status_packet_19b` 0x0800C5DA via `FUN_0800C5D2`, `FUN_0800C332` (0xF4 key frames, 0xF8 clock frames),
  `FUN_0800D170`, packet helpers `FUN_0800CEFC`, `FUN_0800CFB0`, USART StdPeriph helpers, IRQ38 handler
  (`ble_packet.md`).
- OF-10: the builder writes into a second buffer in port RAM and marks it complete; `ble_tx_start_frame` (called from
  `sys_tim2_isr` at count 50 where v2.05 has the inline code 0x08024630..0x08024658) copies the complete buffer to
  0x20007AE0 only when no frame is in progress; command echoes are queued (`ble_tx_queue_put`) and sent after the frame
  in progress. OF-11: enabling BLE builds a frame before the first start.
- NF-04: while SYSCLK is HSE (SD access), frame starts are deferred to the first tick back on MSI and received bytes
  are discarded with the parser reset; v2.05 keeps the BRR computed for MSI (USART_Init 0x0801CAEC with
  RCC_GetClocksFreq at init only), so its baud rate is off by f_HSE / 4.194304 MHz during SD access (-4.6 % with the
  4 MHz crystal of the schematic text; crystal value UNPROVEN). The rule does not depend on the crystal value.
- RAM: 0x20007AE0 (frame), 0x20007B80 (receive), 0x2000802B..0x20008034, 0x20008047, 0x20008048, 0x200080AE..0x200080B1;
  port: second frame buffer, queue.
- Deviations: OF-03 (`FUN_0800CEFC`, `FUN_0800CFB0`: defined value 0 for out-of-range modes), OF-10, OF-11, NF-04,
  OF-34 (frames are not transmitted while the value is invalid during a range change; the previous frame stays the last
  one sent, ARS 5.2 P7).

### 6.27 Carried over as equivalent code (proof)

| v2.05 | Port | Proof |
|---|---|---|
| data_init + zero_init + lz77_init 0x08028FE4/0x08028CDC/0x080287C0 | plain copy of the 574-byte image and zero fill | the decompressed bytes equal `ram_init.txt` (model of the exact lz77 steps, 574 bytes identical); RAM at `main` entry identical; build check |
| RMS square root and average in `FUN_08008208` (0x0800827C..0x080082D4) | not executed | OF-16: each result word has one literal-pool reference, inside the handler; emulator read watchpoints showed no other reader; the four hooks are `bx lr` |
| Option-byte BOR rewrite | not present | owner requirement (never touch option bytes); NF-03 |
| Semihosting exit 0x0802912A | not reachable in either | `main` and `sys_main` never return |

---

## 7. Calibration, power-on window, cal.bin

### 7.1 Power-on window (BOOTWIN, in CAL)

v2.05 `FUN_0800EA3A` (from `main` 0x08024B66 and after STOP 0x08024F00): front-end pins as mode 0 (0x0800EA40..
0x0800EA70), splash "V-205" (`FUN_0801A854`), window counter 0x2000022E = 2000 TIM3 ticks (about 2.0 s), first HY3131
transaction (mode 5 range 0, 0x0800EA8A), key processing on each 10 ms flag; the combinations of `keys_setup.md` 3
(MODE then REL: calibration mode; MEM then REL/PEAK then MODE: cal.bin save/load; SETUP: date-code editing enable;
RANGE: all segments; MIN/MAX refused; HOLD not gated). v2.05 runs the TEMP row during the window and measures the dial's
mode only after it (ARS 6).

Port: `bootwin_start` and `bootwin_step` (state machine) with `BOOTWIN_TICKS` = 2000; the window opens at the same
moment, lasts the same time and gives every key exactly its v2.05 window meaning (a key held at power-up counts).
Baseline mode runs it blocking as v2.05 (TEMP row, then the dial's mode). Production mode (IMP-02, ARS 6): the main
loop runs during the window; the dial is latched with the v2.05 rule and its mode applied at once; the reading is shown
in the main digits with the version on the secondary display; a window key that starts a combination stops the
measurement display and the v2.05 combination screen takes over (the version leaves the secondary display); the RANGE
all-segments test is kept lit until the window closes (`ui_lamp_test`, UI); the first HY3131 write comes no earlier than in v2.05
(about 79 ms after reset at the start of the frame, ARS 6; in the emulator with the Cortex-M3 cycle costs, 2026-11-01, the
20-byte TEMP row frame ends at 82.27 ms in v2.05).  Both builds wait for the splash commit as v2.05 does and then a margin
of 1000 delay iterations (`BW_HY_MARGIN_LOOPS` in `bootwin.s`; 1.70 ms measured, about 7 cycles per iteration at 4.194 MHz):
the frame ends at 84.86 ms (baseline) / 84.53 ms (production), 83.16 / 82.83 ms without the margin. The margin is kept
because the emulated times are lower bounds and the port's start-up path (OPT-01) differs from v2.05's.  While a window
screen owns the main display (the splash before the version moves to the sub display, a combination screen, the
all-segments test), the apply's decimal point is stored but not drawn (`fn_080171FA`, `ui_bootwin_main_busy`); when the
version moves to the sub display the main digits are blanked, and the version is drawn again when an apply has cleared
its decimal point (`ui_bootwin_gate`). Ending the window early when no key is held is not done (ARS 6 item 2). OF-08: the
MODE-then-REL path sets calibration mode (0x2000808A = 1, 0x20008062 = 1) and writes nothing to the EEPROM.

### 7.2 Calibration mode rules in the port

EMAP 7.3 is kept, with these changes:
- OF-07 (owner decision 2026-10-31): SETUP short and MEM short in calibration mode are refused (refusal beep
  `FUN_0800EE6C`, no flag set) in modes 0 and 10; MEM long keeps its v2.05 behaviour in every mode (outside mode 9 range
  6 it starts the board-temperature offset capture, flag 0x20008096, record 0x2E0, which does not depend on the mode,
  EMAP 7.3); a capture whose countdown ends while meter_mode is 0 or 10 is discarded with the
  refusal beep and its flags cleared; NVM refuses CAL-class kinds 0 and 1 in modes 0 and 10. EMAP 7.4: a BEEP
  calibration in v2.05 writes 0x120, which BEEP itself loads but which is also the OHM range-1 record, so the refusal in
  BEEP protects OHM range 1 (Q1).
- NF-16 (switch `CAL_REFUSE_COMPLETION_7_8`, default 1): v2.05 refuses requests in modes 7 and 8 (0x08015728), but a
  capture started in another mode keeps counting across a mode change (no mode change clears the request flags,
  EMAP 7.3); whether a completion can run in PULSE or DUTY is UNPROVEN; if one did, it would write T[7]/T[8] + 16*range =
  0x100/0x110/0x120, the PULSE/DUTY/OHM records. With 1 NVM refuses kinds 0 and 1 in modes 7 and 8 (Q5).
- OF-08 (owner decision): no erase at calibration-mode entry. When CAL saves the range-0 offset of mode m in 16..21 (DC
  modes 17, 19, 21: the `cal_record_write(0)` corresponding to 0x0800F01A in `FUN_0800EF44`; AC modes 16, 18, 20: the MEM
  completion `FUN_0800F7B8`, offset write 0x0800F824), it calls `current_extra_clear(m)`: NVM class USERZERO writes
  A5 00 00 00 00 to that record, and RAM 0x20007E0C = 0 when meter_mode = m and meter_range = 0. Reason: the calibration
  capture never contains the user zero (EMAP 7.3), and the user zero corrects the zero point, which the offset save
  re-establishes (decision 12.2 Q2: at the offset save only).
- OF-09 (owner decision): the REL long press stores 0x20007E0C after the addition.
- NF-07 (switch `CAL_FIX_SETUP_FALLTHROUGH`, default 1 = fixed, decision 12.2 Q9): in v2.05 a SETUP short in calibration mode continues
  into the MEM-short code (0x08014DD4 `bne 0x08014DEE`): a successful offset start sounds the refusal pattern
  (0x08014E68), and in the AC-band case the same reading also writes slot 2 (R'+2 with R' = `ac_words_base`, i.e. record
  base + 0xA). With 1, SETUP ends after its own action with the accept beep.
- NF-08 (switch `CAL_CANCEL_ON_MODE_CHANGE`, default 1 = fixed, decision 12.2 Q9): with 1 a mode or range
  apply cancels a pending capture (refusal beep).
- NF-09 (switch `CAL_REFUSE_FREQ_OFFSET`, default 1): an offset request in mode 6 is allowed by `FUN_08015728` for
  ranges 0 and 1 and would write 0x100 or 0x110 if an offset completion ran in mode 6 (UNPROVEN whether one can). With 1
  NVM refuses kind 0 in mode 6 (FREQ loads only 0x104). If the path is unreachable, behaviour is identical (Q5).
- NF-10 (switch `CAL_FIX_MARKER26_RAM`, default 1 = fixed, decision 12.2 Q9): after an OHM range-6 calibration v2.05 sets RAM 0x20007FE0 = 1
  while the EEPROM marker 0x26 = 0xA5 gives 0x20007FE0 = 0 at the next boot (0x0800F8B8, 0x08010F1A..0x08010F20; DEF-13 in
  `hy3131_modes_misc.md`). With 1 the RAM flag is set to 0 at the write.

Switches are symbols in `firmware/src/inc/config.inc`, each with its default and reason; `make check` prints every
non-default switch of a build.

### 7.3 cal.bin (OF-12, owner decision)

Save writes 1248 bytes: EEPROM 0x000..0x4AF, then 0x4D0..0x4FF verbatim (0x4B0..0x4CF is never accessed and is not
saved), with the v2.05 read-back verify extended to 1248 bytes. Load: the size is taken from the FatFs file object's
size field after `f_open` (W8 identifies the field in the v2.05 FatFs code); exactly 1200 bytes restores 0x000..0x4AF as
v2.05; exactly 1248 bytes also restores bytes +0..+4 of each user-zero slot; any other size is refused before any write
with v2.05's error display ("-Err-"). This refuses files longer than 1200 bytes, which v2.05 accepted by reading the
first 1200 (owner instruction). All writes go through `nvm_restore` (class RESTORE). The read-back compare reads the
EEPROM directly instead of a 1200-byte stack copy (OPT-07), so the stack does not grow. File name, mount, open modes,
retry counts, file time and display sequence are v2.05's (EMAP 8).

---

## 7A. FatFs R0.16 in the production image (IMP-29, owner decision 2026-11-04)

The like-v2.05 build (branch `like-v2.05`) keeps the FatFs R0.08a port of v2.05 (`src/sd/fat.s`, `fat_dir.s`, `fat_file.s`,
with the OF-64 error-path fixes).  The production image replaces it with ChaN's FatFs R0.16 with patch 1 and patch 2 (CVE-2026-6682 BPB FAT-size
check, minimum volume and FAT12 cluster limits), translated by hand into Thumb-2 (`src/ff16/`, owner choice: hand
translation, not compiler output).  Every routine names the R0.16 C function it translates and follows its statements in
order; the source is `ff.c` "R0.16 w/patch 2" (ff16.zip sha256 99f7dc1f..., ff16p1.diff 7996ddc3..., ff16p2.diff
5cd39f1f...), kept outside the repository with the configuration below.

Configuration (ffconf.h): FF_FS_READONLY 0, FF_FS_MINIMIZE 0, FF_USE_CHMOD 1 (for f_utime; f_chmod is not translated),
FF_USE_FIND/MKFS/FASTSEEK/EXPAND/LABEL/FORWARD/STRFUNC 0, FF_CODE_PAGE 932 (as the v2.05 port: DBCS lead bytes 0x81..0x9F,
0xE0..0xFC), FF_USE_LFN 0 (8.3 names, as v2.05), FF_FS_RPATH 0, FF_VOLUMES 1, FF_MULTI_PARTITION 0, FF_MIN_SS = FF_MAX_SS
512, FF_LBA64 0, FF_USE_TRIM 0, FF_FS_TINY 0, FF_FS_EXFAT 0, FF_FS_NORTC 0 (get_fattime of `sd/diskio.s`), FF_FS_CRTIME 0,
FF_FS_NOFSINFO 0, FF_FS_LOCK 0, FF_FS_REENTRANT 0.

Translated: the public f_mount, f_open, f_read, f_write, f_sync, f_close, f_lseek, f_opendir, f_readdir, f_stat, f_utime,
f_unlink, f_rename, f_getfree and the 34 static routines they need (ld_16 .. mount_volume, validate).

Structures (measured with the ARM compiler on the configuration above): FATFS 560 bytes (fits the v2.05 work area
0x20006830, 0x230 bytes), FIL 552 bytes (the v2.05 areas hold 548: the two FIL objects of log, cal.bin and the Bluetooth
transfer move to `.bss_port`), DIR 44 bytes (v2.05 area 28: moves to `.bss_port`), FILINFO 24 bytes with the v2.05 offsets
(fsize 0, fdate 4, ftime 6, fattrib 8, fname 9: log_finfo stays).  Fields read by callers: the file size at FIL +12
(obj.objsize, as R0.08a +12, cal.bin), the file pointer at FIL +20 (R0.08a +8: `fat_f_tell` returns it).

Interface to the callers (unchanged symbols, so log, cal.bin and the Bluetooth transfer keep their calls): `fat_f_mount`
(r0 = volume 0, r1 = FATFS, the R0.08a form) calls f_mount(fs, "", 0) (registration without access, as R0.08a); the other
`fat_f_*` routines take the R0.08a arguments, which R0.16 keeps; FRESULT codes 0..15 and the FA_* open modes are the same in
both versions.  New: `fat_f_unlink`, `fat_f_rename`, `fat_f_getfree`.  Disk interface: disk_read / disk_write receive the
sector count as UINT (R0.16) instead of BYTE; `sd/diskio.s` takes the full count in the production image.

Verification: a differential harness runs the same operation sequences on the same FAT images through ChaN's C (host build,
RAM disk) and through the translation (Unicorn, RAM disk hooked to disk_read / disk_write) and compares every FRESULT,
every returned value and the images byte for byte; then the emulator card tests and the meter.
Results (2026-11-04): 8 images (FAT12 4 MiB and 300 KiB, FAT16 32 MiB, FAT16 98 MiB with 32 KiB clusters, FAT16 and FAT32
behind an MBR, FAT32 68 MiB, the emulator's 64 MiB FAT32 format) x 55 scripts (8.3 and DBCS names, a 70 kB file, directories, a volume
filled to the last cluster, 40 random operation sequences, 10 with an injected read or write error): every output line
and every image identical; r4-r11 and sp preserved by every call; deepest stack use 228 bytes (f_open with the mount,
without the SD driver).  Emulator: test_sd_errors, test_sd_large_card (8, 32, 128 GiB), test_log_trigger,
test_log_minmax_time, test_bt_upload (with a card that is full for the copy) pass; the card scenarios of the differential
comparison with v2.05 diverge only where the R0.08a image does, plus the clock-read timing of mem_logging_sd
(deviations.txt, IMP-29).  Verified working on a meter (2026-11-04): a log of 76 rows with the closing MAX / MIN rows
written and complete; the production image sent over Bluetooth (172 s, 3 failed card writes repeated), checked, written
as EEVBlog.bin and BTLOAD.TMP deleted; that image flashed and started.

## 8. Conventions

### 8.1 File layout

```
firmware/
  DESIGN.md  EEPROM_MAP.md  ORIGINAL_FIRMWARE_ISSUES.md  OPTIMIZATIONS.md (written during implementation)
  deviations.txt                 allowlist for emulator/diff (9.5)
  Makefile
  link/121gw.ld                  linker script (2.3, 5.1, 9.2)
  src/inc/  hw.inc               peripheral register addresses and bit names (RM0038 names)
            macros.inc           FUNC/ENDFUNC/LFUNC, CRIT_ENTER/EXIT, GPIO_SET/CLR, DELAY, TABLE_V205
            ram_v205.inc         v2.05 RAM symbols (generated once by tools/gen_ram_symbols.py, then maintained by review)
            config.inc           build switches (AR profiles, calibration switches, NVM keys, DEBUG), firmware version
            ff16.inc             FatFs R0.16 constants and structure offsets (7A)
  src/sys/  vectors.s reset.s clock.s isr_tim2.s main.s fault.s
  src/brd/  gpio.s board.s frontend.s adc.s delay.s exti.s stop.s
  src/pwr/  apo.s poweroff.s battery.s
  src/bzb/  buzzer.s isr_tim3.s
  src/rt/   fadd.s fmul.s fdiv.s fconv.s dadd.s dmul.s ddiv.s dconv.s dsqrt.s log10.s idiv64.s fcmp.s misc.s
  src/func/ smooth.s hold.s minmax.s rel.s post.s
  src/lcd/  lcd.s font.s draw.s bargraph.s annun.s
  src/ui/   refresh.s value.s messages.s memview.s
  src/key/  keys.s
  src/dial/ dial.s jack.s
  src/mode/ mode.s range.s tables.s
  src/ar/   autorange.s
  src/hy/   spi.s hy3131.s hy_rows.s service.s
  src/mdc/  ad1.s dc.s calmath.s
  src/mres/ ohm.s beep.s diode.s cap.s lowz.s
  src/mfrq/ counter.s freq.s pulse.s
  src/mtmp/ temp.s thermistor.s
  src/mac/  ac.s rms.s acdc.s filter.s peak.s corr.s
  src/mva/  va.s burden.s userzero.s burden_tables.s
  src/cal/  calmode.s capture.s records.s cache.s calbin.s bootwin.s
  src/nvm/  nvm.s nvm_allow.s flash.s
  src/log/  log.s csv.s files.s
  src/sd/   sdio.s sdcard.s diskio.s tables_v205.s   (FatFs: src/ff16/; R0.08a fat*.s on the branch like-v2.05)
  src/ff16/ ff16_low.s ff16_dir.s ff16_vol.s ff16_file.s ff16_file2.s ff16_api.s     (FatFs R0.16, 7A)
  src/set/  setup.s settings.s rotmem.s statereset.s
  src/rtc/  nju6350.s datetime.s
  src/ble/  usart.s packet.s commands.s rate.s bft.s
  tools/    gen_ram_symbols.py extract_tables.py gen_nvm_allow.py check_image.py check_hy.py check_gpio.py
            fe_levels.txt
  build/    (generated: *.o, 121gw.elf, 121gw.map, EEVBlog.bin, check report; not tracked)
```

One module per directory; a file holds routines of one module only.

### 8.2 Assembler syntax

- Every source file starts with `.syntax unified`, `.cpu cortex-m3`, `.thumb`, then `.include` of `macros.inc` (and
  `hw.inc`, `ram_v205.inc`, `config.inc` as needed).
- Sections: `.text.<module>`, `.rodata.<module>`, `.bss_port.<module>`; no code in data sections.
- Literal pools: `ldr rX, =value` with `.ltorg` after each routine group.
- FLASH registers are always addressed with their own literal address and offset #0 (no base+offset addressing of the
  FLASH block), so the instruction-level check of 9.3 is complete.
- No floating-point instructions (no FPU); all float work through RT.
- `it` blocks at most two instructions, each commented; assembled with `-mimplicit-it=never`.
- Interrupt handlers are AAPCS routines declared with `FUNC` (hardware stacking).

### 8.3 Macros (`src/inc/macros.inc`)

| Macro | Expansion / use |
|---|---|
| `FUNC name` / `ENDFUNC name` | `.global name`, `.type name, %function`, `.thumb_func`, `.align 1`, label; `.size name, . - name` |
| `LFUNC name` | as FUNC without `.global` |
| `CRIT_ENTER rX` / `CRIT_EXIT rX` | `mrs rX, primask` + `cpsid i` / `msr primask, rX` |
| `GPIO_SET port_base, mask` / `GPIO_CLR` | halfword store of mask to BSRRL (+0x18) / BSRRH (+0x1A), as v2.05 (it never writes ODR) |
| `DELAY n` | `movs r0, #n` (or `ldr` for large n) / `bl fn_0800ECF6` (v2.05 busy loop) |
| `TABLE_V205 addr, len` | marks a data table copied from v2.05 (entry in a non-loaded `.v205tab` section that the build check uses to compare the bytes with the original image) |
| `NVM_ARM class` | `ldr r0, =NVM_KEY_<class>` / `bl nvm_arm` |

### 8.4 Naming

- Module-local labels `.L<routine>_<what>`; local routines `<mod>_<name>`.
- Globals: canonical names (6, conventions); new routines `<mod>_<name>` (lower case, `_` separated).
- Constants: upper case with module prefix (`HY_VDD_SETTLE_US`, `BOOTWIN_TICKS`).
- RAM: `ram_v205.inc` names; port RAM `<mod>_<name>`.

### 8.5 Comment standard

Every routine has this header (GNU as ARM comment character `@`):

```
@ -----------------------------------------------------------------------------
@ hy3131_load_config_regs - select and write the HY3131 configuration row
@ Replaces : 0x0800B994 hy3131_load_config_regs (v2.05)
@ In       : r0 = mode (0..24), r1 = range
@ Out      : r0 = 0 written, 1 refused (mode/range out of bounds, DESIGN 4.1 item 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main only
@ RAM      : reads 0x20008098, 0x200080BA, 0x200080BD, 0x200080B9, 0x200080B7,
@            0x20007FDF, 0x200080C4, 0x200080C6, 0x200080C7, 0x20007FE0; writes 0x2000807D
@ Spec     : analysis/hy3131_model.md 3; DESIGN.md 4.1
@ Deviation: NF-15
@ -----------------------------------------------------------------------------
```

Inside a routine every instruction whose purpose is not obvious from its operands has a comment; register roles are
stated at the top of each block; every constant has a comment with its meaning and v2.05 source address; every branch
target label says which condition leads there. Tables copied from v2.05 carry source address, size and users. A
comment states only what is true of the code below it; a comment about v2.05 cites an address.

---

## 9. Build, checks and tests

### 9.1 Build

- `make`: assembles every `src/**/*.s` with `arm-none-eabi-as -mcpu=cortex-m3 -mthumb -mimplicit-it=never
  --fatal-warnings -I src/inc`; links with `arm-none-eabi-ld -T link/121gw.ld --build-id=none -Map build/121gw.map
  --no-undefined -nostdlib`; converts with `arm-none-eabi-objcopy -O binary`; pads to a multiple of 4; writes
  `build/EEVBlog.bin` and its SHA-256; runs `make check`.
- `make` builds the production (fast) image; the verification baseline (3.5) is built on the branch `like-v2.05`.
- Reproducible output: no timestamps or paths in the image (as and ld add none with these options), objects linked in
  sorted path order (`LC_ALL=C`), tool versions checked and printed (binutils 2.46.0). The same sources give the same
  SHA-256.
- `make listing`: `arm-none-eabi-objdump -d -S` of the ELF for review.
- `make check-ci`: the checks of 9.3 that need no original image (1, 2, 4, 5, and 3 as far as it concerns `hy_rows` and
  `brd_fe_table`), run by the GitHub workflow `.github/workflows/firmware.yml`. `tools/check_hy.py --reference-data
  tools/hy_reference.txt` reads the v2.05 HY3131 write sequences from the committed data file instead of executing the
  original image (`--reference --write-reference` regenerates it); the checks that compare with the image (`TABLE_V205`
  regions, `.data_v205`, `nvm_allow`, `ram_v205.inc`) are printed as SKIPPED and run in `make check`.
  `tools/build_dist.sh` builds both variants in the layout of the release archive, `tools/gen_fixes.py` writes its
  `FIXES.md` from `ORIGINAL_FIRMWARE_ISSUES.md`, `tools/gen_emu_tables.py` writes the v2.05 tables of the sources for the emulator.

### 9.2 Linker script (`link/121gw.ld`)

MEMORY: FLASH 0x08006000, length 0x5A000; RAM_V205 0x20000000, length 0x80FC; RAM_PORT 0x20008100, length 0x1700.
SECTIONS: `.vectors` (KEEP, at 0x08006000), `.text*`, `.rodata*`, `.v205tab` (not loaded), `.data_v205` at 0x20000000
(AT> FLASH, exactly 0x23E bytes), `.stack` 0x2000023E..0x2000123F (NOLOAD), `.bss_v205` 0x20001240..0x200080FB (NOLOAD,
zeroed by `sys_reset`), `.bss_port` in RAM_PORT. ASSERTs: image end <= 0x08060000; `.data_v205` size 574; `.bss_v205`
start 0x20001240; `.bss_port` inside RAM_PORT.

### 9.3 Static checks (`make check`, every build)

1. Image: word 0 = 0x20001240 and passes the bootloader test; word 1 odd and inside the image; size a multiple of 4 and
   <= 0x5A000; 73 vectors.
2. Never-brick check at instruction level (`tools/check_image.py`, disassembles the linked ELF): for every load and
   store, the effective address is computed when the base register holds a known constant in the basic block (pool
   literal, `movw`/`movt`, `adr`, add of constants); rejected: any effective address 0x40023C10 (PRGKEYR), 0x40023C14 (OPTKEYR)
   or 0x40023C1C..0x40023C2F (OBR, WRPR; RM0038 3.9.10 register map: FLASH_SR at 0x40023C18 is not rejected, it is allowed in
   NVM below) or 0x1FF80000..0x1FF800FF, any store to program flash 0x08000000..0x0805FFFF, any access to the
   FLASH block with a base plus non-zero offset or a register offset; any `movt` producing 0x1FF8 or a constant equal to one
   of the rejected FLASH addresses anywhere; aligned pool words with those values; the PRGKEY and OPTKEY values 0x8C9DAEBF,
   0x13141516, 0xFBEAD9C8, 0x24252627 as pool words or `movw`/`movt` pairs. Stores to PECR may only set PELOCK or clear
   FTDW (value analysis of the stored constant). Allowed only in the NVM objects: 0x08080000..0x08082FFF, 0x40023C04
   (PECR), 0x40023C0C (PEKEYR), 0x40023C18 (SR), 0x89ABCDEF, 0x02030405. FLASH_ACR 0x40023C00 only in the SYS clock object.
3. Tables: every `TABLE_V205` region equals the v2.05 image bytes; `.data_v205` equals `ram_init.txt`; `hy_rows` and the
   reachable (row, INTE) set (4.1); `nvm_allow` regenerated from EMAP 9.2 and compared; `brd_fe_table` against
   `tools/fe_levels.txt`.
4. GPIO policy (`tools/check_gpio.py`): decodes the constant arguments of every `brd_gpio_init` call and rejects
   output or AF configuration of PF3, PE10, PE11, PD6 (except AF7), PC8/PD2 (except AF12), PH0, PH1, PA13, PA14,
   PG0..PG15, and push-pull output of PB7 (HW-01); no MODER/OTYPER/PUPDR/AFR write outside BRD.
5. Symbols: every routine of Appendix C is defined exactly once; no undefined symbol.

### 9.4 Tests in the emulator

The emulator (`emulator/app.py`, `emulator/emu/*`) runs the real bootloader and then the image given by `--app`, with
the EEPROM image given by `--eeprom`. The differential harness `emulator/diff/` (`run.py`, `scenario.py`, `trace.py`,
`compare.py`, `scenarios/`) runs v2.05 and a candidate through the same scripted scenarios (keys, dial, jacks, input
signals, battery/thermistor voltages, SD card, BLE bytes, power cycles; fixed noise seed and calendar) and compares the
streams lcd, gpio (with derived power), spi, uart_tx, eeprom, rtc, sd_cmd, sd_block, reset, fault, and the final EEPROM
image, SD files and LCD frame. The safety monitor `emulator/emu/safety.py` runs in every session.

Without a bootloader image the emulator also starts the application directly from its vector table (SP, reset vector,
VTOR = 0x08006000) with a synthetic EEPROM and the v2.05 tables taken from the `TABLE_V205` data of this tree
(`tools/gen_emu_tables.py`): the standalone mode of the release packages. Direct boot does not reproduce the bootloader's
TIM2, NVIC, clock, FLASH_PECR, GPIO and LCD state of 2.1; the list is in `emulator/API.md` 2.2. The scenario levels below use the real bootloader.

Test levels:
1. RT (W2): each port helper against the v2.05 helper in a bare CPU emulation (Unicorn), at least 20 000 random operands
   per helper plus every edge class (zeros, subnormals, infinities, NaNs, exponent boundaries, halfway cases, divisor
   0); pass = identical result registers, flags (compares) and errno.
2. Routine level (every module): a v2.05 function and its port replacement executed from the same CPU and RAM state
   (states captured from v2.05 scenario runs at the function's entry); result registers, RAM writes and peripheral
   accesses compared; routines with a deviation compared against its expected difference. Requires the routine runner
   of 13.1 (W10).
3. Scenario level, baseline image (the like-v2.05 build, branch `like-v2.05`): every scenario in `emulator/diff/scenarios/`, zero divergences
   except allowlisted deviations (OF-, NF-, HW-, NVM- entries).
4. Scenario level, production image: the same scenarios plus the IMP scenarios (auto-range timing, boot, beep latency,
   continuity codes); allowlist entries for IMP-01..IMP-06 with value tolerances where readings are averaged over more
   samples (settled values identical, ARS 5.1 invariant 1).
5. Safety: the monitor on in every run; a probe build (`make SAFETY_PROBE=1`) whose image tries, in order, a SETTINGS
   write to 0x030, an IDENT write without the item-8 path, a write to 0x500, a PEKEYR write while unlocked (expected to
   be refused by NVM before the store), a HY3131 frame with a non-whitelisted shape and a PF3 output configuration; each
   must be refused by the port's own guard (counters in port RAM) before the emulator monitor sees it. The probe build
   alone is exempt from check 9.3 item 4 for its own probe call sites (listed in `tools/check_gpio.py`); it is never
   released.
6. EEPROM robustness: boot scenarios with EEPROM images all 0x00, all 0xFF, random bytes (fixed seed) and the supplied
   calibration backup in `inputs/binaries`; pass = same behaviour as v2.05 on the same image.
7. STOP/wake: APO and wake by every key and every dial position (NF-05), with and without a pending buzzer repeat
   (HW-08).
8. Stack: deepest use per scenario, limit 3072 bytes, canary intact.

Order (owner rule): all modules are written first; then one build, all tests, and fixing; after a fix only the affected
routine tests and the scenarios that cover the changed module are rerun; one full run of every level at the end.

### 9.5 Deviation allowlist

`firmware/deviations.txt`: one entry per expected divergence, in the format of `emulator/emu/allowlist.py` (all prefixes
OF-, NF-, HW-, NVM-, IMP-, OPT-; several references joined by `+` for one event; condition fields `t`, `step`, `since`,
`boot` and, for uart_tx, `pos`; the clause `build == baseline|production` restricts an entry to one build mode and is
selected with `emulator/diff/run.py --build`; `mask:lcd:sub` / `mask:lcd:main` entries leave one display row out of the
LCD comparison; `tolerance:<stream>` entries widen a time tolerance). The file ends with the list of deviations that no
scenario makes observable. Candidate runs use `--no-noise` (a timing shift below 1 us changes the noise drawn for a
conversion).

---

## 10. Deviation table

Status: approved = owner decision (2026-10-31); fix = defect fix under the owner's rule to fix all bugs; switch = behind
a build switch, default stated; required = forced by a non-negotiable requirement.

| ID | Area | v2.05 behaviour (evidence) | Port behaviour | Status | Module |
|---|---|---|---|---|---|
| OF-01 | table lookup | stale index on a failed search (`FUN_08007D1E`, 0x08007D46) | on a failed search the uncorrected value is returned | fix | MRES |
| OF-02 | frequency rounding | unset r6/r7 stored (`FUN_0800AEE8`); above 1 MHz the AC correction uses an undefined value | defined values; case 9 uses the measured frequency | fix | MFRQ |
| OF-03 | BLE packet helpers | unset r7 stored for out-of-range modes (`FUN_0800CEFC` 0x0800CF28, `FUN_0800CFB0` 0x0800CFFE) | defined value 0 | fix | BLE |
| OF-04 | dBm multiplier | unset r4 into a float multiply for mode byte > 3 (`FUN_0800A74C` 0x0800A762) | multiplier 1.0 | fix | MAC |
| OF-05 | contrast helper | unset r4 passed on for contrast values outside 10..17 (`FUN_0801B77A` 0x0801B784, 0x0801B79C, 0x0801B7FA) | for such values FCR CC is left unchanged, as `FUN_0801B708` does (0x0801B70E..0x0801B774) | fix | LCD |
| OF-06 | GPIO | uninitialised pin mask (`FUN_0801C2C6` 0x0801C2F2) | mask 0 (no pin) for unhandled arguments | fix | BRD |
| OF-07 | calibration | LowZ completion writes the ACV r0 record; BEEP writes 0x120 (= OHM r1) | refused in modes 0 and 10 (7.2) | approved | KEY, CAL, NVM |
| OF-08 | calibration | cal-mode entry rewrites all six user-zero records | record cleared only at its own range-0 offset save (7.2) | approved | CAL, MVA |
| OF-09 | calibration | REL long stores only the increment | stores the accumulated value | approved | MVA |
| OF-10 | BLE | build and transmit unsynchronised | double buffer and queue (6.26) | fix | BLE |
| OF-11 | BLE | stale first frame | frame built before the first start | fix | BLE |
| OF-12 | backup | cal.bin omits 0x4D0..0x4FF | 1248-byte file; 1200 accepted; other sizes refused (7.3) | approved | CAL, NVM |
| OF-13 | ADC | SMPR3 written with ADON = 1 | sample time configured once with ADON = 0 | fix | BRD |
| OF-14 | measurement | AD1 decoded as code - 0xFFFFFF | sign-extend bit 23 | fix | MDC |
| OF-15 | measurement | +0.5 then truncation | round half away from zero | fix | MDC |
| OF-16 | measurement | RMS result computed and discarded | event cleared, nothing computed; INTE values unchanged (4.1) | fix | HY, MAC |
| OF-17 | measurement | PEAK + 1 kHz filter blanks the display | second key refused | fix | KEY |
| OF-18 | measurement | pulse width from truncated duty | width from counts, rounded | fix | MFRQ |
| OF-19 | measurement | TEMP re-converts its own result in MEM view | separate result variable | fix | MTMP, UI |
| OF-20 | measurement | BEEP OL limit inherits the latch | latch cleared on every apply | fix | AR |
| OF-21 | measurement | temperature rounding on the wrong digit | round on T mod 10, half away from zero | fix | MTMP |
| OF-22 | measurement | degF sign from bit 15, one's complement | signed 32-bit conversion | fix | MTMP |
| OF-23 | settings | DIODE 15 V written to 0x12 and never restored | 0x12 not written; 15 V behaviour unchanged (Q6) | fix | MRES, SET |
| OF-24 | measurement | CJ silently stale below -20 degC | existing CJ fault path | fix | MTMP |
| OF-25 | measurement | AC+DC sum of squares wraps at 2^32 | 64-bit sum; ranges up / OFL | fix | MAC, AR |
| OF-26 | measurement | filter reading x10 below 20 Hz | 1/10 scale on every path | fix | MAC, MDC |
| OF-27 | measurement | VA burden table read past its rows | column and row index clamped | fix | MVA |
| OF-28 | measurement | one smoothing state for two quantities | one state per quantity | fix | FUNC, MAC, MVA |
| OF-29 | measurement | DC VA burden correction depends on sign | correction on the magnitude | fix | MVA |
| NF-01 | ADC | ADC_Init ORs an uninitialised stack byte ([sp+8] of 0x08013DD4) into ADC_CR2 | field 0 (software trigger, as used via SWSTART 0x080202EA) | fix | BRD |
| NF-02 | clock | endless loop at 0x0801BF58 if HSERDY still reads 1 after HSE off (cannot occur in practice by instruction count against the 6 HSE cycles of RM0038 6.3.1; estimate) | bounded wait, continue | fix | SYS |
| NF-03 | option bytes | BOR level rewritten with OBL_LAUNCH reset whenever BOR_LEV != 0 (0x0801BEAC..0x0801BED4); dormant on the supplied unit | never touched | required | SYS |
| NF-04 | BLE | baud wrong while SYSCLK = HSE | no transmit or receive while on HSE | fix | BLE |
| NF-05 | STOP | single `wfe`, no check of the wake source (0x080207F6) | SEVONPEND + PRIMASK loop testing the armed EXTI lines (3.6) | fix | BRD |
| NF-06 | STOP | EXTI lines and NVIC enables stay on after wake | disabled after wake | fix | PWR |
| NF-07 | calibration | SETUP short falls into MEM-short code (0x08014DD4) | fixed (switch default 1) | switch | KEY, CAL |
| NF-08 | calibration | pending capture survives mode/range change | fixed (switch default 1) | switch | CAL |
| NF-09 | calibration | FREQ offset request could write 0x100/0x110 (reachability UNPROVEN) | switch, default refuse | switch | CAL, NVM |
| NF-10 | calibration | 0x26 marker RAM flag inverted until reboot | fixed (switch default 1) | switch | CAL |
| NF-11 | LCD | TIM2 ISR draws into the shadow while main read-modify-writes it | ISR sets a request, main draws | fix | SYS, RTC, LCD |
| NF-12 | start-up | VTOR switched late; bootloader TIM2 IRQ live | IRQs disabled and cleared, VTOR set first | fix | SYS |
| NF-13 | start-up | FLASH_PECR left unlocked by the bootloader until the first EEPROM write | PELOCK at reset | fix | SYS, NVM |
| NF-14 | faults | fault handlers hang with outputs as they were | safe outputs, power-down, STOP, reset on wake (4.7) | fix | SYS |
| NF-15 | HY3131 | mode > 24 would send uninitialised bytes (0x0800BA2E, 0x0800BF06; unreachable as traced) | bounds check, no write | fix | HY |
| NF-16 | calibration | a capture could complete in PULSE/DUTY (UNPROVEN) | switch, default refuse | switch | CAL, NVM |
| NF-17 | settings | the setup editor stores contrast 10..17 (0x08015B64, 0x08015B8E, save 0x08015BB2) but boot keeps only 12..17 (0x08011264..0x0801127C), so 10 and 11 become 14 after power-up | switch `SET_ACCEPT_CONTRAST_10_11`, default 1 (decision 12.2 Q11) | switch | SET |
| HW-01 | RTC bus | PB7 push-pull while the NJU6350 drives DATA | open-drain with pull-up, released from command bit 4 until CE low | fix | RTC, BRD |
| HW-02 | power-down | HY bus driven high into a possibly unpowered HY3131 after PE9 low | HY bus analog before PE9 low | fix | BRD |
| HW-03 | wake | HY bus driven about 0.3 ms after PE9 high | HY bus configured last, plus `HY_VDD_SETTLE_US` (default 0, Q3) | fix | BRD |
| HW-04 | GPIO | MODER written before the level | level first | fix | BRD |
| HW-05 | HY3131 | restart bytes from SPI read-back | from the row table | fix | HY |
| HW-06 | DIODE 15 V | PE15 high 3 instructions before PF6 low on exit | PF6 low first | fix | BRD |
| HW-07 | LCD | unbounded waits on LCD_SR | bounded | fix | LCD |
| HW-08 | buzzer | TIM3 can raise PE7 after power-down cleared it (reachability UNPROVEN) | buzzer state cleared first | fix | BZB, PWR |
| NVM-1 | EEPROM | sticky FLASH error blocks all writes until reset | flags cleared per attempt, read-back verify | fix | NVM |
| NVM-2 | EEPROM | writes regardless of battery state; BOR off; a byte write erases its word first | switch `NVM_REFUSE_LOW_BATTERY`, default 1 (decision 12.2 Q10): with 1 NVM refuses writes while the low-battery flag of `adc_ch5_process` is set (Q10) | switch | NVM |
| OF-30 | LowZ | forced "0.0" V for 1.1..2.4 s when a voltage appears (detector 0x08006558 stores 0 for the first five means above threshold), HV symbol up to 1.58 s late | the moment a mean exceeds the LowZ threshold: HV symbol where v2.05 would light it for that value, dashes on the main digits until the AC/DC decision, then the value; AC/DC selection otherwise as v2.05 | fix (owner decision) | MRES, UI, LCD |
| OF-31 | main loop | LCD busy-wait paces the loop; conversions beyond about 72/s dropped; CPU never sleeps | production loop mode (IMP-06); baseline mode keeps v2.05's loop for verification | fix | SYS, LCD |
| OF-32 | display | BEEP and FREQ draw the zeroed value at mode entry | blank until the first valid value | fix | UI, MRES, MFRQ |
| OF-33 | CAP | timeout range jump draws the old count with the new decimal point for one update | blank across the jump | fix | MRES, UI |
| OF-34 | BLE | frames built during a range change report 0 | frames skipped while the value is invalid | fix | BLE |
| OF-35 | logging | log stores the per-sample value 0x20007D68 | log stores the displayed value | fix | LOG |
| OF-52 | battery | table conversion code / 280 - 0.643 V (`FUN_08013728`, table 0x08028C9C); low-battery symbol below 4.31 V real | B+ = code x 3.3 / 4095 / (330/1330); 4.1 V threshold kept (12.2) | fix (owner decision) | PWR |
| OF-53 | HY3131 | INTF written 0 after the event read (0x0800616C): a flag raised in between is lost (CTF: counter not restarted) | INTF acknowledge 0 only for the flags read as set, 1 for the others (DS p19); both builds (12.2, 4.1 item 4) | fix (owner decision) | HY |
| OF-54 | HY3131 | counter registers clocked out before INTF (burst from register 0): CTF seen with the values of the previous count | data and CTF of the same completed count (production: INTF read first; baseline: counter block read again on CTF) | fix (owner decision) | HY |
| OF-55 | backlight | RAM flag 0x2000807B survives an auto power-off while PE8 is driven low (OF-55 evidence); the first MODE long press after the wake only clears the flag | `set_state_reset` clears the flag and the IMP-07 countdown (`pwr_bl_reset`) at power-on and after the wake; the strict image clears the flag only | fix | PWR, SET |
| OF-56 | temperature | type K table 0x08025CF8 holds 10970 uV at 270 degC (NIST 10971) | NIST K table `mtmp_tc_tab_k` (generated, both images); the v2.05 table stays unreferenced | fix | MTMP |
| OF-57 | SD | byte address `sector << 9` in 32 bits: accesses past 4 GiB wrap to sector N mod 2^23 | 64-bit byte address in disk_read / disk_write | fix | SD |
| OF-58 | SD | get_fattime constant 2006-02-09 22:30 (creation time of every file) | FAT time from the clock chip copy 0x200080D7..DC | fix | SD |
| OF-59 | SD | disk status = raw sd_init code (bit 0 tested); read and write ignore SDIO errors | STA_NOINIT on any init failure; RES_ERROR on an SDIO error, a refused block or a missing data / DMA end | fix | SD |
| OF-60 | logging | forced new file (after 20 failed attempts) without CSV header | header due for every new file | fix | LOG |
| OF-61 | logging | final write failure clears the logging flag without log_stop (range stays frozen) | log_stop(0) first | fix | LOG, SYS |
| OF-62 | calibration | RAM variant flags 0x20008087 / 0x20007FE0 not refreshed after a marker write | read back with the boot routines after the write | fix | CAL |
| OF-63 | buzzer | diode, auto-hold, APO warning and power-off beeps ignore the buzzer setting | gated (owner decision); continuity and the safety warnings still sound | fix (owner decision) | BZB, MRES, FUNC, PWR |
| OF-64 | SD | FatFs R0.08a error paths (start cluster before the check, create_chain on a read error, stale window after a failed read, dirty flag after a failed load) | the R0.10a..R0.10c changes | fix | SD |
| NF-18 | STOP | DBGMCU_CR \|= 7 at every start (0x0801BEF8) keeps the RC oscillator and FCLK/HCLK running in STOP (RM0038 DBGMCU_CR bit 1) | set only in debug builds; production enters the true STOP (hardware check in Q8) | fix | SYS |
| IMP-01 | auto-range | `autorange_step` one range per decision | ARS 5: per-sample detection, direct target range, CP settle profile by default, TP per family only after H1..H8 (ARS 12); first value after a change from 4 clean samples (ARS 5.2 P5) | approved | AR, MDC, MAC, MRES, UI |
| IMP-02 | boot | measuring starts after the 2 s window | ARS 6: window kept, measuring during it (7.1) | approved | CAL, SYS |
| IMP-03 | ohm | update rate locked to the LCD loop | ARS 7: every conversion, display blocks >= 100 ms | approved | MRES |
| IMP-04 | beep/diode | latency 6..8 ms / 0.356 s | ARS 8.2: every conversion; DIODE on K = 2 samples | approved | MRES |
| IMP-05 | continuity | codes 0..3 in EEPROM 0x14 | ARS 9: codes 0..15 (0..3 unchanged), boot accepts < 16 | approved | SET, MRES |
| IMP-06 | main loop | LCD-locked loop, full HY3131 burst, blocking routines, no sleep | production mode of 3.5 (no busy-wait, per-event reads, state machines, `wfi`) | approved | SYS, LCD, HY, LOG, SD, BZB, CAL |
| IMP-07 | backlight | on and off only by the MODE long press (0x080162E4..0x0801631A); RAM flag 0x2000807B stays 1 across a STOP while PE8 is low (the only references to the flag are the three loads of the MODE long press, listing 0x08016C84) | production only: SETUP page bL (item 20) sets an auto-off time, OFF (default) / 30 s / 1..99 min, stored in EEPROM 0x017 (EMAP 4.1); countdown on the 1 s flag while the backlight is on, restarted by any key press, dial change, injected key and edit step; at zero the backlight is switched off as the MODE long press does (flag and PE8, no beep); the flag and the countdown are cleared at power-on and STOP wake so that they follow PE8, then the state of the last MODE long press (0x017 bit 7, written by that press only) is restored (owner, 2026-11-02). The strict image is unchanged | approved (owner, 2026-11-02: one new EEPROM byte) | PWR, SET, KEY, DIAL |
| IMP-08 | dBm reference | ACV page 11 shows 10 log10(x^2 / 0.6), dBm into 600 ohm only (`mac_dbm` 0x0800A74C, constant 0x0800A7C6..0x0800A7CA); the page is not editable (`fn_080165F4` returns 0 for item 11 of ACV) | production only: long SETUP on the page edits the reference, 600 ohm (v2.05, default) / 50 ohm / 75 ohm / dBV, shown as `r 600`, `r  50`, `r  75`, `r dbV` while editing; the divisor 0.6 / 0.05 / 0.075 / 1.0 comes from `set_dbm_divisor` (entry 0 is the v2.05 double); stored in EEPROM 0x011 (EMAP 4.1), a value above 3 reads as 600 ohm; units dB m, or dB alone for dBV. The BLE frame keeps sub-mode 0xB4 (a phone application labels every reference dBm). The strict image is unchanged | approved (owner, 2026-11-02: EEPROM bytes of FEATURES.md 3) | SET, MAC, LCD |
| IMP-09 | Bluetooth frame rate | one status frame per 50 TIM2 ticks (0.501 s), built at count 40 of the counter 0x20007F04 that also makes the 500 ms flag, blinks and jack-warning beep (0x080245F6..0x08024658) | production only: SETUP page bt (item 21, after bL) selects 2 (default, v2.05 counter) / 4 / 10 / 20 frames per second; codes 1..3 run on the counter `ble_rate_cnt` (`ble_rate_tick`, periods 25 / 10 / 5 ticks, build 10 / 5 / 2 ticks before the start) and the 500 ms counter keeps its other users; stored in EEPROM 0x015 (EMAP 4.1), a value above 3 reads as 2 per second; frame content unchanged; only complete frames are sent (OF-10). The strict image is unchanged | approved (owner, 2026-11-02: EEPROM bytes of FEATURES.md 3) | BLE, SET, SYS |
| IMP-10 | thermocouple type | type K only: EMF table 0x08025CF8 and window -5891 / 54139 uV in `fn_08013C40`, the same table for the cold junction in `fn_08013CF8` | production only: SETUP page tc (item 23, after bt, TEMP only) selects K (default, v2.05) / J / T; both routines take table and window from the descriptor of the type (`mtmp/tctype.s`); J and T tables from the NIST ITS-90 tables (`mtmp/tc_tables.s`, `tools/gen_tc_tables.py`); spans K -200..1350, J -200..936 (the K input-voltage limit), T -200..400 degC; stored in EEPROM 0x00F (EMAP 4.1), a value above 5 reads as K (codes 3..5 N, R, S: IMP-26). The strict image keeps type K only; both images convert with the NIST K table since OF-56 | approved (owner, 2026-11-02: EEPROM bytes of FEATURES.md 3) | MTMP, SET |
| IMP-11 | REL in percent | REL shows x - base in counts only (`fn_0800E594`, base 0x20007DA8) | production only: SETUP page rEL (item 22, after bt) selects difference (default, v2.05) / percent; in percent, while the REL sign is shown, `fn_08016E08` draws D * 100 / base with the decimal point by magnitude (`ui_relpct_draw`: 0.001 % .. 1 %, OFL above 99999 %, dashes for a zero base) and `lcd_commit_shadow` applies `ui_relpct_mask` (unit and prefix signs off, % on; redraw of all signs when the view ends); D, logging, MIN/MAX and the BLE value stay in counts; stored in EEPROM 0x020 bit 0 (EMAP 4.1). The strict image is unchanged | approved (owner, 2026-11-02: EEPROM bytes of FEATURES.md 3) | UI, SET, LCD |
| IMP-12 | display level | smoothing depths fixed per caller (2, 5, 10, 20) | production only: SETUP page dSP (item 24, last port page) selects level 1 (default, v2.05) / level 2; at level 2 `func_avg_core` and `func_hist_core` use a quarter of the depth, at least 1 (thresholds, mean lengths, auto-ranging and HY3131 unchanged); stored in EEPROM 0x013 (EMAP 4.1). The strict image is unchanged | approved (owner, 2026-11-02: less smoothing) | FUNC, SET |
| IMP-13 | 12-hour clock | the time page shows the hour 00..23 (`fn_080188A0`) | production only: SETUP page CL (item 25) selects 24-hour (default, v2.05) / 12-hour; `fn_080188A0` shows 1..12 with the leading zero blank, no AM/PM mark; clock chip, edit, log and BLE stay 24-hour; stored in EEPROM 0x020 bit 3 (EMAP 4.1) | approved (owner, 2026-11-02) | RTC, SET |
| IMP-14 | statistics | MIN/MAX keeps max, min, an integer running mean and a count (fn_0800E604) | production only: pages n (item 32) and Sd (item 33) while MIN/MAX is on; Welford in binary64 on the readings of the running mean (`func/stats.s`), sample standard deviation on the main digits with one more decimal (`ui/stats_ui.s`); the OF-51 fixes of dsqrt and the 64-bit divisions in the production runtime library | approved (owner, 2026-11-02: all features) | FUNC, UI, SET, RT |
| IMP-15 | bargraph polarity at zero | polarity = sign of the per-sample value 0x20007D68 (0x08018FD6; BLE byte 13 0x0800C798); v2.05's rounding of negative values (OF-15) kept a zero input at 0 or more, so it showed "+" | production only: with no bar lit (count 0) the polarity, on the LCD and in BLE byte 13, is the sign of the displayed value D (`lcd_bar_negative`), with bars lit the per-sample sign as v2.05; without it the correctly rounded per-sample noise of a zero input made the sign change every 14..40 ms (found by the differential harness, setup_navigate_dcv). The strict image is unchanged | fix of a production defect | LCD, BLE |
| IMP-16 | continuity hold time | the tone lasts 100 TIM3 ticks after the last passing reading (`pe7_on_with_timeout(100)`, 0x08007902 / 0x08007920) | production only: SETUP page bH (item 26, BEEP only) selects 100 (default, v2.05) / 50 / 25 ms / off (15 ticks: the re-arms of a steady contact come every 3.1 .. 10.0 ms, so a shorter hold would chop the tone); `set_bh_ticks` gives the hold to `fn_080078D8`; stored in EEPROM 0x021 (EMAP 4.1). The strict image is unchanged | approved (owner, 2026-11-03: forum request) | MRES, SET |
| IMP-17 | bargraph update cost | `lcd_update_bargraph` calls `fn_08019408(25, k)` for every segment k above the count (up to 25 calls of up to 25 clear blocks) | production only: one pass over a 25-entry segment table sets segments 1..count and clears count+1..25 (same end state, bit for bit); in BEEP, where the bargraph is updated on every conversion, the cascade took 28 % of the CPU: handled conversions 236 -> 380 per second (emulator) | performance fix | LCD |
| IMP-18 | HY3131 reads per event | the production service routine read INTF, INTE, R20 and R29 on every event | production only: R20 is not read back (its copy has no reader); R29 is read only when the loaded row sets ENPKH (peak rows), otherwise its value is the R29 written (`hy_row_r29`; every R29 write leaves the chip at that value). Only after a chip brown-out reset, whose register values the datasheet does not give, could the skipped read have differed. 25 % fewer SPI clocks per conversion | performance fix | HY |
| IMP-19 | HY3131 write bit timing | `hy3131_spi_write_byte` calls `hy3131_spi_clock_pulse` per bit, two delay(1) calls per pulse | production only: the write loop uses the bit timing v2.05 itself uses for reads (no delay; CK high >= 6 instructions as the read loop's 6..9, DI set >= 3 instructions before the rising edge; datasheet figures 20..60 ns, one instruction 238 ns); same levels and order. In BEEP 462 instead of 396 conversions per second (emulator). Emulator: beep_values, dcv_values, peak_acv, autorange_dcv identical, no safety finding. Verified working on a meter (HARDWARE_TEST.md step 16) | performance; meter test pending | HY |
| IMP-20 | limit test | none | production only: pages Lt / Lo / HI (items 27..29) and the verdict page (36), `set/limit.s`; limits captured from the displayed value, RAM only; verdict per new result (`lt_tick` from `fn_08016E08`) with the refusal pattern / accept beep on changes; range frozen and RANGE refused while on (key/short.s, key/long.s); a mode or range change ends the test | approved (owner, 2026-11-02: limits captured, RAM only) | SET, KEY, UI |
| IMP-21 | logging trigger | a record every interval (sys_main step 9) or 5 per second with interval 0 (sys_tim2_isr) | production only: SETUP pages tr (item 30) and Ch (31): tr-In (v2.05), tr-Ch (a record when the displayed reading moved >= Ch counts since the last record, tested per second), tr-Lt (a record per limit-verdict change); with tr-Ch / tr-Lt interval 0 has no fast path; every request sets v2.05's flag 0x20007FE2 (`log/trigger.s`); EEPROM 0x020 bits 2..1, 0x022. The closing MAX / MIN rows end with `YYYY/MM/DD,hh:mm:ss,` of their row (`log/mmtime.s`, kept by log_take_max_main / log_take_min_main); while MIN/MAX is on the pages tHI (item 34) and tLo (35) after Sd show the hour-minute of the maximum / minimum on the main display, taken from rtc_hour / rtc_minute when fn_0800E604 changes the register (`ui/mmtime.s`), RAM only | approved (owner, 2026-11-02: all features) | LOG, SET, SYS |
| IMP-22 | auto-hold at zero in OHM and DIODE | a signal needs at least 1000 counts (`fn_0800E30C` 0x0800E366..0x0800E3BE, OHM/BEEP also no overload), and a range change in auto-hold sets the reference to 0 (`autorange_step` 0x0800E244), so 0 ohm / 0 V were never captured | production only: in OHM and DIODE an overload is "no signal" (reference 1000000, as v2.05 for an OHM overload), a reading below 1000 counts is a signal at range 0 or in manual range (not while the auto-ranging still steps down), a range change sets the reference to 1000000; other modes unchanged (`func/hold.s`, `ar/autorange.s`) | approved (owner, 2026-11-03) | FUNC, AR |
| IMP-23 | DCV averaging | means of non-overlapping blocks of 16 AD1 samples (`ad1_accumulate_average` 0x08006342): one value per 16 samples, and a block that a step falls into shows a mixed value | production only, DCV outside calibration mode: the mean of the last 16 samples published every 8 samples, the window restarted when a sample is more than 8192 codes (about 98 counts) from the running half block and a second one confirms the new level, the first value after a step from 4 new samples, the first sample of a half block compared with the previous half block, a mean published while the settle count runs (discarded) not kept as the previous half block, so no displayed window contains a settling sample (`mdc/dcvavg.s`); the settle count of a range change doubled so the discarded time stays v2.05's (`ar_apply`).  Emulator: 19.8 against 9.8 display changes per second, no straddled value (v0.9.4: 6 in 12 steps), displayed noise 1.99 against 2.07 counts at 8 counts per sample, first value after a range change at the same time | approved (owner, 2026-11-03) | MDC, AR |
| IMP-24 | current-loop percent of DCmA | DCmA shows the current only | production only: SETUP page LP (item 37, DCmA only): off / 4..20 mA / 0..20 mA; the main display shows the percent of the span with 0.01 % and the % sign (`set/lp.s`, `ui/loop.s`, mask shared with IMP-11); EEPROM 0x028 | approved (owner, 2026-11-03: forum request) | SET, UI |
| IMP-25 | platinum RTD temperature in OHM | OHM shows the resistance only | production only: SETUP page Pt (item 38, OHM only): off / Pt100 / Pt1000; the main display shows the IEC 60751 temperature with 0.1 degree and the degC / degF sign of TEMP, table of R / R0 every 5 degC with linear interpolation (`set/rtd.s`, `ui/rtd.s`, `mtmp/rtd_table.s` from `tools/gen_rtd_table.py`, mask shared with IMP-11); REL subtracts the lead resistance; EEPROM 0x029 | approved (owner, 2026-11-03: forum request) | SET, UI, MTMP |
| IMP-26 | thermocouple types N, R, S | types K, J, T (IMP-10) | production only: the SETUP page tc also offers N, R and S (codes 3..5); NIST ITS-90 tables of the IMP-10 shape (`mtmp/tc_tables.s` from `tools/gen_tc_tables.py`; R and S start at -50 degC, entries 0..15 are search sentinels), windows N -200..1300, R and S -50..1760 degC (`mtmp/tctype.s`) | approved (owner, 2026-11-03: forum request) | MTMP, SET |
| IMP-27 | battery voltage trim | battery value from the nominal divider (OF-52), not editable | production only: the battery page (item 1) edits a trim t = -50..+50 (0.2 % steps); `pwr_bat_trim` scales the filtered value by (1000 + 2 t) / 1000 before the low-battery limit and the page (`set/btrim.s`, `pwr/battery.s`); EEPROM 0x02A = t + 100 | approved (owner, 2026-11-03: GitHub issue 2) | SET, PWR |
| IMP-28 | firmware file over Bluetooth to the SD card | an update needs the card in a computer | production only: SETUP page Ld (item 39, after bt) owns the Bluetooth link: packets with CRC-16, answered one by one, collected in log_buf (8 KiB) and appended to BTLOAD.TMP; at the end length, CRC-32 and image header are checked, then the file is copied to EEVBlog.bin and read back, BTLOAD.TMP is deleted, and an EEVBlog.bin whose copy failed in every attempt is deleted (`ble/bft.s`; hooks in `ble/usart.s`, `sys/main.s`, `set/setup.s`); sender `emulator/tools/bt_upload.py`; flash and EEPROM untouched | approved (owner, 2026-11-03) | BLE, SET |
| IMP-29 | FatFs R0.16 with patches 1 and 2 | FatFs R0.08a (2010) with the error-path fixes of OF-64; no f_unlink, f_rename, f_getfree | production only: the R0.16 functions used by the firmware translated by hand (`src/ff16/`, section 7A); the R0.08a entry points `fat_f_*` keep their arguments (`ff16/ff16_api.s`); FIL and DIR objects in `.bss_port`, the FATFS work area stays at 0x20006830; checked against ChaN's C by the differential harness (same results and images) | approved (owner, 2026-11-04) | SD, LOG, CAL, BLE |
| IMP-30 | firmware version over Bluetooth | the status frame carries no version | production only: a key frame with the unused code 0x90 (`F4 39 30 39 30`) is echoed as every key frame and answered with `F6 c0 c1 c2 c3 c4 x` (FW_VER_C0..C4 of config.inc, x = XOR of the six bytes before it), queued after the echo; 0x90 is not handed to the key routine (`ble/commands.s` fn_0800C332, `ble_version_frame`); test `emulator/scripts/test_ble_version.py`; for the companion program (FEATURES.md 2.11 stage 3) | approved (owner, 2026-11-04) | BLE |
| IMP-31 | set-clock frame applied every time | v2.05 applies only the first set-clock frame after the Bluetooth toggle (0x20008033 tested at 0x0800C3DC..0x0800C3E4) | production only: every `F8` frame with a valid checksum is echoed and written to the clock chip (`ble/commands.s` fn_0800C332; the flag is still written); test `emulator/scripts/test_ble_clock.py`; for the companion's time sync (FEATURES.md 2.11 stage 5) | approved (owner, 2026-11-04) | BLE |

Each deviation gets entries in `firmware/deviations.txt` and at least one scenario showing v2.05 and port behaviour.

---

## 11. Optimisation table (becomes `firmware/OPTIMIZATIONS.md` when implemented)

Only changes that leave LCD, keys, buzzer, backlight, SD files, BLE/USART protocol, EEPROM contents, HY3131
configuration sequence and user-visible timing identical, or improve them without changing meaning.

| ID | Optimisation | Why it is invisible or an improvement | Verified by |
|---|---|---|---|
| OPT-01 | RAM init by plain copy instead of lz77 | identical RAM content at `main` entry (6.27) | build check |
| OPT-02 | RMS square root and average removed (with OF-16) | no reader of the results | OF-16 evidence; spi stream |
| OPT-03 | NVM skips programming a byte that already holds the value | EEPROM content identical, fewer erase/write cycles (v2.05 setting saves rewrite unchanged bytes, EMAP 7.1) and fewer power-loss windows | streams `eeprom` and `eeprom_final` (`eeprom_store` differs and is not compared) |
| OPT-04 | one RT copy for all modules | code size | RT tests |
| OPT-06 | table lookups where v2.05 uses compare ladders (mode dispatch, INTE selection, rotary readers), tables equal to the ladders' cases | same result for every input; out-of-range inputs keep the v2.05 default branch | routine tests over the whole input range |
| OPT-07 | cal.bin read-back compared against the EEPROM directly | no 1200-byte stack buffer; same result | routine test of `calbin_load` |
| OPT-08 | calibration records read from the RAM cache | identical values (the cache is the EEPROM image, updated on every verified write); apply faster | routine tests of the loaders; scenarios |

New optimisations are added here before they are implemented; anything that changes an external stream is a deviation.

---

## 12. Risks and open questions

### 12.1 Risks and mitigations

| Risk | Effect | Mitigation |
|---|---|---|
| EEPROM corruption by a port bug | loss of calibration, serial, options | single NVM path, classes (IDENT separate), caller arming, re-check at the store, PELOCK outside the byte program, instruction-level build checks, emulator comparison, probe build |
| Power loss or low battery during an EEPROM byte write | BOR is off (supplied unit USER 0xF0) and the controller erases a non-zero word before writing it (RM0038 byte write, FTDW = 0); content after a loss in between is UNPROVEN; shared words put markers beside settings (0x01C..0x01F: buzzer and marker 0x1F; 0x000..0x003: date and serial MSB) | OPT-03 skips unchanged bytes (setting saves rewrite unchanged words in v2.05); NVM-2 switch (Q10); release note to save cal.bin before experiments |
| Brick | meter unusable | no statically addressed instruction can reach program flash or option bytes and FLASH-block addressing is restricted (8.2, 9.3; a pointer computed at run time cannot be excluded statically, see Q12); PELOCK at reset; bootloader path independent of the application; bounded waits |
| Hardware damage | destroyed parts | HY3131 table and shape checks, GPIO policy, power order, emulator safety monitor (4) |
| Float results differ from v2.05 | readings differ by counts | RT copies v2.05 algorithms; edge-class differential tests; routine tests of every chain |
| Timing differences | LCD/BLE/GPIO events shift | baseline mode with v2.05 loop structure, one-tick tolerance; same delay loop counts |
| Emulator fidelity (Cortex-M3 best-case cycle costs and the branch flash wait state, `emulator/emu/cycles.py`; data-load wait states, bus wait states and the upper ends of the cycle ranges not modelled, so emulated times are lower bounds; ideal keys) | bug invisible in the emulator | rules that do not depend on cycle timing (bounded waits, explicit order); hardware test plan before release (Q8); ARS 12 measurements before TP profiles |
| Unproven hardware facts (4 MHz crystal, PE9 role, NJM2870 start-up, MCU rail, pin-to-net by label position, PB7 rise time) | wrong safety margin | choices safe for every reading (HW-02, HW-03, NF-04); Q3, Q4 |
| SD/FAT reimplementation differs in command order | file-system divergence | v2.05 call order; sd_cmd/sd_block streams compared |
| Interface drift between workers | link errors, wrong arguments | Appendix C names and signatures; `--no-undefined`; routine tests at module boundaries |
| ISR/main races | rare wrong state | ISR rules (3.4), NF-11 |
| Stack overflow | silent RAM corruption | canary, per-scenario depth, 3072-byte limit |
| Image size | must stay <= 0x5A000 | v2.05 is 144 616 bytes; build assertion |
| Bootloader erases before reading the file | a bad file leaves no application (recovery: a correct file) | release procedure: `make check` passed and SHA-256 recorded before copying to a card |

### 12.2 Decisions (2026-10-31; owner policy: fix every defect, safety first, technical calls by the project)

- Q1 (OF-07, BEEP): refused. BEEP writes 0x120, the record it loads, which is also OHM range 1; refusing keeps OHM
  range 1 from being recalibrated under BEEP's configuration. LowZ refused as before. Refusal beep, no write.
- Q2 (OF-08): a user-zero record is cleared only at the range-0 offset save of its own mode.
- Q3 (HW-03): extra HY bus delay after PE9 on wake = 0 (never earlier than v2.05); no start-up figure in the documents.
- Q4: keep v2.05's power order for PD1 / PE9 (no data justifies a change).
- Q5 (NF-09, NF-16): keep the refusals (identical to v2.05 where the path is unreachable).
- Q6 (OF-23): stop writing 0x12; 15 V is never applied without a key press (a remembered 15 V source switched onto a
  circuit on entering DIODE can damage the device under test). Byte 0x12 is left as found.
- Q7: verified new defects get OF numbers in `ORIGINAL_FIRMWARE_ISSUES.md`; NF-/HW-/NVM-/IMP-/OPT- entries keep their
  prefixes and the allowlist format accepts all prefixes.
- Q8: required before the image is flashed to a meter: full EEPROM dump 0x08080000..0x08082FFF and cal.bin save
  before flashing, first power-on on batteries (a current-limited bench supply in place of the batteries is optional), APO/wake test, EEPROM dump after and compared; the test
  procedure goes in `firmware/HARDWARE_TEST.md`: a concise checklist for the EEVblog hardware test on his own meter,
  written with the release, including the list of intended deviations.
- Q9: fix all three: NF-07 (`CAL_FIX_SETUP_FALLTHROUGH` = 1), NF-08 (`CAL_CANCEL_ON_MODE_CHANGE` = 1),
  NF-10 (`CAL_FIX_MARKER26_RAM` = 1).
- Q10 (NVM-2): EEPROM writes are refused while the low-battery flag is set (refusal beep). Reason: BOR is off and a
  byte write erases and rewrites its whole word, so a supply loss during the write could corrupt neighbouring
  calibration bytes.
- Q11 (NF-17): contrast 10 and 11 are accepted at boot (what the editor offers and saves).
- Verification of the NF items (2026-10-31): NF-07 is OF-37, NF-08 is OF-36, NF-17 is OF-38 in
  `ORIGINAL_FIRMWARE_ISSUES.md` (confirmed by execution). NF-10 is refuted: the only write of marker 0x26 / RAM flag
  0x20007FE0 (0x0800F8AE..0x0800F8B8) is in the AC gain completion FUN_0800F7B8, which never runs in mode 9; switch
  `CAL_FIX_MARKER26_RAM` is removed and that code is ported as in v2.05. BEEP calibration stays refused (OF-07).
- OF-52 (battery conversion, found 2026-10-31 after Phase 1): fix in PWR (`adc_ch5_process` / `fn_08013728`): battery =
  code x 3.3 / 4095 / (330/1330), low-battery threshold 4.1 V kept; implemented after Phase 2 so integration compares
  against an unchanged target, then allowlisted for the battery value and symbol streams. Implemented 2026-11-01 (both
  builds): `fn_08013728` returns (code x 1330 + 2047) / 4095 in 0.01 V; the v2.05 table stays in the generated
  `src/pwr/tables_v205.s` without a reader.
- OF-53 and OF-54 (HY3131 event service, found 2026-10-31; owner decision 2026-11-01), both builds: the INTF write after
  the event read clears only the flags that were read (0 for each flag seen set, 1 for the others; INTF bits clear only on
  a written 0, DS p19 10.2 (7)), so a flag raised between the read and the write stays pending; counter data and CTF belong
  to the same completed count (production reads INTF first and the counter block after it; the baseline keeps v2.05's
  burst from register 0 and reads the counter block 0x14..0x1D again when CTF is seen). Only register reads and writes of
  v2.05's kinds are used; the INTF acknowledge values are the one whitelist extension (4.1 item 4).
- OF-32 scope (owner decision 2026-11-01), production: FREQ, PULSE and DUTY with no signal are blank only until the first
  counter result or the first no-signal timeout (300 TIM2 ticks, v2.05 0x0802442E); after a timeout 0.000 is shown as in
  v2.05 (`ar_result_seen`, `ar_apply`, counter `ar_freq_tmo_count` incremented by the TIM2 handler).
- Hardware question for the EEVblog test (Q8): v2.05's SD write completion wait FUN_080232E0 (0x08023346: counter 1000,
  polls SDIO_STA.TXACT) times out after about 7 ms at 4 MHz and then skips CMD12. Whether TXACT stays set while the card
  holds D0 busy after a block is not stated in RM0038 (DPSM Busy state text; TXACT "asserted when it transmits data").
  If it does, slow cards (busy up to 250 ms allowed, SD physical layer 4.6.2.2) make the write fail; the emulator's SDIO
  model assumes it does. The port keeps the v2.05 loop until the hardware behaviour is known; HARDWARE_TEST.md asks for
  a logging test with a slow card.
- Q12: MPU guard added (switch `MPU_GUARD`). The emulator models the MPU (PM0056 4.2, `emulator/emu/scs.py`); the guard
  build boots and stray stores to program flash and the option bytes fault into `sys_fault_safe` with nothing written.
  Default 1: the STOP/wake scenario of both guard builds is identical to v2.05 with no safety violation (2026-11-01).
- Routine-level runner (9.4 level 2): `emulator/diff/routine.py`. Check tools: `firmware/tools/check_image.py`
  (items 1, 2, 5, plus lint items 6 and 7, stricter than item 2: every FLASH offset outside the allowed list and the
  FLASH bit-band alias are rejected), `check_hy.py` (needs a Python with capstone and unicorn: `make PYTHON=...`),
  `check_gpio.py` with `fe_levels.txt`.

---

## 13. Implementation order and parallel work plan

### 13.1 Workers

| Worker | Modules / items | v2.05 code bytes (Appendix A) |
|---|---|---|
| W1 Platform | SYS, BRD, PWR, BZB; `Makefile`, `link/121gw.ld`, `hw.inc`, `macros.inc`, `config.inc` | 11 246 |
| W2 Numerics | RT, FUNC | 7 010 |
| W3 Display | LCD, UI | 14 976 |
| W4 Control | KEY, DIAL, MODE, AR | 9 738 (Appendix A counts `autorange_step` and `FUN_0800E2A0` under MODE and `frequency_select_range` under MFRQ, i.e. in W5's figure, although AR (W4) ports it) |
| W5 Measurement A | HY, MDC, MRES, MFRQ, MTMP | 11 436 |
| W6 Measurement B | MAC, MVA | 16 160 |
| W7 Calibration | CAL (with BOOTWIN), NVM; `ram_v205.inc`, `tools/gen_ram_symbols.py`, `gen_nvm_allow.py`, `extract_tables.py` | 7 616 (the FLASH driver ported by NVM is counted under SYS, i.e. in W1's figure) |
| W8 Storage | LOG, SD | 26 528 |
| W9 Settings and link | SET, RTC, BLE | 14 512 |
| W10 Test infrastructure | `tools/check_image.py`, `check_hy.py`, `check_gpio.py`, `fe_levels.txt`; in `emulator/diff/`: the routine-level runner (9.4 level 2), the allowlist prefix extension (9.5, after Q7), the `hy3131_whitelist` generation run (`run.py --make-whitelist`; the safety monitor needs that file), scenarios for every deviation and for STOP/wake, EEPROM-robustness and probe runs | - |

### 13.2 Order

1. Phase 0, foundations (W1, W7, W10; complete deliverables, no partial images): build files, include files,
   `ram_v205.inc`, all v2.05 constant tables extracted into module source files with `TABLE_V205` marks, `nvm_allow`
   generator, all check tools, the routine runner and the whitelist file, `deviations.txt` entries for every deviation
   of section 10 with its streams and conditions. Exit: every tool runs on the v2.05 image and its inputs and gives
   the expected results (tables equal, 47 HY3131 pairs, allowed-byte table equals EMAP, v2.05 against itself gives zero
   divergences with the routine runner).
2. Phase 1, all modules in parallel (W1..W9) against Appendix C and `ram_v205.inc`, written for both loop modes; each
   worker prepares the routine-test inputs for its module. A second worker reviews each module against this document
   and the v2.05 listing before Phase 2 (critique).
3. Phase 2, integration of the baseline image: one build, `make check`, routine tests, all baseline scenarios, probe
   build, EEPROM robustness, STOP/wake; divergences fixed module by module, rerunning only affected tests; one final
   full run.
4. Phase 3, production image: IMP-01..IMP-06 enabled (TP profiles stay off until ARS 12 hardware measurements),
   production scenarios and allowlist; one full run; then the critique of the whole project.

### 13.3 Coupling rules

- A worker changes only files of its modules; shared include files change only through their owners (13.1), on request.
- Cross-module calls use only Appendix C names; a new cross-module routine is added to Appendix C.2 first.
- A module writes another module's v2.05 variable only where the v2.05 function it ports does (5.2).

---

## Appendix A. Every v2.05 function and its module

Method: every bytemap.txt line of type `code` (`analysis/decompile/bytemap.txt`), classified from its callers, callees,
RAM and MMIO accesses and the specifications; 800 functions (7 continuation chunks counted with their parent), 119 222
bytes. Format: module (worker; functions, bytes): start addresses, with the verified name where one exists.
Moves made by the design (section 6): AR takes `autorange_step` 0x0800DE24 and 0x0800E2A0 from MODE and
`frequency_select_range` 0x0800AC1C from MFRQ (6.12); NVM takes the EEPROM byte layer (0x08011F80..0x08012148,
0x080104F8, 0x08010504, 0x0801159C, 0x080115CC, 0x08011B40, 0x08011DCE, 0x08011E88, 0x08011F38) from CAL and the FLASH
driver (0x0801F9FC..0x0801FB60) from SYS (6.21); SD keeps `sdio_gpio_init`/`deinit` and configures the pins through
`brd_gpio_init`; BOOTWIN (`FUN_0800EA3A`) stays in CAL.

**SYS** (W1; 111 functions, 4754 bytes): 0800ED0C, 0801BE60, 0801BE76, 0801BF1A, 0801BF92 rcc_lsi_as_rtc_lcd_clock, 0801BFC6, 0801BFD2, 0801BFDE, 0801C486, 0801C4D4, 0801F9FC, 0801FA68, 0801FA8E, 0801FAA0, 0801FAEE, 0801FAFA, 0801FB00, 0801FB60, 0801FD1C, 0801FD7A, 0801FD8A, 0801FDCA, 0801FDE2, 0801FDEC rcc_lse_config, 0801FDFC, 0801FE06, 0801FE1E, 0801FE2A, 0801FF34, 0801FF70, 0801FF78, 0801FF80, 0801FF9E, 0801FFBC, 0801FFDA, 0801FFF8, 0802079C, 08020848, 0802086C, 08020876, 080208E0 nvic_set_vector_table, 08020908, 0802096C, 08020988, 0802099E, 0802427C NMI_Handler, 0802427E HardFault_Handler, 08024280 MemManage_Handler, 08024282 BusFault_Handler, 08024284 UsageFault_Handler, 08024286 SVC_Handler, 08024288 DebugMon_Handler, 0802428A PendSV_Handler, 0802428C IRQ28_Handler, 080248B0 SysTick_Handler, 08024B40 main, 08025F70 reset_preinit, 08025FC2, 080287C0 lz77_init, 08028CDC zero_init, 08028FE4 data_init, 0802910C cmain, 08029126 low_level_init, 0802912A exit, 08029130 exit, 0802913C semihosting_exit, 08029174 Reset_Handler, 0802919C c_startup, 08029298 IRQ0_Handler, 0802929C IRQ1_Handler, 080292A0 IRQ2_Handler, 080292A4 IRQ4_Handler, 080292A8 IRQ5_Handler, 080292AC IRQ11_Handler, 080292B0 IRQ12_Handler, 080292B4 IRQ13_Handler, 080292B8 IRQ14_Handler, 080292BC IRQ15_Handler, 080292C0 IRQ16_Handler, 080292C4 IRQ17_Handler, 080292C8 IRQ19_Handler, 080292CC IRQ20_Handler, 080292D0 IRQ21_Handler, 080292D4 IRQ22_Handler, 080292D8 IRQ24_Handler, 080292DC IRQ25_Handler, 080292E0 IRQ26_Handler, 080292E4 IRQ27_Handler, 080292E8 IRQ30_Handler, 080292EC IRQ31_Handler, 080292F0 IRQ32_Handler, 080292F4 IRQ33_Handler, 080292F8 IRQ34_Handler, 080292FC IRQ35_Handler, 08029300 IRQ36_Handler, 08029304 IRQ37_Handler, 08029308 IRQ39_Handler, 0802930C IRQ41_Handler, 08029310 IRQ42_Handler, 08029314 IRQ43_Handler, 08029318 IRQ44_Handler, 0802931C IRQ46_Handler, 08029320 IRQ47_Handler, 08029324 IRQ48_Handler, 08029328 IRQ49_Handler, 0802932C IRQ50_Handler, 08029330 IRQ51_Handler, 08029334 IRQ52_Handler, 08029338 IRQ54_Handler, 0802933C IRQ55_Handler, 08029340 IRQ56_Handler.

**BRD** (W1; 69 functions, 5272 bytes): 0800C28C sample_pf8_at_boot, 0800ECF6, 0800FBE8, 0800FC60, 0800FD30, 0800FD80, 0800FDB0, 0800FDD0, 0800FE00, 0800FE14, 0800FE74, 0801349C, 080137B4 adc_select_channel_4_or_5, 0801381E adc_ch4_average_10, 08013DD4, 0801BD48 gpio_init, 0801BDEC, 0801BE04 gpio_set_alternate_function, 0801C056 board_gpio_init, 0801C2C6 gpio_init_pg_inputs, 0801C368 gpio_init_pe10_pe11_inputs, 0801C43E gpio_init_analog, 0801C522, 0801C584 power_down_peripherals, 0801C61C, 0801C6F4, 0801C756, 0801C7AA, 0801C852, 0801C8EC, 0801C908, 0801C92E, 0801C97E, 0801C9A4, 0801C9AE, 0801C9D8, 0801CA0C, 0801CA22, 08020094, 080200B4, 08020104, 0802012C, 080202EA, 080202F4, 080202FA, 08020314, 08020348, 080207A4, 080207AC, 080207B4, 080207CC, 08020808, 08020822, 080209A8, 080209FC, 08020A46, 08020A74, 08020AC8, 08020B50, 08020B6A, 080248C8 IRQ3_Handler, 080248E8 IRQ6_Handler, 080248FC IRQ7_Handler, 08024910 IRQ8_Handler, 08024924 IRQ9_Handler, 08024938 IRQ10_Handler, 0802494C IRQ23_Handler, 080249A8 IRQ40_Handler, 08024A24 IRQ18_Handler.

**PWR** (W1; 6 functions, 848 bytes): 0800ED26, 080134DA adc_ch5_process, 080135B0, 0801368A, 08013728, 08024ECA enter_stop_and_reinit.

**BZB** (W1; 8 functions, 372 bytes): 0800EE50, 0800EE5E, 0800EE6C, 0800EE7A, 0800EEA8, 0800EED0 pe7_on_with_timeout, 08024722 IRQ29_Handler, 08024F06 pe7_on_blocking_100_ticks.

**RT** (W2; 38 functions, 4504 bytes): 08012F60, 08012F74, 08012F78, 08012F94, 08013090, 08013168, 080131B8, 080131CC, 080132A0, 080132CC, 080132EC, 080132FC, 08013370, 080133B4, 080133C4, 08013EC4, 08013ED8, 08013EDC, 08013EF4, 08013FE4, 08014028, 08014118, 08014140, 08014158, 0801B874, 0801BACC, 0801BB5C, 0801BB64, 0801BD08, 0801BD24, 0801FB9C, 0801FBB0, 0802035C, 08020390, 08023CA0, 08023EDC, 08023EE8, 08023F2C.

**FUNC** (W2; 13 functions, 2506 bytes): 08008344, 0800B754, 0800B888, 0800DCFC, 0800E278, 0800E30C, 0800E594, 0800E604, 0800E758, 0801584C, 080158D4, 08015974, 0801A028.

**LCD** (W3; 61 functions, 11844 bytes): 08017100 lcd_show_value_pos5_9, 0801717E, 080172A8 lcd_set_mode_annunciators, 08017700, 080177AC, 080177F2, 08017858, 08017F28 lcd_show_value_pos0_4, 08017FB4, 08018B14, 08018B80 lcd_update_bargraph, 08018F14, 08018FA8 bargraph_count_from_value, 0801912C, 08019268, 080192FC, 08019364, 08019408, 08019AE0 lcd_draw_5char, 08019B12, 08019B24, 08019B48, 08019C5C, 08019CBC, 08019CF0, 08019D2C, 08019D68, 08019E24, 08019F2E, 08019FA2, 0801A07C, 0801A110, 0801A17C, 0801A32A, 0801A370, 0801A3A4, 0801A440, 0801A6D8, 0801A760, 0801A81C, 0801A89C, 0801A950 lcd_draw_glyph, 0801AFFC, 0801B090, 0801B130, 0801B304 lcd_commit_shadow, 0801B396 lcd_commit_shadow_partial, 0801B450 lcd_init, 0801B4D6, 0801B708, 0801B77A, 080203B4, 080203FA, 08020402, 0802041E, 08020426, 0802043E, 08020456, 08020472, 0802048A, 08020492.

**UI** (W3; 33 functions, 3132 bytes): 0800D664, 0800D6E0, 0800E848, 0800EA24, 080153AC, 08015934, 08016D34, 08016E08, 08017092, 080170AC, 080171FA, 08017222, 0801725E, 0801772E, 0801776E, 08019698, 08019738, 08019792, 080197B6, 080197E0, 08019808, 0801982C, 08019854, 08019880, 080198B0, 080198FC, 08019948, 080199B4, 08019A22, 08019A74, 08019A86, 08019A98, 0801A854.

**KEY** (W4; 11 functions, 4046 bytes): 08014AE6, 08014C3C handle_pg8_15_short_press, 0801622C handle_pg8_15_long_press, 0801680C, 0801682C, 0801688C process_pg8_15_press_release, 08016A64, 08016B4C, 08016B7C, 08016BB8, 08016BCA sample_pg8_15.

**DIAL** (W4; 7 functions, 1314 bytes): 0801417C sense_pe10_pe11, 080143E4, 080143EE, 08014948, 08014954, 0801496E debounce_pg0_7_onehot, 08014A14 sample_pg0_7.

**MODE** (W4; 15 functions, 4378 bytes): 08006774, 080080C8, 0800D2D0 meter_apply_mode_range, 0800D5F4 load_full_scale, 0800D80C, 0800D81E, 0800D920 decimal_position_for_mode_range, 0800DB48, 0800DE24 autorange_step, 0800E2A0, 08014500 cycle_mode_on_bit0, 08014708, 0801472C, 08014796, 08019DA2.

**HY** (W5; 12 functions, 2554 bytes): 08006124 hy3131_poll, 0800614E hy3131_service_irq, 080061E4 ad1_ready_dispatch, 0800B974, 0800B994 hy3131_load_config_regs, 0800BEAC hy3131_set_irq_enable, 0800BF8C hy3131_counter_restart, 0800C03C hy3131_write_regs, 0800C0C0 hy3131_read_regs_to_rxbuf, 0800C138 hy3131_spi_read_byte, 0800C16C hy3131_spi_write_byte, 0800C1BC hy3131_spi_clock_pulse.

**MDC** (W5; 14 functions, 1782 bytes): 080062F8, 08006342 ad1_accumulate_average, 08006418, 080064D6, 08007714, 080077F0, 08007FA8, 08008138, 0800EEF0, 0800F2FC, 0800F368 cal_subtract_offset_clamp, 0800F37E, 0800F3B8 cal_divide_by_gain, 0800F648.

**MRES** (W5; 14 functions, 2816 bytes): 08006540, 08006558, 0800662C, 080078B8, 080078D8, 08007940, 080079C4, 08007B70, 08007D1E, 08007E84, 0800B33C, 0800B540, 0800EC28, 080159C8.

**MFRQ** (W5; 13 functions, 2702 bytes): 0800AA00, 0800AB48 counter_parse_and_restart, 0800AC1C frequency_select_range, 0800AEE8, 0800B070, 0800B244, 0800B2D8, 0800B610 counter_compute_frequency, 0800B67C, 0800B6D4, 0800B6F0, 0800ED64, 08012F28.

**MTMP** (W5; 7 functions, 1582 bytes): 08007840, 0801385A adc_ch4_process, 08013AAC, 08013B76, 08013C40, 08013CF8, 08018AD8.

**MAC** (W6; 27 functions, 7698 bytes): 0800664A, 080067D6, 0800699A, 080069B4, 08006A9E, 08006AEC, 08006C7A, 08006D40, 080070CC, 0800742C, 080075FA, 080076BC, 08008208, 0800827C, 080082D4, 08008468, 0800A5B2, 0800A5BA, 0800A5BC, 0800A608, 0800A6A8, 0800A74C, 0800A7F8, 0800A7FA, 0800A7FC, 080124F4, 080129EE.

**MVA** (W6; 16 functions, 8462 bytes): 080084E0, 080087F8, 08008B8C, 08008ED0, 08009364, 0800A260, 0800A358, 0800A4AC, 0800A560, 0800D8C2, 08011448 current_extra_load, 080114BC current_extra_store, 0801150E current_extra_erase_all, 0801154E current_extra_offset, 0801485A, 080148F6.

**CAL** (W7; 56 functions, 7616 bytes): 08007532, 0800EA3A, 0800EF44, 0800F034, 0800F0AC, 0800F13C, 0800F470, 0800F6C0, 0800F7B8, 0800F8E4, 0800F9F0, 0800FB1E, 0800FB38, 0800FB58, 0800FB78, 0800FB98, 0800FBB8, 080104BC, 080104D4, 080104F8 eeprom_read_u8_wrapper, 08010504 eeprom_write_u8_wrapper, 08010F10, 08010F28, 08010F4C, 08010F74, 08010F8C, 08010FB8, 0801159C, 080115CC, 0801167C load_cal_record_from_eeprom, 08011924, 08011950 cal_record_load_va, 080119F4, 08011AA4, 08011B40 cal_record_write, 08011DCE, 08011E88, 08011F38, 08011F80 eeprom_read_u32_be, 08011FD4, 08012000 eeprom_read_u16_be, 0801203A eeprom_read_u8, 0801204C eeprom_read_byte, 08012068 eeprom_write_u32_be, 080120A8 eeprom_write_u16_be, 080120D0 eeprom_write_u8, 080120F0 eeprom_program_byte, 08012148 eeprom_write_byte_retry, 08015728, 08015768, 080157E8, 0801CD14 calbin_save, 0801CF06 calbin_load, 0801D0D6, 0801FA1C, 0801FA2E.

**LOG** (W8; 55 functions, 12726 bytes): 08010516 log_compose_mode_range, 08010908, 080109EA, 08010AF8, 08010B64, 08010BCA, 08010BE8, 08010C34, 08010C8C, 08010CCC, 08010CE2, 08010CFC, 08010D92, 08010DE0, 08010E98, 08010EF4, 08010F02, 0801217C, 08012260, 0801657C, 0801D126, 0801D1A8, 0801D37C, 0801D48C, 0801D51A, 0801D53A, 0801D5B0, 0801D640, 0801D79C, 0801D838, 0801D8FC, 0801D9AC, 0801DA40, 0801DAB2, 0801DB34, 0801DB64, 0801DBF0, 0801E018, 0801E048, 0801E076, 0801E330, 0801E3D8, 0801E43C, 0801E4D2, 0801E512, 0801E564, 0801E7A8, 0801E7FA, 0801E82E log_write_csv_token, 0801F4B8, 0801F558, 0801F604, 0801F6B4, 0801F7AC, 0801F7E0.

**SD** (W8; 94 functions, 13802 bytes): 0801E010, 0801F84C, 0801F87E, 0801F8BA, 08020B84, 08020BA0, 08020BB6, 08020BDA, 08020BEE, 08020C66, 08020D3E, 08020D58, 08020E3A, 08020F7C, 08020FEE, 080210CA, 08021180, 080212B2, 0802131A, 0802137E, 08021400, 0802156E, 08021612, 080216B2, 0802172C, 08021B50, 08021B80, 08021BCC, 08021D72, 08021F60, 08022188, 0802224C, 08022268, 0802242C, 080224B6, 08022526, 0802256E, 080225D8, 0802268A, 080226AC, 080226D6, 080226E6, 08022932, 08022942, 08022AE4, 08022ECE sd_set_bus_width, 08022F96, 08022FCE, 08023100, 080232E0, 080233BE, 08023408, 08023476, 08023524, 08023558, 080235A4, 0802361C, 08023752, 080237AA, 0802381C, 080238F0, 08023A8C, 08023CD8 sdio_gpio_deinit, 08023D56 sdio_gpio_init, 08023DE8, 08023E58, 08023F5C, 08023F6E, 08023F7E, 08023FB8, 0802402E, 08024038, 08024074, 0802408C, 080240B6, 080240BE, 080240C4, 080240CE, 080240D6, 080240FE, 08024106, 0802411C, 0802414A, 08024150, 0802416E, 08024188, 0802418E, 080241A8, 080241F0, 0802422E, 0802424A, 08024260, 080248B8 IRQ45_Handler, 080248C0 IRQ53_Handler.

**SET** (W9; 60 functions, 7642 bytes): 0800D190, 0800D718, 08010FF0, 08011020, 08011046, 0801106C, 08011098, 080110B8, 080110E4, 08011118, 08011154 rotary_memory_store, 08011218, 08011248, 08011258, 08011294, 080112A4, 080112EC, 080112FC, 08011330, 08011340, 08011384, 08011394, 080113CC, 080113DC, 08011400, 08011410, 08011438, 08015410, 08015A22, 08015A74, 08015AC0, 08015B54, 08015BE0, 08015C20, 08015F7C, 080160E8, 08016190, 080165F4, 0801797C, 08017F94, 0801801E, 0801803C, 080180AA, 08018102, 0801813A, 080181B6, 08018228, 08018356, 0801839A, 08018410, 08018460, 08018490, 080184D4, 08018590, 080186AC, 080186E0, 0801871C, 080189B0, 08018A00, 08024DE0.

**RTC** (W9; 24 functions, 2356 bytes): 0800FF18, 080100C4, 08010118, 0801013E, 0801016C, 080101AC rtc_write_reg, 080101E2 rtc_read_reg, 08010204, 08010254 rtc_read_byte, 080102B8, 08010308 rtc_ce_high, 0801031E rtc_ce_low, 0801033C rtc_data_pin_output, 08010378 rtc_data_pin_input_pullup, 080103A8, 080103D8, 08015C94, 08015D40, 08015E74, 08015F44, 08018788, 080187D8, 080188A0, 0801896C.

**BLE** (W9; 36 functions, 4514 bytes): 0800C308, 0800C332, 0800C470, 0800C51A, 0800C53A, 0800C5D2, 0800C5DA build_status_packet_19b, 0800C99E, 0800C9FC, 0800CA2A, 0800CA64, 0800CA96, 0800CAC4, 0800CB04, 0800CB44, 0800CCC8, 0800CE28, 0800CE32, 0800CE78, 0800CEFC, 0800CFB0, 0800D07C, 0800D0C8, 0800D100, 0800D170, 0801C390 usart2_init_19200_pf15_high, 0801C954 usart2_deinit_pf15_low, 0801CAEC, 0801CBDC, 0801CBF8, 0801CC00, 0801CC08, 0801CC5E, 0801CC7C, 0801CCEC, 080247D8 IRQ38_Handler.


## Appendix B. v2.05 RAM base addresses by primary module

Method: every literal-pool word in the 0x2000xxxx range loaded by an `ldr` in the listing (660 distinct addresses), assigned to the module whose functions load it most often (ties: the lower-level module in the order of Appendix A). `*` = also referenced by functions of another module. Addresses are base addresses as loaded; a variable may extend beyond its base (structures, buffers). Fixed owners that override this count are listed in 5.2.

**SYS** (34): 2000020C, 20000218, 20000230*, 20007D0C, 20007D10, 20007F00, 20007F04, 20007F08, 20007FA8*, 20007FAA*, 20007FC0*, 20007FC4*, 20007FDE, 20007FE2*, 20007FFA*, 2000802B*, 2000802C, 20008031*, 20008036*, 2000803A*, 20008054*, 2000806F*, 20008077, 200080B2*, 200080B4*, 200080D0*, 200080D1, 200080D2, 200080D3, 200080D4*, 200080D5*, 200080E6*, 200080E8*, 200080E9*.

**BRD** (2): 20007FD2*, 20008086.

**PWR** (7): 200076F0, 20007740, 20007FBA*, 20007FBC, 20007FDC, 20008038*, 200080F9.

**BZB** (5): 20007FB4, 20007FB6, 20008079, 2000807A, 200080CF.

**RT** (1): 20000228.

**FUNC** (36): 200070A8, 20007238, 20007CD8, 20007D6C*, 20007D88, 20007D8C, 20007D90, 20007D94, 20007D98, 20007D9C*, 20007DA0*, 20007DA4, 20007DA8*, 20007DAC*, 20007DF8, 20007E70, 20007E74, 20007E78, 20007FB2*, 20008046*, 20008048*, 20008049*, 2000804E*, 2000804F*, 20008051*, 20008052*, 20008053*, 20008055*, 20008056*, 20008057, 20008058*, 20008059*, 2000805A*, 2000805C*, 20008084, 20008085.

**LCD** (16): 20007790*, 20007D70*, 20007DB0*, 20007DB4*, 20007DB8*, 20007DBC*, 20007DC0*, 20007FE1*, 20007FE3*, 20007FE4*, 20008041*, 2000804D*, 200080B1*, 200080B7*, 200080B8*, 200080E7*.

**UI** (19): 20000236, 20007FD8, 20007FE6*, 20007FEB*, 20007FEC*, 20007FED, 2000803F*, 2000805F*, 20008060*, 20008061*, 20008063*, 20008076*, 20008090*, 20008091, 20008092, 20008093, 20008094, 20008099*, 200080C2*.

**KEY** (32): 2000022E*, 20007E0C*, 20007E8C*, 20007E90*, 20007FA2*, 20007FB8, 2000801D*, 20008033*, 20008044*, 2000804A*, 20008067, 20008068, 20008069*, 2000806A, 2000806B, 2000806C, 2000806D*, 20008072*, 20008073*, 2000807B, 20008088*, 20008089*, 20008096*, 200080CD*, 200080CE*, 200080ED, 200080EE, 200080EF, 200080F0, 200080F1, 200080F2, 200080F3.

**DIAL** (10): 2000023B, 2000023C, 20008064, 20008065*, 20008066*, 20008075, 200080CC*, 200080EA, 200080EB, 200080EC.

**MODE** (24): 20000000, 20000238*, 20007D60*, 20007E60*, 20007E64*, 20007E9C*, 20007EA0*, 20007FC2*, 20008035*, 20008042*, 2000804B*, 20008050*, 20008074, 20008080*, 2000809A, 200080A0*, 200080A1*, 200080A2*, 200080AD*, 200080BB*, 200080BC*, 200080C8*, 200080C9, 200080F8.

**HY** (8): 200077D0*, 20007DC4, 20007DCC, 20007FE0*, 2000807D, 2000807E*, 2000807F, 200080BD*.

**MDC** (6): 20007DC8, 20007DD0, 20007E6C*, 20008081*, 200080A7*, 200080C4*.

**MRES** (16): 20000239*, 2000023A, 20007CC0, 20007CC4, 20007CC8, 20007CCC, 20007CD0, 20007CD4, 20007D08, 20007FC6*, 20007FC8, 2000807C, 20008098*, 200080A3*, 200080A4*, 200080B5.

**MFRQ** (12): 2000001C*, 20007C40, 20007C48, 20007E18*, 20007E34, 20007E38, 20007E3C, 20007E40*, 20007E44*, 20007E48, 20008045*, 2000809B.

**MTMP** (15): 20007BA8, 20007E7C, 20007E80, 20007E84, 20007E88, 20007FCC*, 20007FCE, 20007FD0, 20007FD4, 20007FD6, 20008097*, 200080AC, 200080AE*, 200080AF, 200080B0.

**MAC** (89): 20007C5C, 20007C60, 20007C64, 20007C68, 20007C6C, 20007C70, 20007C74, 20007C78, 20007C7C, 20007C80, 20007C84, 20007C88, 20007C8C, 20007C90, 20007C94, 20007C98, 20007C9C, 20007CA0, 20007CA4, 20007CA8, 20007CAC, 20007CB0, 20007CB4, 20007CB8, 20007CBC, 20007D64*, 20007D68*, 20007D74*, 20007D78, 20007D84*, 20007DD4*, 20007DD8, 20007DDC, 20007DE0, 20007DE4, 20007DE8, 20007DEC, 20007DF0, 20007DF4, 20007E08, 20007E5C, 20007E94*, 20007EA4, 20007EA8, 20007F0C, 20007F10, 20007F14, 20007F18, 20007F1C, 20007F20, 20007F24, 20007F28, 20007F2C, 20007F30, 20007F34, 20007F38, 20007F3C, 20007F40, 20007F44, 20007F48, 20007F4C, 20007F50, 20007F54, 20007F58, 20007F5C, 20007F60, 20007F64, 20007F68, 20007F6C, 20007F70, 20007F74, 20007F78, 20007F7C, 20007F80, 20007F84, 20007F88, 20007F8C, 20007F90, 20007F94, 2000803E*, 2000805D*, 2000805E*, 20008082, 20008083, 20008087*, 2000808C*, 2000808E*, 200080B9*, 200080BE*.

**MVA** (40): 20007C10, 20007C18, 20007C20, 20007C28, 20007CDC, 20007CE0, 20007CE4, 20007CE8, 20007CEC, 20007CF0, 20007CF4, 20007CF8, 20007CFC, 20007D00, 20007D04, 20007D7C*, 20007D80*, 20007E24*, 20007E28*, 20007E2C*, 20007E30*, 20007EAC*, 20007EB0*, 20007EB4*, 20007EB8, 20007EBC, 20007EC0, 20007EC4, 20007FDF*, 2000804C*, 2000808A*, 200080BF*, 200080C0*, 200080C1*, 200080C3, 200080C5*, 200080C6*, 200080C7*, 200080CA*, 200080CB*.

**CAL** (31): 20001240*, 20006830*, 20006EA8*, 20007C38, 20007D5C, 20007DFC, 20007E00*, 20007E04, 20007E10*, 20007E14*, 20007E1C, 20007E20*, 20007E4C*, 20007E50*, 20007E54*, 20007E58*, 20007E68*, 20007ED4*, 20007ED8*, 20007F9A*, 20007FBE*, 2000803C*, 2000803D*, 2000808D*, 2000808F*, 20008095*, 2000809C, 2000809D, 2000809E, 2000809F, 200080F5*.

**LOG** (194): 20000020, 20000024, 20000028, 20000030, 2000003C, 20000044, 20000050, 2000005C, 20000064, 2000006C, 20000078, 20000084, 20000090, 20000098, 200000A0, 200000AC, 200000B8, 200000C0, 200000C8, 200000D0, 200000D8, 200000E0, 200000E8, 200000F0, 200000F8, 20000100, 20000108, 20000110, 20000118, 20000120, 20000128, 20000130, 20000138, 20000140, 20000148, 2000014C, 20000154, 2000015C, 20000164, 2000016C, 20000174, 2000017C, 20000184, 2000018C, 20000194, 2000019C, 200001A0, 200001A4, 200001A8, 200001AC, 200001B0, 200001B4, 200001B8, 200001BC, 200001C4, 200001CC, 200001D0, 200001D8, 200001E0, 200001E8, 200001EC, 200001F0, 200001F8, 20000204, 20000232, 20000234, 20006A60*, 20006C84, 200073C8, 200074B8, 200075A8, 20007810, 2000784C, 20007888, 200078C4, 20007900, 2000793C, 20007978, 200079B4, 200079F0, 20007A2C, 20007A68, 20007AA4, 20007B1C, 20007B38, 20007BD0, 20007C57, 20007D1C*, 20007D20, 20007D24, 20007D28, 20007D2C, 20007D30, 20007D34, 20007D38*, 20007D3C, 20007D40, 20007D44, 20007D48, 20007D4C, 20007D50, 20007D54, 20007D58, 20007EC8, 20007ECC, 20007ED0, 20007EDC, 20007EE0, 20007EE4, 20007F9C*, 20007F9E*, 20007FA0, 20007FA4*, 20007FAC, 20007FAE, 20007FDA, 20007FE5*, 20007FE7*, 20007FE8*, 20007FE9*, 20007FEA, 20007FEE, 20007FEF, 20007FF0, 20007FF1, 20007FF2, 20007FF3, 20007FF4, 20007FF5, 20007FF6, 20007FF7, 20007FF8, 20007FF9, 20007FFB, 20007FFC, 20007FFD, 20007FFE, 20007FFF, 20008000, 20008001, 20008002, 20008003, 20008004, 20008005, 20008006, 20008007, 20008008, 20008009, 2000800A, 2000800B, 2000800C, 2000800D, 2000800E, 2000800F, 20008010, 20008011, 20008012, 20008013, 20008014, 20008015, 20008016, 20008017, 20008018, 20008019, 2000801A, 2000801B*, 2000801C*, 2000801E, 2000801F, 20008020, 20008021, 20008022, 20008023, 20008024, 20008025, 20008026, 20008027, 20008028, 20008029, 2000802A, 2000803B*, 20008043, 200080D7*, 200080D8*, 200080D9*, 200080DA*, 200080DB*, 200080DC*, 200080E2, 200080E3, 200080E4, 200080E5, 200080F4*, 200080F6.

**SD** (15): 20007698, 20007B50, 20007B68, 20007BBC, 20007BF0*, 20007C00, 20007C58, 20007EE8, 20007EEC, 20007EF0, 20007EF4, 20007EF8, 20007EFC, 20007F98, 200080F7.

**SET** (33): 2000022C*, 20000237*, 20007C30*, 20007D14*, 20007D18, 20007E98*, 20007FA6, 20007FCA*, 20008037*, 20008039*, 20008040*, 2000805B*, 20008062*, 2000806E*, 20008070*, 20008071*, 20008078*, 2000808B*, 200080A5*, 200080A6*, 200080A8*, 200080A9, 200080AA*, 200080AB*, 200080B3*, 200080B6*, 200080BA*, 200080D6*, 200080DD*, 200080DE*, 200080DF*, 200080E0*, 200080E1*.

**RTC** (1): 2000023D.

**BLE** (14): 20003950, 200048F0, 20005890, 20007AE0*, 20007B80, 20007B94, 20007FB0*, 2000802D, 2000802E, 2000802F, 20008030*, 20008032, 20008034, 20008047*.


## Appendix C. Cross-module interface routines

### C.1 Replaced v2.05 functions called across modules

Every v2.05 function called (bl/b) from a function of another module (296 routines). Format: v2.05 address, canonical port symbol, calling modules, register signature from `analysis/decompile/params.txt` (in = argument registers, out = result registers; no routine takes stack arguments). The port routine keeps this signature (section 6, conventions).

Exceptions decided by this design:
- `eeprom_write_u8`, `eeprom_write_u16_be`, `eeprom_write_u32_be` are internal to NVM; their v2.05 callers in SET, MVA
  and CAL call `nvm_write_setting`, `nvm_write_ident` or `nvm_write_userzero` (C.2) after `nvm_arm`.
- `hy3131_write_regs` is internal to HY; MAC calls `hy_peak_restart` (C.2).
- The FLASH driver routines `fn_0801F9FC` and `fn_0801FB60` (listed under SYS, Appendix A) are internal to NVM (6.21).
- `current_extra_erase_all` is no longer called at calibration-mode entry (OF-08); CAL calls `current_extra_clear` (C.2).
- `autorange_step` belongs to AR (6.12), although the table lists it under MODE, its Appendix A module.
- The NVM writers return a status in r0 (C.2).


**BLE (6)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800C332 | `fn_0800C332` | SYS | - | - |
| 0800C51A | `fn_0800C51A` | KEY | - | - |
| 0800C5D2 | `fn_0800C5D2` | SYS | - | - |
| 0800D170 | `fn_0800D170` | SYS | r0, r1 | - |
| 0801C954 | `usart2_deinit_pf15_low` | BRD | - | - |
| 0801CC08 | `fn_0801CC08` | SYS | r0, r1, r2 | - |

**BRD (24)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800C28C | `sample_pf8_at_boot` | SYS | - | - |
| 0800ECF6 | `fn_0800ECF6` | CAL, HY, MAC, RTC | r0 | - |
| 0800FBE8 | `fn_0800FBE8` | MODE | r0, r1 | - |
| 0800FD30 | `fn_0800FD30` | CAL, MRES | r0 | - |
| 0800FD80 | `fn_0800FD80` | CAL | r0 | - |
| 0800FDB0 | `fn_0800FDB0` | CAL | r0 | - |
| 0800FDD0 | `fn_0800FDD0` | CAL | r0 | - |
| 0800FE00 | `fn_0800FE00` | CAL | - | - |
| 0800FE14 | `fn_0800FE14` | CAL | r0 | - |
| 0800FE74 | `fn_0800FE74` | CAL, MVA | r0, r1 | - |
| 0801349C | `fn_0801349C` | SYS | - | - |
| 080137B4 | `adc_select_channel_4_or_5` | PWR | r0 | r0 |
| 08013DD4 | `fn_08013DD4` | SYS | - | - |
| 0801BD48 | `gpio_init` | BLE, LCD, RTC, SD | r0, r1 | - |
| 0801BDEC | `fn_0801BDEC` | LCD | r0 | - |
| 0801BE04 | `gpio_set_alternate_function` | BLE, LCD, SD | r0, r1, r2 | - |
| 0801C056 | `board_gpio_init` | SYS | - | - |
| 0801C43E | `gpio_init_analog` | SYS | - | - |
| 0801C522 | `fn_0801C522` | PWR | - | - |
| 0801C97E | `fn_0801C97E` | PWR | - | - |
| 080207B4 | `fn_080207B4` | SYS | r0 | - |
| 080207CC | `fn_080207CC` | PWR | r0, r1 | - |
| 08020808 | `fn_08020808` | SYS | r0 | r0 |
| 08020822 | `fn_08020822` | SYS | r0 | - |

**BZB (6)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800EE50 | `fn_0800EE50` | CAL, KEY, MODE | - | - |
| 0800EE5E | `fn_0800EE5E` | KEY, LOG | - | - |
| 0800EE6C | `fn_0800EE6C` | KEY, MODE, MRES | - | - |
| 0800EEA8 | `fn_0800EEA8` | MODE | r0 | - |
| 0800EED0 | `pe7_on_with_timeout` | FUNC, MRES, SYS | r0 | - |
| 08024F06 | `pe7_on_blocking_100_ticks` | PWR | - | - |

**CAL (26)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08007532 | `fn_08007532` | MAC | - | - |
| 0800EA3A | `fn_0800EA3A` | PWR, SYS | - | - |
| 0800EF44 | `fn_0800EF44` | MDC | r0 | r0 |
| 0800F034 | `fn_0800F034` | MRES | r0 | r0 |
| 0800F0AC | `fn_0800F0AC` | MAC | r0 | r0 |
| 0800F470 | `fn_0800F470` | MDC, MRES | r0 | r0 |
| 0800F6C0 | `fn_0800F6C0` | MRES | r0, r1 | - |
| 0800F7B8 | `fn_0800F7B8` | MAC | r0, r1 | - |
| 0800F9F0 | `fn_0800F9F0` | MVA | r0 | - |
| 080104BC | `fn_080104BC` | SET | - | r0 |
| 08010F10 | `fn_08010F10` | SET | - | r0 |
| 08010F4C | `fn_08010F4C` | SET | - | - |
| 08010F74 | `fn_08010F74` | RTC | - | - |
| 08010F8C | `fn_08010F8C` | SET | - | - |
| 08010FB8 | `fn_08010FB8` | SET | - | - |
| 0801167C | `load_cal_record_from_eeprom` | MAC, MODE, SET | r0, r1 | - |
| 08011AA4 | `fn_08011AA4` | MODE | - | - |
| 08011B40 | `cal_record_write` | MFRQ, MTMP, MVA | r0, r1 | - |
| 08011F80 | `eeprom_read_u32_be` | MVA | r0 | r0 |
| 08012000 | `eeprom_read_u16_be` | SET | r0 | r0 |
| 0801203A | `eeprom_read_u8` | MVA, SET | r0 | r0 |
| 08012068 | `eeprom_write_u32_be` | MVA | r0, r1 | - |
| 080120A8 | `eeprom_write_u16_be` | SET | r0, r1 | - |
| 080120D0 | `eeprom_write_u8` | MVA, SET | r0, r1 | - |
| 08015728 | `fn_08015728` | KEY | r0 | r0 |
| 08015768 | `fn_08015768` | KEY | r0 | r0 |

**DIAL (2)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0801417C | `sense_pe10_pe11` | SYS | - | - |
| 08014948 | `fn_08014948` | SYS | - | - |

**FUNC (8)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08008344 | `fn_08008344` | MAC | r0, r1, r2 | r0 |
| 0800B754 | `fn_0800B754` | MAC, MDC, MRES | r0, r1, r2 | r0 |
| 0800B888 | `fn_0800B888` | MAC, MDC | r0 | r0 |
| 0800DCFC | `fn_0800DCFC` | SYS | - | - |
| 0800E758 | `fn_0800E758` | UI | r0 | r0 |
| 0801584C | `fn_0801584C` | KEY, LOG | r0, r1 | - |
| 080158D4 | `fn_080158D4` | KEY | - | - |
| 0801A028 | `fn_0801A028` | BLE, LCD | - | r0 |

**HY (4)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08006124 | `hy3131_poll` | SYS | - | - |
| 0800B974 | `fn_0800B974` | CAL, MAC, MFRQ, MODE | r0, r1 | - |
| 0800BF8C | `hy3131_counter_restart` | MFRQ | - | - |
| 0800C03C | `hy3131_write_regs` | MAC | r0, r1, r2 | - |

**KEY (2)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0801680C | `fn_0801680C` | CAL, SYS | - | - |
| 08016B7C | `fn_08016B7C` | DIAL | r0 | r0 |

**LCD (41)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08017100 | `lcd_show_value_pos5_9` | KEY, UI | r1, r2, r3 | - |
| 0801717E | `fn_0801717E` | UI | r0 | - |
| 080172A8 | `lcd_set_mode_annunciators` | UI | r0, r1, r2, r3 | - |
| 08017700 | `fn_08017700` | MVA | r0, r1 | - |
| 080177AC | `fn_080177AC` | UI | r0 | - |
| 080177F2 | `fn_080177F2` | UI | r0 | - |
| 08017858 | `fn_08017858` | UI | r0 | - |
| 08017F28 | `lcd_show_value_pos0_4` | SET, UI | r0, r1, r2 | - |
| 08017FB4 | `fn_08017FB4` | KEY, MVA, RTC, SET, UI | r0 | - |
| 08018B14 | `fn_08018B14` | UI | - | - |
| 080192FC | `fn_080192FC` | UI | - | - |
| 08019364 | `fn_08019364` | UI | - | - |
| 08019AE0 | `lcd_draw_5char` | RTC, SET, UI | r0, r1 | - |
| 08019B12 | `fn_08019B12` | SET | r0, r1 | - |
| 08019B24 | `fn_08019B24` | SET | r0, r1 | - |
| 08019B48 | `fn_08019B48` | UI | - | - |
| 08019C5C | `fn_08019C5C` | FUNC, KEY, LOG, SET, UI | r0 | - |
| 08019CBC | `fn_08019CBC` | SYS | - | - |
| 08019CF0 | `fn_08019CF0` | PWR, UI | r0 | - |
| 08019D2C | `fn_08019D2C` | BLE, UI | r0 | - |
| 08019D68 | `fn_08019D68` | FUNC, KEY, LOG, MODE, UI | r0 | - |
| 08019E24 | `fn_08019E24` | FUNC, KEY, UI | r0 | - |
| 08019F2E | `fn_08019F2E` | KEY, UI | r0 | - |
| 08019FA2 | `fn_08019FA2` | FUNC, KEY, UI | r0 | - |
| 0801A07C | `fn_0801A07C` | KEY, UI | r0 | - |
| 0801A110 | `fn_0801A110` | UI | - | - |
| 0801A17C | `fn_0801A17C` | UI | - | - |
| 0801A32A | `fn_0801A32A` | KEY, LOG, UI | r0 | - |
| 0801A370 | `fn_0801A370` | UI | - | - |
| 0801A3A4 | `fn_0801A3A4` | SET, UI | - | - |
| 0801A440 | `fn_0801A440` | MFRQ, UI | - | - |
| 0801A760 | `fn_0801A760` | MODE | - | - |
| 0801A81C | `fn_0801A81C` | BRD, CAL, UI | - | - |
| 0801A89C | `fn_0801A89C` | KEY | - | - |
| 0801B090 | `fn_0801B090` | BLE, LOG, RTC, SET, UI | r0 | - |
| 0801B130 | `fn_0801B130` | RTC, SET, UI | r0 | - |
| 0801B304 | `lcd_commit_shadow` | BRD, CAL, KEY, RTC, SET, UI | - | - |
| 0801B450 | `lcd_init` | PWR, SET, SYS | r0, r1 | - |
| 0801B77A | `fn_0801B77A` | SET | - | - |
| 080203FA | `fn_080203FA` | BRD | r0 | - |
| 08020492 | `fn_08020492` | BRD | r0 | r0 |

**LOG (12)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08010516 | `log_compose_mode_range` | SYS | - | - |
| 08010AF8 | `fn_08010AF8` | MODE | r0 | - |
| 08010B64 | `fn_08010B64` | SYS | - | - |
| 08010BE8 | `fn_08010BE8` | SET | - | - |
| 08010C8C | `fn_08010C8C` | UI | r0 | r0 |
| 08010CE2 | `fn_08010CE2` | KEY | - | - |
| 08010D92 | `fn_08010D92` | KEY | - | - |
| 08010E98 | `fn_08010E98` | KEY | - | - |
| 08010F02 | `fn_08010F02` | UI | r0 | - |
| 0801657C | `fn_0801657C` | KEY | r0 | - |
| 0801D126 | `fn_0801D126` | SYS | - | r0 |
| 0801D37C | `fn_0801D37C` | CAL | r0 | - |

**MAC (7)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800664A | `fn_0800664A` | HY | - | - |
| 080067D6 | `fn_080067D6` | MVA | - | - |
| 080069B4 | `fn_080069B4` | HY | - | - |
| 08006AEC | `fn_08006AEC` | HY, MRES, MVA | - | - |
| 08008208 | `fn_08008208` | HY | - | - |
| 0800A5BC | `fn_0800A5BC` | MDC | r0 | - |
| 0800A7FC | `fn_0800A7FC` | HY | - | - |

**MDC (10)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 080062F8 | `fn_080062F8` | HY | - | r0 |
| 08006342 | `ad1_accumulate_average` | HY | r0 | r0 |
| 08006418 | `fn_08006418` | MAC, MRES | - | - |
| 080064D6 | `fn_080064D6` | MRES | - | - |
| 08007714 | `fn_08007714` | HY, MRES, MVA | - | - |
| 080077F0 | `fn_080077F0` | HY, MTMP | - | - |
| 08007FA8 | `fn_08007FA8` | HY | - | - |
| 08008138 | `fn_08008138` | MVA | - | - |
| 0800F368 | `cal_subtract_offset_clamp` | MAC | r0 | r0 |
| 0800F3B8 | `cal_divide_by_gain` | MAC | r0 | r0 |

**MFRQ (3)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800AA00 | `fn_0800AA00` | HY | - | - |
| 0800ED64 | `fn_0800ED64` | SYS | - | - |
| 08012F28 | `fn_08012F28` | CAL, MAC | r0, r1 | r0 |

**MODE (12)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08006774 | `fn_08006774` | MAC, SET | r0 | - |
| 080080C8 | `fn_080080C8` | MDC, SET | r0 | - |
| 0800D2D0 | `meter_apply_mode_range` | DIAL, MRES, SYS | r0 | - |
| 0800D5F4 | `load_full_scale` | MRES | - | - |
| 0800D80C | `fn_0800D80C` | MVA | r0 | - |
| 0800D920 | `decimal_position_for_mode_range` | LOG, MFRQ, MRES, UI | r0, r1 | r0 |
| 0800DB48 | `fn_0800DB48` | MVA | - | - |
| 0800DE24 | `autorange_step` | FUNC | - | - |
| 08014500 | `cycle_mode_on_bit0` | KEY | - | - |
| 0801472C | `fn_0801472C` | SET | - | - |
| 08014796 | `fn_08014796` | KEY | - | - |
| 08019DA2 | `fn_08019DA2` | BLE, LCD | - | r0 |

**MRES (9)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08006540 | `fn_08006540` | HY | - | - |
| 08006558 | `fn_08006558` | SYS | - | - |
| 080078B8 | `fn_080078B8` | HY | - | - |
| 080079C4 | `fn_080079C4` | HY | - | - |
| 08007E84 | `fn_08007E84` | HY | - | - |
| 0800B33C | `fn_0800B33C` | MFRQ | - | - |
| 0800B540 | `fn_0800B540` | HY | - | - |
| 0800EC28 | `fn_0800EC28` | MODE | - | - |
| 080159C8 | `fn_080159C8` | KEY | - | - |

**MTMP (3)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08007840 | `fn_08007840` | HY | - | - |
| 0801385A | `adc_ch4_process` | BRD | r0 | - |
| 08018AD8 | `fn_08018AD8` | BLE, SET | r0 | r0 |

**MVA (8)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 080084E0 | `fn_080084E0` | HY | - | - |
| 080087F8 | `fn_080087F8` | MDC | r0, r1 | r0 |
| 08008B8C | `fn_08008B8C` | HY | - | - |
| 0800A560 | `fn_0800A560` | MODE | - | - |
| 08011448 | `current_extra_load` | MODE | r0, r1 | - |
| 080114BC | `current_extra_store` | KEY | r0, r1, r2 | - |
| 0801150E | `current_extra_erase_all` | CAL | - | - |
| 0801485A | `fn_0801485A` | KEY, MODE | r0, r1 | - |

**PWR (3)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800ED26 | `fn_0800ED26` | BZB, MODE, SET | - | - |
| 080134DA | `adc_ch5_process` | BRD | - | - |
| 08024ECA | `enter_stop_and_reinit` | SYS | - | - |

**RT (24)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 08012F60 | `fn_08012F60` | CAL, MAC, MDC, MRES, MTMP | r0 | r0 |
| 08012F74 | `fn_08012F74` | CAL, MRES, PWR | r0 | r0 |
| 08012F94 | `fn_08012F94` | CAL, MAC, MDC, MRES, MTMP, PWR | r0, r1 | r0 |
| 08013090 | `fn_08013090` | CAL, MAC, MRES, SET | r0, r1 | r0 |
| 08013168 | `fn_08013168` | CAL, MAC, MDC, MTMP | r0 | r0, r1 |
| 080131B8 | `fn_080131B8` | MAC, MDC | r0, r1, r2, r3 | r0, r1 |
| 080132A0 | `fn_080132A0` | CAL, MAC, MDC | r0, r1 | r0 |
| 080132EC | `fn_080132EC` | MAC, MRES, MTMP | r0, r1 | r0 |
| 08013370 | `fn_08013370` | CAL, MAC, MRES, MTMP, PWR | r0 | r0 |
| 080133B4 | `fn_080133B4` | MAC, MTMP | r0, r1 | r0 |
| 08013ED8 | `fn_08013ED8` | MAC | r0 | r0, r1 |
| 08013EF4 | `fn_08013EF4` | MAC | r0, r1 | r0, r1 |
| 08013FE4 | `fn_08013FE4` | CAL, FUNC, MVA | r0, r1, r2, r3 | r0, r1 |
| 08014028 | `fn_08014028` | MFRQ | r0, r1, r2, r3 | r0, r1 |
| 08014118 | `fn_08014118` | MVA | r0, r1 | r0 |
| 0801B874 | `fn_0801B874` | CAL, MAC | r0, r1, r2, r3 | r0, r1 |
| 0801BACC | `fn_0801BACC` | CAL, MAC, MTMP | r0, r1 | r0 |
| 0801BB5C | `fn_0801BB5C` | MAC | r0, r1 | r0, r1 |
| 0801BB64 | `fn_0801BB64` | MAC, MTMP | r0, r1, r2, r3 | r0, r1 |
| 0801BD08 | `fn_0801BD08` | MDC, MRES | r0, r1 | - |
| 0801BD24 | `fn_0801BD24` | MRES, SET | r0 | r0 |
| 0802035C | `fn_0802035C` | MTMP, SET | r0, r1 | - |
| 08020390 | `fn_08020390` | SET | r0, r1 | - |
| 08023CA0 | `fn_08023CA0` | LOG | r0 | r0 |

**RTC (10)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800FF18 | `fn_0800FF18` | SET, SYS | - | - |
| 080100C4 | `fn_080100C4` | SYS | - | - |
| 0801016C | `fn_0801016C` | BLE | - | - |
| 08015C94 | `fn_08015C94` | SET | r0 | - |
| 08015D40 | `fn_08015D40` | SET | r0 | - |
| 08015E74 | `fn_08015E74` | SET | r0 | - |
| 08018788 | `fn_08018788` | SET | r0, r1 | - |
| 080187D8 | `fn_080187D8` | SET | r0, r1, r2 | - |
| 080188A0 | `fn_080188A0` | SET | r0, r1, r2 | - |
| 0801896C | `fn_0801896C` | SYS | r0 | - |

**SD (13)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0801E010 | `fn_0801E010` | LOG | r0 | r0 |
| 0801F84C | `fn_0801F84C` | CAL, LOG | r0 | r0 |
| 08021B80 | `fn_08021B80` | CAL, LOG | r0, r1 | r0 |
| 08021BCC | `fn_08021BCC` | CAL, LOG | r0, r1, r2 | r0 |
| 08021D72 | `fn_08021D72` | CAL, LOG | r0, r1, r2, r3 | r0 |
| 08021F60 | `fn_08021F60` | CAL, LOG | r0, r1, r2, r3 | r0 |
| 0802224C | `fn_0802224C` | CAL, LOG | r0 | - |
| 08022268 | `fn_08022268` | LOG | r0, r1 | r0 |
| 0802242C | `fn_0802242C` | LOG | r0, r1 | r0 |
| 080224B6 | `fn_080224B6` | LOG | r0, r1 | r0 |
| 08022526 | `fn_08022526` | LOG | r0, r1 | r0 |
| 0802256E | `fn_0802256E` | LOG | r0, r1 | r0 |
| 08022932 | `fn_08022932` | CAL, LOG, SYS | - | - |

**SET (17)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800D190 | `fn_0800D190` | SYS | - | - |
| 0800D718 | `fn_0800D718` | LOG, MODE, UI | - | - |
| 08010FF0 | `fn_08010FF0` | DIAL | - | r0 |
| 08011020 | `fn_08011020` | DIAL | - | r0 |
| 08011046 | `fn_08011046` | DIAL | - | r0 |
| 0801106C | `fn_0801106C` | DIAL | - | r0 |
| 08011098 | `fn_08011098` | DIAL | - | r0 |
| 080110B8 | `fn_080110B8` | DIAL | - | r0 |
| 080110E4 | `fn_080110E4` | DIAL | - | r0 |
| 08011154 | `rotary_memory_store` | MODE | - | - |
| 08011384 | `fn_08011384` | MRES | r0 | - |
| 08015410 | `fn_08015410` | KEY | - | - |
| 080165F4 | `fn_080165F4` | KEY | r0 | r0 |
| 0801797C | `fn_0801797C` | UI | - | - |
| 0801801E | `fn_0801801E` | UI | - | - |
| 0801803C | `fn_0801803C` | UI | - | - |
| 08024DE0 | `fn_08024DE0` | PWR, SYS | - | - |

**SYS (22)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0801BE60 | `fn_0801BE60` | BLE | r0 | - |
| 0801BE76 | `fn_0801BE76` | PWR | - | - |
| 0801BF1A | `fn_0801BF1A` | CAL, LOG | r0 | - |
| 0801BFC6 | `fn_0801BFC6` | BRD, LCD | - | - |
| 0801BFD2 | `fn_0801BFD2` | BRD | - | - |
| 0801F9FC | `fn_0801F9FC` | CAL | - | - |
| 0801FB60 | `fn_0801FB60` | CAL | r0 | r0 |
| 0801FD1C | `fn_0801FD1C` | BRD | - | - |
| 0801FD7A | `fn_0801FD7A` | BRD | r0 | - |
| 0801FDCA | `fn_0801FDCA` | BRD | r0 | - |
| 0801FDE2 | `fn_0801FDE2` | BRD | r0 | - |
| 0801FDEC | `rcc_lse_config` | BRD | r0 | - |
| 0801FE06 | `fn_0801FE06` | BRD | r0 | - |
| 0801FE1E | `fn_0801FE1E` | BRD | - | r0 |
| 0801FE2A | `fn_0801FE2A` | BLE | r0 | - |
| 0801FF80 | `fn_0801FF80` | BLE, BRD, SD | r0, r1 | - |
| 0801FF9E | `fn_0801FF9E` | BRD, SD | r0, r1 | - |
| 0801FFBC | `fn_0801FFBC` | BLE, BRD, LCD | r0, r1 | - |
| 0801FFDA | `fn_0801FFDA` | BRD, SD | r0, r1 | - |
| 08020876 | `fn_08020876` | BRD | r0 | - |
| 0802096C | `fn_0802096C` | BRD | r0, r1 | - |
| 0802099E | `fn_0802099E` | BZB | r0, r1 | - |

**UI (24)**

| v2.05 | Symbol | Called from | In | Out |
|---|---|---|---|---|
| 0800D664 | `fn_0800D664` | SYS | - | - |
| 0800D6E0 | `fn_0800D6E0` | SET | - | - |
| 0800E848 | `fn_0800E848` | FUNC | - | - |
| 080153AC | `fn_080153AC` | KEY, MODE, SYS | - | - |
| 08015934 | `fn_08015934` | FUNC, KEY | - | - |
| 08016D34 | `fn_08016D34` | SYS | - | - |
| 08017092 | `fn_08017092` | BZB | - | - |
| 080170AC | `fn_080170AC` | KEY | r0 | - |
| 080171FA | `fn_080171FA` | MODE, MVA | - | - |
| 0801772E | `fn_0801772E` | KEY | - | - |
| 08019792 | `fn_08019792` | CAL | - | - |
| 080197B6 | `fn_080197B6` | CAL | - | - |
| 080197E0 | `fn_080197E0` | CAL | - | - |
| 08019808 | `fn_08019808` | CAL | - | - |
| 0801982C | `fn_0801982C` | CAL | - | - |
| 08019854 | `fn_08019854` | CAL | - | - |
| 08019880 | `fn_08019880` | CAL, SET | - | - |
| 080198B0 | `fn_080198B0` | SET | - | - |
| 080198FC | `fn_080198FC` | SET | - | - |
| 08019948 | `fn_08019948` | SET | r0 | - |
| 080199B4 | `fn_080199B4` | SET | r0 | - |
| 08019A22 | `fn_08019A22` | SET | r0 | - |
| 08019A86 | `fn_08019A86` | SET | r0 | - |
| 0801A854 | `fn_0801A854` | CAL | - | - |

### C.2 New cross-module routines of the port

| Symbol | Module | In | Out | Context | Called by | Purpose |
|---|---|---|---|---|---|---|
| `sys_reset` | SYS | - | does not return | reset | vector 1 | 3.2 steps 1..5 |
| `cal_capture_cancel` | CAL | - | - | main | `meter_apply_mode_range` (MODE) | cancels a running capture with the refusal beep (OF-36) |
| `nvm_read_block`, `nvm_restore_begin`, `nvm_restore_next`, `nvm_restore_verify` | NVM | see `src/nvm/nvm.s` headers | | main | CAL (cal.bin restore) | block read and the stepped RESTORE-class write session |
| `calbin_start`, `calbin_step`, `calbin_result` | CAL | see `src/cal/calbin.s` headers | | main | power-on window (BOOTWIN), LOG/SD | cal.bin save/load as a state machine (IMP-06, OF-12) |
| `bootwin_active` (byte) | CAL | - | - | main | UI | power-on window open |
| `ble_tx_tick` | BLE | - | - (clobbers r0-r3) | TIM2 ISR | `isr_tim2` (SYS), every tick after the 500 ms block | starts a deferred status frame (NF-04, OF-10/11); alias of `ble_tx_kick` |
| `lcd_commit_retry` | LCD | - | - | main (production) | `fn_08016D34` (UI, at the end of the pass so that the repeated commit holds the finished screen), `enter_stop_and_reinit` (PWR, in the "-oFF-" beep loop) | repeats a deferred LCD commit (no busy-wait, IMP-06); every production loop that stays blocking after a screen was committed and does not run `fn_08016D34` must call it |
| `lcd_commit_flush` | LCD | - | - | main (production) | `bootwin_start` (CAL), after the splash commit | repeats a deferred LCD commit until it is written (bounded by LCD_WAIT_POLLS, HW-07), so the first HY3131 write of the power-on window keeps v2.05's time (7.1) |
| `ar_freq_tmo_count` (byte, `.bss_port`) | AR | - | - | IRQ28 (write), main (read) | incremented only by `sys_tim2_isr` (SYS) at a FREQ / PULSE / DUTY no-signal timeout that publishes a zero result (production); read by `ar_result_seen` and `ar_apply` | ends the OF-32 blanking at the first timeout (decision 12.2); a single writer, so no update is lost |
| `ui_blank_req` (byte, `.bss_port`) | UI | - | - | main | written by AR (`ar_apply`, `ar_result_seen`) and MRES (`fn_08006558`); read by `fn_08016E08`, `ui_value_valid` | main digits blank (1) or dashes (2), production only (OF-30, OF-32, IMP-01 rule P5); the OF-33 blank uses the v2.05 flag 0x2000805C |
| `ui_value_valid` | UI | - | r0 = 1 while the main digits show a reading, 0 while blank or dashes | main | `ble_value_valid` (BLE), a tail call, so a status frame is held back whenever the main digits are blank (`W3_to_W9.md`) | OF-34 |
| `lcd_init_fault` (byte, `.bss_port`) | LCD | - | - | main | set by `lcd_init` | 1 if `lcd_init` gave up waiting for LCD_SR.ENS or RDY (HW-07) |
| `sys_main` | SYS | - | does not return | main | `sys_reset` | 3.2 step 5, main loop 3.5 |
| `sys_system_init` | SYS | - | - | main | `sys_main`, `enter_stop_and_reinit` | replaces `FUN_0801BE76` without the option-byte block |
| `sys_clock_select` | SYS | r0 = 0 run (MSI range 6), 1 SD (HSE if it starts) | - | main | LOG (log write), CAL (cal.bin save/load) | replaces `FUN_0801BF1A` (callers 0x0801CD38, 0x0801CF14, 0x0801D1B2 and the switch-backs 0x0801CEFC, 0x0801D068, 0x0801D372); bounded waits |
| `sys_systick_isr` | SYS | - | - | SysTick | vector | v2.05 0x080248B0 (unreachable there; ported) |
| `brd_rtcwkup_isr`, `brd_adc_isr` | BRD | - | - | IRQ3, IRQ18 | vector | v2.05 0x080248C8, 0x08024A24 (unreachable there; ported) |
| `ble_usart2_isr` | BLE | - | - | IRQ38 | vector | replaces 0x080247D8 |
| `sd_sdio_isr`, `sd_dma_isr` | SD | - | - | IRQ45, IRQ53 | vector | replace 0x080248B8 and 0x080248C0 |
| `set_state_reset` | SET | - | - | main | `sys_main`, `enter_stop_and_reinit` | alias of `fn_08024DE0` |
| `sys_tim2_isr` | SYS | - | - | IRQ28 | vector | replaces IRQ28 0x0802428C |
| `sys_fault_safe` | SYS | - | does not return | fault | vectors | 4.7 |
| `sys_crit_enter` / `sys_crit_exit` | SYS | - / r0 = saved PRIMASK | r0 = saved PRIMASK / - | any | all | critical sections (macro form `CRIT_ENTER`/`CRIT_EXIT` preferred) |
| `brd_gpio_init` | BRD | r0 = port base, r1 = pointer to {u32 mask, u8 mode, u8 speed, u8 otype, u8 pupd, u8 af, u8 level} | r0 = 0 done, 1 refused by `brd_pin_policy` | main | every module that configures pins (SD, BLE, LCD, RTC, BRD) | replaces `gpio_init` + `gpio_set_alternate_function`; level before MODER (HW-04) |
| `brd_fe_apply` | BRD | r0 = mode, r1 = range | - | main | MODE, CAL (BOOTWIN), MVA | = `fn_0800FBE8`, table-driven (4.4) |
| `brd_exti_isr` | BRD | - | - | EXTI IRQs | vectors | clear pending bits |
| `pwr_apo_second` | PWR | - | - | main | `sys_main` step 9 | v2.05 APO block 0x08024CAE..0x08024D1A |
| `pwr_bl_second`, `pwr_bl_restart`, `pwr_bl_reset`, `pwr_bl_wake`, `pwr_bl_remember`, `pwr_bl_restore` (production only) | PWR | - | - (`pwr_bl_restart` keeps r0, r1 and the registers it does not use; flags clobbered) | main | `sys_main` step 9; KEY (`process_pg8_15_press_release`, `fn_08014AE6`, `handle_pg8_15_long_press`), DIAL (`debounce_pg0_7_onehot`), SET (`set_bl_edit`); `set_state_reset` | IMP-07 backlight auto-off timer: countdown, restart, state at power-on and wake |
| `pwr_bl_setting` (byte), `pwr_bl_count` (u16), `.bss_port`, production only | PWR | - | - | main | written by SET (`set_bl_load`, `set_bl_edit`) and PWR; read by PWR and SET | setting code 0 OFF, 1 = 30 s, 2..100 = 1..99 min; seconds left |
| `set_dsp_load`, `set_dsp_edit`, `set_dsp_draw` (production only) | SET | `set_dsp_edit`: r0 = 1 up, 2 down, 100 save | - | main | `set_state_reset`, `fn_0800D190` (load); `fn_080165F4` (edit, item 24); `fn_0801797C` (draw) | IMP-12 setup item 24 (page dSP), EEPROM 0x013 through `nvm_write_setting`; `func_dsp_level` read by `func_avg_core`, `func_hist_core` |
| `set_relp_load`, `set_relp_edit`, `set_relp_draw`, `set_clk_edit`, `set_clk_draw` (production only) | SET | `set_relp_edit`: r0 = 1 up, 2 down, 100 save | - | main | `set_state_reset`, `fn_0800D190` (load); `fn_080165F4` (edit, item 22); `fn_0801797C` (draw) | IMP-11 setup item 22 (page rEL), EEPROM 0x020 bit 0 through `nvm_write_setting` |
| `ui_relpct_view`, `ui_relpct_draw`, `ui_relpct_mask` (production only) | UI | - | `ui_relpct_view`: r0 = 1 while the percent view is shown | main | `fn_08016E08` (view, draw); `lcd_commit_shadow` (mask) | IMP-11 REL in percent |
| `log_trig_reset`, `log_trig_taken`, `log_trig_interval`, `log_trig_second`, `log_trig_verdict`, `set_ch_load`, `set_tr_edit`, `set_ch_edit`, `set_lg_draw` (production only) | LOG, SET | - | - | main | `log_start`, `log_take_record`, `sys_main` step 9, `lt_tick`; setup dispatchers | IMP-21 logging trigger |
| `log_mm_save`, `log_mm_write` (production only) | LOG | r0 = log_max_time / log_min_time | `log_mm_write`: r0 = 0 ok, 1 write failed | main | `log_take_max_main`, `log_take_min_main` (tail call); `log_write_minmax_rows` | IMP-21 date and time of the MAX / MIN rows |
| `ui_mmt_mark`, `ui_mmt_view`, `ui_mmt_draw` (production only) | UI | `ui_mmt_mark`: r0 = 0 maximum, 1 minimum; `ui_mmt_draw`: r0 = 1 value path, 0 overload path | `ui_mmt_view`: r0 = 1 while tHI / tLo is shown | main | `fn_0800E604`; `fn_08016E08` | IMP-21 MIN/MAX time pages |
| `lt_reset`, `set_lt_edit`, `set_lt_draw`, `lt_tick` (production only) | SET | `set_lt_edit`: r0 = action, r1 = item; `set_lt_draw`: r0 = item | `set_lt_draw`: r0 = 0 verdict page without a test | main | `set_state_reset`; `fn_080165F4`; `fn_0801797C`; `fn_08016E08` | IMP-20 limit test |
| `set_bh_ticks`, `set_bh_load`, `set_bh_edit`, `set_bh_draw` (production only) | SET | `set_bh_edit`: r0 = 1 up, 2 down, 100 save | `set_bh_ticks`: r0 = TIM3 ticks | main | `fn_080078D8` (ticks); `set_state_reset`, `fn_0800D190` (load); `fn_080165F4`; `fn_0801797C` | IMP-16 setup item 26 (page bH), EEPROM 0x021 |
| `func_stats_clear`, `func_stats_add`, `func_stats_sd_float` (production only) | FUNC | `func_stats_add`: r0 = reading | `func_stats_sd_float`: r0 = 1 and r1 = sigma (binary32), or r0 = 0 | main | `fn_08015974` (clear); `fn_0800E604` (add); `ui_stats_draw` | IMP-14 statistics |
| `ui_stats_view`, `ui_stats_draw`, `ui_stats_page`, `ui_stats_tick` (production only) | UI | `ui_stats_page`: r0 = item | `ui_stats_view`: r0 = 1 while Sd is shown | main | `fn_08016E08`; `fn_0801797C` | IMP-14 statistics pages |
| `lcd_bar_negative`, `lcd_bar_zero_sign` (production only) | LCD | - | `lcd_bar_negative`: r0 = 1 negative | main | `bargraph_count_from_value` (zero sign); `fn_0800C5DA` (BLE byte 13) | IMP-15 bargraph polarity with no bar lit |
| `set_tc_load`, `set_tc_edit`, `set_tc_draw` (production only) | SET | `set_tc_edit`: r0 = 1 up, 2 down, 100 save | - | main | `set_state_reset`, `fn_0800D190` (load); `fn_080165F4` (edit, item 23); `fn_0801797C` (draw) | IMP-10 setup item 23 (page tc, TEMP only), EEPROM 0x00F through `nvm_write_setting` |
| `mtmp_tc_select` (production only) | MTMP | r0 = type | - | main | `set_tc_load`, `set_tc_edit` | IMP-10: writes `mtmp_tc_type` and `mtmp_tc_descp`, read by `fn_08013C40` and `fn_08013CF8` |
| `set_bt_load`, `set_bt_edit`, `set_bt_draw` (production only) | SET | `set_bt_edit`: r0 = 1 up, 2 down, 100 save | - | main | `set_state_reset`, `fn_0800D190` (load); `fn_080165F4` (edit, item 21); `fn_0801797C` (draw) | IMP-09 setup item 21 (page bt), EEPROM 0x015 through `nvm_write_setting`; `ble_rate` read by `sys_tim2_isr` |
| `ble_rate_tick` (production only) | BLE | - | - | TIM2 interrupt | `sys_tim2_isr` while `ble_rate` != 0 | IMP-09: build request and frame start of the rates 4, 10, 20 per second |
| `set_dbm_load`, `set_dbm_edit`, `set_dbm_draw` (production only) | SET | `set_dbm_edit`: r0 = 1 up, 2 down, 100 save | - | main | `set_state_reset` (load); `fn_080165F4` (edit, item 11 in ACV); `fn_0801797C` (draw while `set_edit`) | IMP-08 dBm reference of the ACV page 11, EEPROM 0x011 through `nvm_write_setting`; `set_dbm_divisor` read by `mac_dbm`, `set_dbm_ref` by `FUN_0801A440` (no m for dBV) |
| `set_bl_load`, `set_bl_edit`, `set_bl_draw`, `set_bl_store` (production only) | SET | `set_bl_edit`: r0 = 1 up, 2 down, 100 save; `set_bl_draw`: r0 = code | - | main | `set_state_reset`, `fn_0800D190` (load); `fn_080165F4` (edit); `fn_0801797C` (draw) | IMP-07 setup item 20 (page bL), EEPROM 0x017 through `nvm_write_setting` |
| `bzb_tim3_isr` | BZB | - | - | IRQ29 | vector | replaces IRQ29 0x08024722 |
| `bzb_silence` | BZB | - | - | main | PWR, `sys_fault_safe` | clear buzzer state, PE7 low (HW-08) |
| `func_smooth_hist` | FUNC | r0 = value, r1 = threshold, r2 = depth, r3 = state pointer | r0 = smoothed value | main | MAC, MVA, MDC | `FUN_0800B754` algorithm on a caller-owned state block (OF-28) |
| `func_smooth_avg` | FUNC | r0 = value, r1 = threshold, r2 = depth, r3 = state pointer | r0 = smoothed value | main | MAC, MVA | `FUN_08008344` algorithm on a caller-owned state block (OF-28) |
| `ar_apply` | AR | r0 = mode, r1 = range | - | main | MODE | 6.12 |
| `ar_sample` | AR | r0 = calibrated per-sample value, r1 = raw AD1 code | - | main | MDC, MAC, MRES | production mode only (IMP-01) |
| `hy_peak_restart` | HY | - | - | main | MAC (`FUN_0800A7FC`) | the two 0x29 writes of 0x0800A872/0x0800A88C with bytes from the row table (HW-05) |
| `current_extra_clear` | MVA | r0 = mode (16..21) | r0 = NVM status | main | CAL | OF-08: arm USERZERO, write A5 00000000 to that mode's record, zero 0x20007E0C if the mode is active at range 0 |
| `cal_cache_load` | CAL | - | - | main | `bootwin_start` (CAL; at boot and after STOP) | OPT-08 |
| `bootwin_start` / `bootwin_step` | CAL | - / - | - / r0 = 0 window open, 1 closed | main | `sys_main`, `enter_stop_and_reinit` | 7.1 |
| `nvm_reset_lock` | NVM | - | - | reset | `sys_reset` | PELOCK = 1 |
| `nvm_clear_errors` | NVM | - | - | main | `sys_system_init` | FLASH_SR <- 0x1F02 (v2.05 0x0801BEA4) |
| `nvm_arm` | NVM | r0 = class key | - | main | callers of the writers below | arming token, one write call |
| `nvm_write_setting` | NVM | r0 = offset, r1 = value, r2 = width (1, 2, 4) | r0 = status | main | SET | class SETTINGS (EMAP 9.2) |
| `nvm_write_ident` | NVM | r0 = offset (0x001 or 0x003), r1 = value | r0 = status | main | CAL (`FUN_08010F74`, `FUN_08010FB8`) | class IDENT: 0x001 length 2 only while 0x2000808B != 0; 0x003 length 4 |
| `nvm_write_userzero` | NVM | r0 = mode (16..21), r1 = value (i32) | r0 = status | main | MVA | class USERZERO, 0xA5 + u32 BE |
| `nvm_marker_write` | NVM | r0 = 0x1F or 0x26 | r0 = status | main | CAL | = `FUN_080104D4` / `FUN_08010F28` (10 tries with read-back) |
| `nvm_restore` | NVM | r0 = buffer, r1 = length (1200 or 1248) | r0 = 0, 8 or 9 | main | CAL (`calbin_load`) | class RESTORE (7.3) |
| `ble_tx_start_frame` | BLE | - | - | IRQ28 | `sys_tim2_isr` | OF-10 frame start |
| `ble_tx_queue_put` | BLE | r0 = pointer, r1 = length | r0 = 0 queued, 1 full | main | BLE command handling | OF-10 echo queue |

Status values of the NVM writers: 0 written and verified (or skipped because unchanged, OPT-03), 1 refused, 2
programming failed after 10 attempts. `cal_record_write`, `fn_08011DCE`, `fn_08011E88`, `fn_08011F38` (C.1) return the
same status in r0 and require `nvm_arm` with the CAL key.
