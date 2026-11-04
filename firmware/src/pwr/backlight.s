@ =============================================================================
@ backlight.s - PWR: backlight auto-off timer (production image only, DESIGN.md 10 IMP-07, FEATURES.md 2.9)
@
@ v2.05 switches the backlight on and off only by the MODE long press (handle_pg8_15_long_press 0x080162E4: RAM flag
@ 0x2000807B and GPIOE BSRR bit 8 = PE8) and leaves it on until the next long press, until the APO power-off, or
@ for ever.  The production image can switch it off by itself after a time the user chooses (SETUP page bL, stored in
@ EEPROM 0x017, EEPROM_MAP.md 4.1): OFF (default, never), 30 s, or 1..99 minutes.
@
@ The setting is the code pwr_bl_setting: 0 = OFF, 1 = 30 s, 2..100 = (code - 1) minutes.  The countdown pwr_bl_count is
@ in seconds and is counted down by pwr_bl_second on the 1 s flag of the main loop (loop step 9, next to the APO
@ countdown pwr_apo_second); it runs only while the backlight flag 0x2000807B is set and the count is not zero.
@ Every key press (KEY, 10 ms tick), every latched dial position change (DIAL), every injected remote key (KEY), the
@ MODE long press that switches the backlight on and every edit step of the setting restart the countdown with
@ pwr_bl_restart.  When the count reaches zero the backlight is switched off exactly as the MODE long press does it
@ (flag 0x2000807B cleared, PE8 low through GPIOE BSRR bit 24); there is no beep.  After such a timer switch-off the next
@ key press switches the backlight on again for the set time and is otherwise swallowed (no short or long action), and the
@ next dial change switches it on again and acts as usual (pwr_bl_wake); a backlight switched off by the MODE long press
@ stays off.  The state of the user's own switching (MODE long press) is remembered in EEPROM 0x017 bit 7 and
@ restored at power-on and wake (pwr_bl_remember, pwr_bl_restore).
@
@ The start value is the time plus one second: the 1 s flag is not in phase with the restart, so the first decrement comes
@ 0..1 s after it, and the backlight therefore stays on for at least the chosen time and at most one second longer.
@
@ After a STOP wake and at power-on pwr_bl_reset clears the flag and the count: PE8 is low in both cases (power_down_
@ peripherals 0x0801C596, board_gpio_init), and v2.05 leaves the flag at 1 after a wake (nothing but the MODE long press
@ writes it), which made the next MODE long press look like "off" and need a second press.
@
@ Context: main only (no interrupt handler touches the variables).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ PWR_BL_CODE_30S,     1             @ setting code of 30 s (codes 2..100 are 1..99 minutes)
    .equ PWR_BL_PE8,          0x0100        @ PE8 = BL_OUT, the backlight (DESIGN.md 4.5)
    .equ pwr_bl_on,           v_2000807B    @ 1 = backlight on (set and cleared by the MODE long press 0x080162E4..0x0801631A)

    .section .bss_port.pwr, "aw", %nobits
    .align 1
@ pwr_bl_count: seconds until the backlight is switched off, 0 = no countdown (owner PWR)
    .global pwr_bl_count
pwr_bl_count:   .space 2
@ pwr_bl_auto: 1 = the countdown switched the backlight off; the next key press or dial change switches it on again
@ (pwr_bl_wake); 0 = the backlight is on, or was switched off by the MODE long press (owner PWR)
    .global pwr_bl_auto
pwr_bl_auto:    .space 1
@ pwr_bl_saved_on: the backlight state remembered in EEPROM 0x017 bit 7 (1 = on), loaded at boot and wake (owner PWR)
    .global pwr_bl_saved_on
pwr_bl_saved_on: .space 1
@ pwr_bl_setting: backlight auto-off code 0..100, loaded from EEPROM 0x017 at boot and wake, edited by SET (owner SET)
    .global pwr_bl_setting
pwr_bl_setting: .space 1

    .section .text.pwr.backlight, "ax", %progbits

@ -----------------------------------------------------------------------------
@ pwr_bl_reload_seconds - countdown start value of a setting code
@ Replaces : nothing in v2.05 (new, FEATURES.md 2.9)
@ In       : r0 = setting code 0..100
@ Out      : r0 = seconds: 0 for OFF, 31 for 30 s, (code - 1) * 60 + 1 for 1..99 minutes (time plus one second)
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC pwr_bl_reload_seconds
    cbz r0, 1f                              @ OFF: no countdown (r0 = 0 is the result)
    cmp r0, #PWR_BL_CODE_30S
    beq 2f                                  @ 30 s
    subs r0, r0, #1                         @ minutes 1..99
    movs r1, #60
    muls r0, r1, r0                         @ r0 = minutes * 60 (at most 99 * 60 = 5940)
    adds r0, r0, #1                         @ plus the partial first second
    bx lr
2:  movs r0, #31                            @ 30 s plus the partial first second
1:  bx lr
ENDFUNC pwr_bl_reload_seconds

@ -----------------------------------------------------------------------------
@ pwr_bl_restart - restart the backlight countdown from the present setting
@ Replaces : nothing in v2.05 (new, FEATURES.md 2.9)
@ In/Out   : - / -
@ Clobbers : flags only (r0, r1 are saved)
@ Context  : main (KEY press detection, DIAL latch, remote key, MODE long press, SET edit)
@ RAM      : reads pwr_bl_setting; writes pwr_bl_count
@ Note     : restarts whether or not the backlight is on; the countdown itself runs only while the flag 0x2000807B is set
@            (pwr_bl_second), so no countdown happens while the backlight is off
@ -----------------------------------------------------------------------------
FUNC pwr_bl_restart
    push {r0, r1, lr}
    ldr r0, =pwr_bl_setting
    ldrb r0, [r0]                           @ setting code
    bl pwr_bl_reload_seconds                @ r0 = start value in seconds (0 for OFF)
    ldr r1, =pwr_bl_count
    strh r0, [r1]
    pop {r0, r1, pc}
ENDFUNC pwr_bl_restart

@ -----------------------------------------------------------------------------
@ pwr_bl_second - backlight countdown of one second
@ Replaces : nothing in v2.05 (new, FEATURES.md 2.9); called by sys_main in loop step 9 after pwr_apo_second
@ In/Out   : - / -
@ Clobbers : r0, r1, flags
@ Context  : main (loop step 9, 1 s flag)
@ RAM      : reads 0x2000807B; reads and writes pwr_bl_count; at zero writes 0x2000807B and GPIOE BSRR (PE8)
@ Note     : the switch-off is the one of the MODE long press without its beep: 0x2000807B = 0 (0x0801630C..0x08016310)
@            and a halfword store of 0x100 to GPIOE BSRRH (0x08016312..0x0801631A)
@ -----------------------------------------------------------------------------
FUNC pwr_bl_second
    ldr r0, =pwr_bl_on
    ldrb r0, [r0]
    cbz r0, 1f                              @ backlight off: no countdown
    ldr r1, =pwr_bl_count
    ldrh r0, [r1]
    cbz r0, 1f                              @ OFF setting, or already switched off: nothing to count
    subs r0, r0, #1
    strh r0, [r1]                           @ count - 1 (strh leaves the flags)
    bne 1f                                  @ not zero yet
    movs r0, #0
    ldr r1, =pwr_bl_on
    strb r0, [r1]                           @ flag 0x2000807B = 0, as the MODE long press (0x08016310)
    mov.w r0, #PWR_BL_PE8
    ldr r1, =(GPIOE_BASE + GPIO_BSRRH)
    strh r0, [r1]                           @ PE8 low, as the MODE long press (0x0801631A)
    movs r0, #1
    ldr r1, =pwr_bl_auto
    strb r0, [r1]                           @ switched off by the timer: the next key or dial wakes it
1:  bx lr
ENDFUNC pwr_bl_second

@ -----------------------------------------------------------------------------
@ pwr_bl_wake - switch the backlight on again after the countdown switched it off
@ Replaces : nothing in v2.05 (new, FEATURES.md 2.9)
@ In       : -
@ Out      : r0 = 1 if the backlight was switched on (the caller then swallows the key press), 0 otherwise
@ Clobbers : r1, flags
@ Context  : main (KEY press detection, DIAL latch)
@ RAM      : reads and clears pwr_bl_auto; at a wake writes 0x2000807B = 1, GPIOE BSRR (PE8 high) and pwr_bl_count
@ Note     : the switch-on is the one of the MODE long press without its beep (0x080162EE..0x08016306): 0x2000807B = 1,
@            0x20007FB8 = 0x78 and a halfword store of 0x100 to GPIOE BSRRL; a backlight switched off by the MODE long press
@            is not woken
@ -----------------------------------------------------------------------------
FUNC pwr_bl_wake
    ldr r1, =pwr_bl_auto
    ldrb r0, [r1]
    cbz r0, 1f                              @ not switched off by the timer: nothing to do (r0 = 0)
    movs r0, #0
    strb r0, [r1]                           @ wake handled
    movs r0, #1
    ldr r1, =pwr_bl_on
    strb r0, [r1]                           @ flag 0x2000807B = 1, as the MODE long press (0x080162EE..0x080162F4)
    movs r0, #0x78
    ldr r1, =v_20007FB8
    strh r0, [r1]                           @ 0x20007FB8 = 0x78, as the MODE long press (0x080162F6..0x080162FC; no reader)
    mov.w r0, #PWR_BL_PE8
    ldr r1, =(GPIOE_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PE8 high, as the MODE long press
    push {lr}
    bl pwr_bl_restart                       @ a new countdown from the present setting
    pop {lr}
    movs r0, #1                             @ woken: the caller swallows the key press
1:  bx lr
ENDFUNC pwr_bl_wake

@ -----------------------------------------------------------------------------
@ pwr_bl_reset - backlight state at power-on and after a STOP wake
@ Replaces : nothing in v2.05 (new, FEATURES.md 2.9); called by set_state_reset after the APO reload
@ In/Out   : - / -
@ Clobbers : r0, r1
@ Context  : main
@ RAM      : writes pwr_bl_count and 0x2000807B
@ Note     : PE8 is low at both moments (0x0801C596 in power_down_peripherals; board_gpio_init), so the flag is cleared to
@            match it; v2.05 leaves the flag as it was before the STOP
@ -----------------------------------------------------------------------------
FUNC pwr_bl_reset
    movs r0, #0
    ldr r1, =pwr_bl_count
    strh r0, [r1]                           @ no countdown
    ldr r1, =pwr_bl_on
    strb r0, [r1]                           @ flag follows the pin: backlight off
    ldr r1, =pwr_bl_auto
    strb r0, [r1]                           @ no wake pending: the backlight was not switched off by the timer
    bx lr
ENDFUNC pwr_bl_reset

@ -----------------------------------------------------------------------------
@ pwr_bl_remember - store the backlight state after a MODE long press (EEPROM 0x017 bit 7)
@ Replaces : nothing in v2.05 (new: v2.05 does not keep the backlight state over a power-off)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main (handle_pg8_15_long_press, MODE, after the toggle)
@ RAM      : reads 0x2000807B; writes pwr_bl_saved_on
@ Note     : only the user's own switching is remembered: the timer's switch-off (pwr_bl_second) and its wake
@            (pwr_bl_wake) do not write, so the EEPROM is written once per MODE long press at most
@ -----------------------------------------------------------------------------
FUNC pwr_bl_remember
    push {r4, lr}
    ldr r0, =pwr_bl_on
    ldrb r0, [r0]
    ldr r1, =pwr_bl_saved_on
    strb r0, [r1]                           @ remembered state = the state after the toggle
    bl set_bl_store                         @ EEPROM 0x017 = code | state << 7
    pop {r4, pc}
ENDFUNC pwr_bl_remember

@ -----------------------------------------------------------------------------
@ pwr_bl_restore - switch the backlight on at power-on or wake if it was on when last switched
@ Replaces : nothing in v2.05 (new)
@ In/Out   : - / -
@ Clobbers : r0, r1, flags
@ Context  : main (set_state_reset, after pwr_bl_reset; PE8 is an output by then: board_gpio_init runs in
@            sys_system_init before set_state_reset)
@ RAM      : reads pwr_bl_saved_on; writes 0x2000807B, 0x20007FB8, GPIOE BSRR (PE8), pwr_bl_count
@ -----------------------------------------------------------------------------
FUNC pwr_bl_restore
    ldr r0, =pwr_bl_saved_on
    ldrb r0, [r0]
    cbz r0, 1f                              @ remembered off: stay off
    movs r0, #1
    ldr r1, =pwr_bl_on
    strb r0, [r1]                           @ flag 0x2000807B = 1, as the MODE long press (0x080162EE..0x080162F4)
    movs r0, #0x78
    ldr r1, =v_20007FB8
    strh r0, [r1]                           @ 0x20007FB8 = 0x78, as the MODE long press (0x080162F6..0x080162FC)
    mov.w r0, #PWR_BL_PE8
    ldr r1, =(GPIOE_BASE + GPIO_BSRRL)
    strh r0, [r1]                           @ PE8 high
    push {lr}
    bl pwr_bl_restart                       @ the auto-off countdown starts
    pop {lr}
1:  bx lr
ENDFUNC pwr_bl_restore

    .ltorg

