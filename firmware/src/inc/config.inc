@ =============================================================================
@ config.inc - build switches and build constants of the 121GW replacement firmware
@
@ Every switch is defined only if the build has not defined it already, so a value given on the make command
@ line (make NAME=value, passed to the assembler as --defsym NAME=value) wins.  Each switch line carries the
@ marker "SWITCH <name> default <value>"; the Makefile reads these markers to pass command-line values and to
@ print every non-default switch of a build (DESIGN.md 7.2 last paragraph, 9.1).
@
@ Decisions cited as Qn are DESIGN.md 12.2 (owner decisions of 2026-10-31).  Where the deviation table of
@ DESIGN.md 10 still names the v2.05 behaviour as default but 12.2 decided otherwise, the 12.2 decision is the
@ default here and the line says so.
@ =============================================================================

    .ifndef CONFIG_INC
    .equ CONFIG_INC, 1

@ -----------------------------------------------------------------------------
@ Loop mode and build kind
@ -----------------------------------------------------------------------------

    @ This is the production (fast) build: IMP-06 loop structure (no busy-wait, per-event reads, state machines, WFI at
    @ the end of each pass), DESIGN.md 3.5.  The build with the v2.05 loop structure lives on the branch like-v2.05.

    @ Version shown at power-on (ui_version_sub on the sub display from the start of the power-on window, IMP-02 /
    @ IMP-35), five characters with the decimal point after the third: "F-A.BC" (F = fast build, release vA.B.C;
    @ a release tag vA.B.C must match "F-A.BC", checked by .github/scripts/check_fw_version.py before anything is
    @ published).
    .equ FW_VER_C0, 'F'
    .equ FW_VER_C1, '-'
    .equ FW_VER_C2, '1'
    .equ FW_VER_C3, '1'
    .equ FW_VER_C4, '8'

    @ DEBUG = 1 sets DBGMCU_CR DBG_SLEEP | DBG_STOP | DBG_STANDBY at every start as v2.05 does (0x0801BEF8).
    @ Production (0) leaves DBGMCU_CR alone so STOP is the true low-current STOP (NF-18, RM0038 30.16.3).
    .ifndef DEBUG
    .equ DEBUG, 0                       @ SWITCH DEBUG default 0 (NF-18)
    .endif

    @ BLE_AT_POWERUP = 1 switches Bluetooth on at every power-up as a long PEAK does (ble/blcmd.s blcmd_ble_on), so a
    @ computer can reach a development build without a key press.  Production (0): off at power-up, as v2.05.
    @ SD_READ_ONLY = 1 leaves the card write path out of sd/sdcard.s and sd/diskio.s (block write, write wait, stop,
    @ ACMD22, disk_write, the write-timeout diagnosis): the bootloader, which only reads the card, assembles its own
    @ copies of the two files with it (bootloader/Makefile).  The firmware is built with 0.
    .ifndef SD_READ_ONLY
    .equ SD_READ_ONLY, 0                @ SWITCH SD_READ_ONLY default 0 (1 only in the bootloader's own build)
    .endif

    .ifndef BLE_AT_POWERUP
    .equ BLE_AT_POWERUP, 0              @ SWITCH BLE_AT_POWERUP default 0 (development builds only)
    .endif

    @ MPU_GUARD = 1 makes program flash 0x08000000..0x0807FFFF and the option-byte page 0x1FF80000..0x1FF800FF
    @ read-only through the Cortex-M3 MPU at start-up, so even a store through a pointer computed at run time
    @ faults into sys_fault_safe instead of reaching the flash interface (Q12).  Default 0 until the emulator
    @ models the MPU and the guarded image has been tested in it (Q12: "enabled once W10 has added the MPU to
    @ the emulator and it is tested").
    .ifndef MPU_GUARD
    .equ MPU_GUARD, 1                   @ SWITCH MPU_GUARD default 1 (Q12: MPU model in the emulator; STOP/wake verified in both builds)
    .endif

    @ SAFETY_PROBE = 1 builds the never-released probe image of DESIGN.md 9.4 level 5.
    .ifndef SAFETY_PROBE
    .equ SAFETY_PROBE, 0                @ SWITCH SAFETY_PROBE default 0 (probe image is never released)
    .endif

@ -----------------------------------------------------------------------------
@ Hardware timing (BRD, SYS)
@ -----------------------------------------------------------------------------

    @ Extra hold-off in microseconds before the HY3131 bus pins PF0..PF3 are configured at the end of
    @ board_gpio_init (HW-03).  The NJM2870 start-up time is not in the supplied documents; 0 keeps the order
    @ never earlier than v2.05 (Q3).
    .ifndef HY_VDD_SETTLE_US
    .equ HY_VDD_SETTLE_US, 0            @ SWITCH HY_VDD_SETTLE_US default 0 (Q3)
    .endif

    @ Poll bound of every hardware ready-flag wait (DESIGN.md 3.2 step 3: HSERDY 0x5000 polls as v2.05
    @ 0x08025FF0 / 0x0801FDA4; VOSF, PLLRDY, SWS, HSIRDY, LSIRDY, HSERDY-clear, ADC flags bounded the same way).
    .equ SYS_WAIT_POLLS, 0x5000

    @ Poll bound of the LCD status waits in the BRD power-down path (HW-07, DESIGN.md 4.3 rule 6: 0x8000).
    .equ LCD_WAIT_POLLS, 0x8000

@ -----------------------------------------------------------------------------
@ Power-on window (CAL module, DESIGN.md 7.1)
@ -----------------------------------------------------------------------------
    .equ BOOTWIN_TICKS, 2000            @ TIM3 ticks of the window, v2.05 0x2000022E = 2000 (FUN_0800EA3A)

@ -----------------------------------------------------------------------------
@ Auto-range profiles (AR module, DESIGN.md 6.12, analysis/autorange_and_scheduler.md 5.2 P4 and 12)
@ -----------------------------------------------------------------------------

    @ AR_PROFILE_TP_<family> = 1 enables the target settle profile TP for that family; 0 keeps the conservative
    @ profile CP.  Each one stays 0 until the hardware step test of ARS section 12 named on its line has passed.
    .ifndef AR_PROFILE_TP_DCV
    .equ AR_PROFILE_TP_DCV, 0           @ SWITCH AR_PROFILE_TP_DCV default 0 (ARS 12 H1 not done)
    .endif
    .ifndef AR_PROFILE_TP_OHM
    .equ AR_PROFILE_TP_OHM, 0           @ SWITCH AR_PROFILE_TP_OHM default 0 (ARS 12 H2 not done)
    .endif
    .ifndef AR_PROFILE_TP_CURRENT
    .equ AR_PROFILE_TP_CURRENT, 0       @ SWITCH AR_PROFILE_TP_CURRENT default 0 (ARS 12 H3 not done)
    .endif
    .ifndef AR_PROFILE_TP_AC
    .equ AR_PROFILE_TP_AC, 0            @ SWITCH AR_PROFILE_TP_AC default 0 (ARS 12 H4 not done)
    .endif

@ -----------------------------------------------------------------------------
@ Measurement switches (MAC)
@ -----------------------------------------------------------------------------

    @ MAC_RMS_SERVICE = 1 assembles the v2.05 RMS-event processing of FUN_08008208 (square root and average,
    @ 0x0800827C..0x080082D4) for differential tests; 0 services the RMS event with the INTF clear only, because the
    @ results have no reader (OF-16, DESIGN.md 6.13, 6.27).  Requested by W6 (firmware/requests/W6_to_W1.md).
    .ifndef MAC_RMS_SERVICE
    .equ MAC_RMS_SERVICE, 0             @ SWITCH MAC_RMS_SERVICE default 0 (OF-16: the RMS result has no reader)
    .endif

@ -----------------------------------------------------------------------------
@ Calibration switches (CAL, NVM; DESIGN.md 7.2, 10)
@ -----------------------------------------------------------------------------
    .ifndef CAL_REFUSE_COMPLETION_7_8
    .equ CAL_REFUSE_COMPLETION_7_8, 1   @ SWITCH CAL_REFUSE_COMPLETION_7_8 default 1 (NF-16, Q5)
    .endif
    .ifndef CAL_FIX_SETUP_FALLTHROUGH
    .equ CAL_FIX_SETUP_FALLTHROUGH, 1   @ SWITCH CAL_FIX_SETUP_FALLTHROUGH default 1 (OF-37, was NF-07; Q9)
    .endif
    .ifndef CAL_CANCEL_ON_MODE_CHANGE
    .equ CAL_CANCEL_ON_MODE_CHANGE, 1   @ SWITCH CAL_CANCEL_ON_MODE_CHANGE default 1 (OF-36, was NF-08; Q9)
    .endif
    .ifndef CAL_REFUSE_FREQ_OFFSET
    .equ CAL_REFUSE_FREQ_OFFSET, 1      @ SWITCH CAL_REFUSE_FREQ_OFFSET default 1 (NF-09, Q5)
    .endif
    @ CAL_FIX_MARKER26_RAM (NF-10) does not exist: DESIGN.md 12.2 "Verification of the NF items" refuted NF-10
    @ and removed the switch; FUN_0800F7B8 is ported as in v2.05.

@ -----------------------------------------------------------------------------
@ Settings and EEPROM switches (SET, NVM)
@ -----------------------------------------------------------------------------

    @ Contrast 10 and 11 accepted at boot (what the setup editor offers and saves).  Q11 decided "accepted";
    @ the deviation table row NF-17 (now OF-38) still says default 0 = v2.05; the decision is applied.
    .ifndef SET_ACCEPT_CONTRAST_10_11
    .equ SET_ACCEPT_CONTRAST_10_11, 1   @ SWITCH SET_ACCEPT_CONTRAST_10_11 default 1 (OF-38, was NF-17; Q11)
    .endif

    @ EEPROM writes refused while the low-battery flag 0x200080F9 of adc_ch5_process is set.  Q10 decided
    @ "refused" (BOR off, a byte write erases and rewrites its word); the deviation table row NVM-2 and
    @ EEPROM_MAP.md (NVM-3) still say default 0 = v2.05; the decision is applied.
    .ifndef NVM_REFUSE_LOW_BATTERY
    .equ NVM_REFUSE_LOW_BATTERY, 1      @ SWITCH NVM_REFUSE_LOW_BATTERY default 1 (NVM-2, Q10)
    .endif

@ -----------------------------------------------------------------------------
@ NVM arming keys (DESIGN.md 6.21, macro NVM_ARM in macros.inc)
@ Per-class constants passed to nvm_arm immediately before a writer.  The values are arbitrary but distinct,
@ have no zero byte, and differ from every FLASH key value of RM0038 3.9.4..3.9.6, so no key word can stand in
@ for another and none can be mistaken for a FLASH key by the build check (DESIGN.md 9.3 item 2).
@ -----------------------------------------------------------------------------
    .equ NVM_KEY_SETTINGS,  0x5E771A65
    .equ NVM_KEY_IDENT,     0x1DE47C3B
    .equ NVM_KEY_USERZERO,  0x2E5A0D17
    .equ NVM_KEY_CAL,       0xCA1B7E29
    .equ NVM_KEY_RESTORE,   0x7E5703A9

    .endif
