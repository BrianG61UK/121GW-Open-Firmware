@ =============================================================================
@ nvm.s - NVM module: the only data-EEPROM write path, write classes, arming token, readers
@
@ Every EEPROM change of the firmware passes through nvm_write_bytes, which is reached only from the public
@ writers below, each of one write class (EEPROM_MAP.md 9.2, DESIGN.md 6.21, Appendix C.2):
@   SETTINGS  nvm_write_setting                      settings and rotary memory (EMAP 7.1)
@   IDENT     nvm_write_ident                        date code 0x001 (gated by 0x2000808B) and serial 0x003
@   USERZERO  nvm_write_userzero                     user current-zero records 0x4D0..0x4FC
@   CAL       cal_record_write, fn_08011DCE, fn_08011E88, fn_08011F38, nvm_marker_write
@   RESTORE   nvm_restore (nvm_restore_begin / _next / _verify)   cal.bin restore (OF-12)
@ Protection (EEPROM_MAP.md 9.3):
@   1. arming: the caller calls nvm_arm(class key) immediately before one writer call; the writer opens a
@      session only when the token equals that class's key XOR 0x4E564D21, and the token is cleared at every
@      session open, so one arm allows one writer call and a stray branch into a writer finds no token;
@   2. nvm_write_bytes refuses unless a session of its class is open, the whole range is inside 0x000..0x4FC and
@      allowed for the class by nvm_allow (generated from EEPROM_MAP.md), and the class condition holds
@      (IDENT gate, USERZERO record shape, CAL: calibration mode and the (kind, mode, range) rule recomputed
@      here from meter_mode/meter_range with the refusals of EEPROM_MAP.md 10);
@   3. the byte program (flash.s) re-checks offset and class bitmap at the store, unlocks only around one
@      store and locks on every exit;
@   4. the low-battery refusal of decision Q10 (switch NVM_REFUSE_LOW_BATTERY) is taken at session open, so a
@      writer call is refused as a whole (refusal beep) and never stops half way because of it.
@ Refusals write nothing, return status 1 and count in nvm_refusals (read by the tests).
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "nvm_allow.inc"

    .equ NVM_TOKEN_XOR,     0x4E564D21      @ EEPROM_MAP.md 9.3 item 1
    .equ NVM_SESSION_TAG,   0xC0            @ nvm_session = NVM_SESSION_TAG | class while a writer runs
    .equ NVM_USERZERO_BASE, 0x4D0           @ current_extra_offset 0x0801154E: mode 16 -> 0x4D0, +8 per mode
    .equ NVM_MARKER,        0xA5            @ record/marker validity byte (EMAP 4)
    .equ T_PEAK_ENTRY,      0x32            @ byte offset of T[25] (peak record), v2.05 ldrh [r0,#0x32] 0x08011C12

@ CAL write kinds used by the rule check (nvm_cal_expect); one per distinct target of EMAP 7.3
    .equ K_OFF,             1               @ cal_record_write kind 0, non-VA modes
    .equ K_GAIN,            2               @ cal_record_write kind 1, non-VA modes
    .equ K_K2,              3               @ cal_record_write kind 2 (never called in v2.05, EMAP 7.3)
    .equ K_K3,              4               @ cal_record_write kind 3 (never called in v2.05, EMAP 7.3)
    .equ K_BOARD,           5               @ kind 0xC8: 0x2E0 u16
    .equ K_OHMW,            6               @ kind 0x96: 0x178 u32
    .equ K_VA_OFF1,         7               @ fn_08011DCE kind 0: R
    .equ K_VA_OFF2,         8               @ fn_08011DCE kind 0: R+8
    .equ K_VA_GAIN1,        9               @ fn_08011DCE kind 1: R+4
    .equ K_VA_GAIN2,        10              @ fn_08011DCE kind 1: R+0xC
    .equ K_ACW1,            11              @ fn_08011E88 word 1: R'+0 (K_ACW1 + n - 1 for word n)
    .equ K_ACW4,            14              @ fn_08011E88 word 4: R'+6
    .equ K_MARK1F,          15              @ marker 0x1F
    .equ K_MARK26,          16              @ marker 0x26

@ -----------------------------------------------------------------------------
@ Port RAM of NVM (DESIGN.md 5.1 .bss_port)
@ -----------------------------------------------------------------------------
    .section .bss_port.nvm, "aw", %nobits
    .align 2
    .global nvm_token, nvm_refusals, nvm_session
nvm_token:      .space 4                    @ armed key XOR NVM_TOKEN_XOR; 0 when not armed
nvm_refusals:   .space 4                    @ number of refused writer calls / writes (tests read it)
nvm_session:    .space 1                    @ NVM_SESSION_TAG | class while a writer runs, else 0
nvm_cal_kind:   .space 1                    @ K_* of the CAL write in progress
nvm_cal_amode:  .space 1                    @ mode argument of fn_08011E88 (AC words)
nvm_cal_arange: .space 1                    @ range argument of fn_08011E88
    .align 2
nvm_rst_buf:    .space 4                    @ restore: image buffer
nvm_rst_len:    .space 2                    @ restore: image length (1200 or 1248)
nvm_rst_pos:    .space 2                    @ restore: next byte position (0..1199, then 1200..1229)

    .section .rodata.nvm, "a", %progbits
    .align 2
@ arming keys in NVM_CLASS_* order (config.inc values, macros.inc NVM_ARM)
nvm_keys:
    .word NVM_KEY_SETTINGS, NVM_KEY_IDENT, NVM_KEY_USERZERO, NVM_KEY_CAL, NVM_KEY_RESTORE

    .section .text.nvm, "ax", %progbits

@ =============================================================================
@ Arming and sessions
@ =============================================================================

@ -----------------------------------------------------------------------------
@ nvm_arm - arm the NVM module for exactly one following writer call
@ Replaces : nothing in v2.05 (new, EEPROM_MAP.md 9.3 item 1)
@ In       : r0 = class key (NVM_KEY_SETTINGS, _IDENT, _USERZERO, _CAL, _RESTORE of config.inc)
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main
@ RAM      : writes nvm_token
@ -----------------------------------------------------------------------------
FUNC nvm_arm
    ldr r1, =NVM_TOKEN_XOR
    eors r0, r0, r1                         @ store key XOR constant, never the key itself
    ldr r1, =nvm_token
    str r0, [r1]
    bx lr
ENDFUNC nvm_arm

@ -----------------------------------------------------------------------------
@ nvm_refuse_count - count one refusal
@ Replaces : nothing in v2.05 (refusal counter nvm_refusals)
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_refuse_count
    ldr r1, =nvm_refusals
    ldr r0, [r1]
    adds r0, r0, #1
    str r0, [r1]
    bx lr
ENDFUNC nvm_refuse_count

@ -----------------------------------------------------------------------------
@ nvm_session_open - consume the token and open a writer session of one class
@ Replaces : nothing in v2.05 (EEPROM_MAP.md 9.3 item 1)
@ In       : r0 = class (NVM_CLASS_*)
@ Out      : r0 = 0 session open, 1 refused (wrong or missing token, unknown class, low battery, or a
@            RESTORE session in progress and another class asked for)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ RAM      : clears nvm_token always; writes nvm_session, nvm_cal_kind (a RESTORE session in progress is left
@            untouched when another class is refused); reads 0x200080F9 (low battery, set by adc_ch5_process
@            0x0801353E when the battery reading is below 41)
@ Spec     : EEPROM_MAP.md 9.3 item 1; DESIGN.md 12.2 Q10
@ Deviation: NVM-2 (low-battery refusal with the refusal beep FUN_0800EE6C)
@ -----------------------------------------------------------------------------
LFUNC nvm_session_open
    push {r4, lr}
    mov r4, r0                              @ r4 = class
    ldr r1, =nvm_token
    ldr r2, [r1]                            @ r2 = token as armed
    movs r3, #0
    str r3, [r1]                            @ the token is spent by this call whatever the outcome
    ldr r1, =nvm_session
    ldrb r0, [r1]
    cmp r0, #(NVM_SESSION_TAG | NVM_CLASS_RESTORE)
    bne 1f
    cmp r4, #NVM_CLASS_RESTORE              @ a cal.bin restore is in progress (it spans several steps in the
    bne .Lnso_refuse_keep                   @ production loop): another class is refused and the restore kept
1:  strb r3, [r1]                           @ no session until every test has passed
    strb r3, [r1, #1]                       @ nvm_cal_kind = 0 (follows nvm_session)
    cmp r4, #NVM_CLASS_COUNT
    bhs .Lnso_refuse
    ldr r1, =nvm_keys
    ldr r1, [r1, r4, lsl #2]                @ key of the class
    ldr r3, =NVM_TOKEN_XOR
    eors r1, r1, r3
    cmp r1, r2
    bne .Lnso_refuse                        @ not armed for this class
    .if NVM_REFUSE_LOW_BATTERY
    ldr r1, =v_200080F9
    ldrb r1, [r1]                           @ battery below the low threshold now (0x0801353A..0x08013544)
    cbz r1, .Lnso_open
    bl fn_0800EE6C                          @ refusal beep (Q10)
    b .Lnso_refuse
    .endif
.Lnso_open:
    ldr r1, =nvm_session
    orr r0, r4, #NVM_SESSION_TAG
    strb r0, [r1]
    movs r0, #0
    pop {r4, pc}
.Lnso_refuse:
.Lnso_refuse_keep:
    bl nvm_refuse_count
    movs r0, #1
    pop {r4, pc}
ENDFUNC nvm_session_open

@ -----------------------------------------------------------------------------
@ nvm_session_close - end the writer session
@ Replaces : nothing in v2.05 (EEPROM_MAP.md 9.3 item 1)
@ In       : -
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_session_close
    ldr r1, =nvm_session
    movs r2, #0
    strb r2, [r1]                           @ nvm_session
    strb r2, [r1, #1]                       @ nvm_cal_kind
    bx lr
ENDFUNC nvm_session_close

@ =============================================================================
@ The single write path
@ =============================================================================

@ -----------------------------------------------------------------------------
@ nvm_cal_expect - the CAL target rule: offset and length the current CAL write must have
@ Replaces : nothing in v2.05 (new; EEPROM_MAP.md 9.2 CAL row, 7.3, 10)
@ In       : nvm_cal_kind, nvm_cal_amode, nvm_cal_arange (RAM), meter_mode, meter_range
@ Out      : r0 = expected offset, r1 = expected length; r0 = 0xFFFFFFFF when the write is refused
@ Clobbers : r2, r3, r12, flags
@ Context  : main
@ RAM      : reads 0x2000803C, 0x2000803D, 0x20000000 (range counts), 0x200080B7 (peak hold)
@ Spec     : EEPROM_MAP.md 5.1, 5.3, 7.3, 10; DESIGN.md 7.2
@ Deviation: OF-07 (kinds 0, 1 refused in modes 0 and 10), NF-09 (kind 0 refused in mode 6, switch
@            CAL_REFUSE_FREQ_OFFSET), NF-16 (kinds 0, 1 refused in modes 7, 8, switch
@            CAL_REFUSE_COMPLETION_7_8); kinds 2 and 3, never called by v2.05, are refused
@ -----------------------------------------------------------------------------
LFUNC nvm_cal_expect
    push {r4-r6, lr}
    ldr r0, =nvm_cal_kind
    ldrb r4, [r0]                           @ r4 = kind
    ldr r0, =meter_mode
    ldrb r5, [r0]                           @ r5 = mode
    ldr r0, =meter_range
    ldrb r6, [r0]                           @ r6 = range
    cmp r5, #24                             @ mode outside 0..24: no record
    bhi .Lnce_refuse
    ldr r0, =range_count
    ldrb r0, [r0, r5]                       @ number of ranges of the mode (RAM 0x20000000)
    cmp r6, r0
    bhs .Lnce_refuse                        @ range outside the mode's ranges
    ldr r2, =v205_tab_08028EE8              @ r2 = record base table T (u16 per mode)
    cmp r4, #K_BOARD
    beq .Lnce_board
    cmp r4, #K_OHMW
    beq .Lnce_ohmw
    cmp r4, #K_MARK1F
    beq .Lnce_mark1f
    cmp r4, #K_MARK26
    beq .Lnce_mark26
    cmp r4, #K_ACW1
    blo .Lnce_notacw
    cmp r4, #K_ACW4
    bls .Lnce_acw
.Lnce_notacw:
    @ VA test: modes 13..15 and 22..24 (as cal_record_write 0x08011BAA..0x08011BE2)
    sub r3, r5, #13
    cmp r3, #2
    bls .Lnce_va
    sub r3, r5, #22
    cmp r3, #2
    bls .Lnce_va
    @ non-VA mode: only K_OFF and K_GAIN
    cmp r4, #K_OFF
    beq 1f
    cmp r4, #K_GAIN
    bne .Lnce_refuse                        @ VA kinds outside VA modes, kinds 2 and 3
1:  cmp r5, #0                              @ OF-07: LowZ
    beq .Lnce_refuse
    cmp r5, #10                             @ OF-07: BEEP
    beq .Lnce_refuse
    .if CAL_REFUSE_COMPLETION_7_8
    sub r3, r5, #7                          @ NF-16: PULSE, DUTY
    cmp r3, #1
    bls .Lnce_refuse
    .endif
    cmp r5, #6
    bne 2f
    cmp r4, #K_OFF
    .if CAL_REFUSE_FREQ_OFFSET
    beq .Lnce_refuse                        @ NF-09: FREQ offset
    .else
    beq 2f                                  @ v2.05: FREQ offset goes to T[6] + 16*range
    .endif
    ldrh r0, [r2, #12]                      @ FREQ gain: frequency reference T[6] + 4 = 0x104
    adds r0, r0, #4
    b .Lnce_len4
2:  cmp r5, #2                              @ peak record for ACV/ACmV with peak hold (0x08011BF4..0x08011C0C)
    beq 3f
    cmp r5, #4
    bne 4f
3:  ldr r0, =v_200080B7
    ldrb r0, [r0]
    cmp r0, #1
    bne 4f
    ldrh r0, [r2, #T_PEAK_ENTRY]            @ T[25] = 0x2D0
    b 5f
4:  ldrh r0, [r2, r5, lsl #1]               @ T[mode]
    add r0, r0, r6, lsl #4                  @ + 16 * range
5:  cmp r4, #K_GAIN
    bne .Lnce_len4
    adds r0, r0, #4                         @ gain word at R+4
    b .Lnce_len4
.Lnce_va:
    sub r3, r4, #K_VA_OFF1                  @ VA modes accept only the four VA kinds
    cmp r3, #3
    bhi .Lnce_refuse
    ldrh r0, [r2, r5, lsl #1]
    add r0, r0, r6, lsl #4                  @ R = T[mode] + 16 * range
    ldr r1, =nvm_va_add
    ldrb r1, [r1, r3]                       @ +0, +8, +4, +0xC
    add r0, r0, r1
    b .Lnce_len4
.Lnce_acw:
    ldr r0, =nvm_cal_amode
    ldrb r3, [r0]                           @ r3 = mode argument
    ldrb r1, [r0, #1]                       @ r1 = range argument
    cmp r3, r5                              @ the arguments are meter_mode/meter_range at every v2.05 call
    bne .Lnce_refuse                        @ (0x0800F9BC..0x0800F9C8, 0x08011F68..0x08011F70)
    cmp r1, r6
    bne .Lnce_refuse
    cmp r5, #2                              @ AC-word modes 2, 4, 16, 18, 20 (FUN_08007532 0x08007548..
    beq 6f                                  @ 0x0800756E, FUN_0800F13C 0x0800F144..0x0800F16A)
    cmp r5, #4
    beq 6f
    cmp r5, #20
    beq 6f
    cmp r5, #16
    beq 7f
    cmp r5, #18
    bne .Lnce_refuse
7:  movs r6, #1                             @ modes 16, 18: sub forced to 1 (0x080115D6..0x080115E8)
6:  ldrh r0, [r2, r5, lsl #1]
    adds r0, r0, #8
    add r0, r0, r6, lsl #4                  @ R' = T[mode] + 8 + 16 * sub
    sub r3, r4, #K_ACW1
    add r0, r0, r3, lsl #1                  @ + 2 * (word - 1)
    movs r1, #2
    pop {r4-r6, pc}
.Lnce_board:
    mov r0, #0x2E0                          @ board temperature offset, u16
    movs r1, #2
    pop {r4-r6, pc}
.Lnce_ohmw:
    cmp r5, #9                              @ OHM range-6 weight: only in mode 9 range 6, where the MEM long
    bne .Lnce_refuse                        @ starts its capture (0x080164EE)
    cmp r6, #6
    bne .Lnce_refuse
    mov r0, #0x178                          @ u32 at 0x178
    b .Lnce_len4
.Lnce_mark1f:
    cmp r5, #2                              @ written only after an ACV range-0 gain (0x0800F882..0x0800F896)
    bne .Lnce_refuse
    cmp r6, #0
    bne .Lnce_refuse
    movs r0, #0x1F
    movs r1, #1
    pop {r4-r6, pc}
.Lnce_mark26:
    cmp r5, #9                              @ written only after an OHM range-6 gain (0x0800F89A..0x0800F8AE)
    bne .Lnce_refuse
    cmp r6, #6
    bne .Lnce_refuse
    movs r0, #0x26
    movs r1, #1
    pop {r4-r6, pc}
.Lnce_len4:
    movs r1, #4
    pop {r4-r6, pc}
.Lnce_refuse:
    mov r0, #0xFFFFFFFF
    movs r1, #0
    pop {r4-r6, pc}
ENDFUNC nvm_cal_expect

@ -----------------------------------------------------------------------------
@ nvm_write_bytes - check one write against its class and program its bytes
@ Replaces : nothing in v2.05 as a whole (EEPROM_MAP.md 9.2 nvm_write_bytes); the byte loop corresponds to the
@            successive eeprom_write_byte_retry calls of 0x08012068 / 0x080120A8 / 0x080120D0
@ In       : r0 = class, r1 = offset, r2 = length (1..5), r3 = pointer to the bytes in write order (MSB first)
@ Out      : r0 = 0 every byte holds its value, 1 refused (nothing written; the store-time re-check could
@            only refuse a later byte after earlier ones if it disagreed with the checks made here, which use
@            the same table and session), 2 a byte was not confirmed after 10 attempts (the remaining bytes are
@            still written, as v2.05 writes every byte regardless)
@ Clobbers : r1-r3, r12, flags
@ Context  : main; reached only from the writers of this file
@ RAM      : reads nvm_session, nvm_cal_*, 0x2000808A (cal mode), 0x2000808B (date-code gate)
@ Spec     : EEPROM_MAP.md 9.2, 9.3 items 1-2
@ -----------------------------------------------------------------------------
LFUNC nvm_write_bytes
    push {r4-r8, lr}
    mov r4, r0                              @ r4 = class
    mov r5, r1                              @ r5 = offset
    mov r6, r2                              @ r6 = length
    mov r7, r3                              @ r7 = source
    @ 1. a session of this class must be open
    cmp r4, #NVM_CLASS_COUNT
    bhs .Lnwb_refuse
    ldr r0, =nvm_session
    ldrb r0, [r0]
    orr r1, r4, #NVM_SESSION_TAG
    cmp r0, r1
    bne .Lnwb_refuse
    @ 2. length 1..5, first and last byte at or below 0x4FC (the first is tested on its own, so a huge offset
    @    cannot wrap around to a small last offset)
    subs r0, r6, #1
    cmp r0, #4
    bhi .Lnwb_refuse
    movw r1, #0x4FC
    cmp r5, r1
    bhi .Lnwb_refuse
    adds r0, r5, r6
    subs r0, r0, #1                         @ last offset (no wrap: offset <= 0x4FC, length <= 5)
    cmp r0, r1
    bhi .Lnwb_refuse
    @ 3. every byte allowed for the class (nvm_allow)
    ldr r1, =nvm_allow
    movs r0, #NVM_ALLOW_STRIDE
    mla r8, r4, r0, r1                      @ r8 = class bitmap
    movs r2, #0                             @ r2 = index
1:  adds r3, r5, r2                         @ offset of byte r2
    lsrs r0, r3, #3
    ldrb r0, [r8, r0]
    and r3, r3, #7
    lsrs r0, r0, r3
    lsls r0, r0, #31                        @ Z = 1 when the class bit is 0
    beq .Lnwb_refuse
    adds r2, r2, #1
    cmp r2, r6
    blo 1b
    @ 4. class condition
    cmp r4, #NVM_CLASS_IDENT
    beq .Lnwb_ident
    cmp r4, #NVM_CLASS_USERZERO
    beq .Lnwb_userzero
    cmp r4, #NVM_CLASS_CAL
    beq .Lnwb_cal
    cmp r4, #NVM_CLASS_RESTORE
    bne .Lnwb_write                         @ SETTINGS: the class table is the whole condition
    cmp r6, #1                              @ RESTORE: byte by byte (nvm_restore_next)
    bne .Lnwb_refuse
    b .Lnwb_write
.Lnwb_ident:
    cmp r5, #1                              @ date code: length 2 at 0x001 while 0x2000808B != 0
    bne 2f                                  @ (v2.05 gate 0x08015F46..0x08015F4E)
    cmp r6, #2
    bne .Lnwb_refuse
    ldr r0, =v_2000808B
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lnwb_refuse
    b .Lnwb_write
2:  cmp r5, #3                              @ serial: length 4 at 0x003 (setup item 8 save 0x08015F90)
    bne .Lnwb_refuse
    cmp r6, #4
    bne .Lnwb_refuse
    b .Lnwb_write
.Lnwb_userzero:
    cmp r6, #5                              @ one whole record: marker + i32 BE
    bne .Lnwb_refuse
    sub r0, r5, #NVM_USERZERO_BASE
    tst r0, #7                              @ at a record base 0x4D0 + 8k (the table limits k to 0..5)
    bne .Lnwb_refuse
    ldrb r0, [r7]
    cmp r0, #NVM_MARKER                     @ first byte 0xA5
    bne .Lnwb_refuse
    b .Lnwb_write
.Lnwb_cal:
    ldr r0, =v_2000808A
    ldrb r0, [r0]
    cmp r0, #1                              @ calibration mode (its only store of 1: 0x0800EAE6)
    bne .Lnwb_refuse
    bl nvm_cal_expect
    cmp r0, r5                              @ offset must equal the rule's target
    bne .Lnwb_refuse
    cmp r1, r6                              @ and the length its width
    bne .Lnwb_refuse
.Lnwb_write:
    movs r8, #0                             @ r8 = combined status
    movs r2, #0
    push {r2}                               @ [sp] = byte index (keeps r4..r8 for the state)
    sub sp, sp, #4                          @ 8-byte stack alignment for the calls
3:  ldr r2, [sp, #4]
    adds r0, r5, r2                         @ offset of byte r2
    ldrb r1, [r7, r2]                       @ its value
    mov r2, r4                              @ class
    bl nvm_program_byte
    cmp r0, #1
    beq 4f                                  @ refused at the store: stop at once
    cmp r0, #0
    it ne                                   @ remember a failed byte, keep writing the rest
    movne r8, r0
    ldr r2, [sp, #4]
    adds r2, r2, #1
    str r2, [sp, #4]
    cmp r2, r6
    blo 3b
    add sp, sp, #8
    mov r0, r8
    pop {r4-r8, pc}
4:  add sp, sp, #8
.Lnwb_refuse:
    bl nvm_refuse_count
    movs r0, #1
    pop {r4-r8, pc}
ENDFUNC nvm_write_bytes

@ -----------------------------------------------------------------------------
@ nvm_write_be - write a value of 1, 2 or 4 bytes MSB first through nvm_write_bytes
@ Replaces : the byte split of 0x080120D0 eeprom_write_u8, 0x080120A8 eeprom_write_u16_be (high byte first,
@            0x080120BC, 0x080120CA) and 0x08012068 eeprom_write_u32_be (bits 31..24 first, 0x08012078..
@            0x080120A2)
@ In       : r0 = offset, r1 = value, r2 = width (1, 2 or 4), r3 = class
@ Out      : r0 = status of nvm_write_bytes (1 for another width)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_write_be
    push {r4, lr}
    sub sp, sp, #8                          @ [sp..sp+3] = bytes in write order
    mov r4, r0                              @ r4 = offset
    cmp r2, #1
    beq 1f
    cmp r2, #2
    beq 2f
    cmp r2, #4
    beq 4f
    bl nvm_refuse_count                     @ any other width: refuse
    movs r0, #1
    b 9f
1:  strb r1, [sp]                           @ u8
    b 8f
2:  lsrs r0, r1, #8
    strb r0, [sp]                           @ bits 15..8 first
    strb r1, [sp, #1]
    b 8f
4:  rev r0, r1                              @ big-endian byte order: bits 31..24 at the lowest address
    str r0, [sp]
8:  mov r0, r3                              @ class
    mov r1, r4                              @ offset
    mov r3, sp                              @ source (width already in r2)
    bl nvm_write_bytes
9:  add sp, sp, #8
    pop {r4, pc}
ENDFUNC nvm_write_be

@ -----------------------------------------------------------------------------
@ nvm_cal_write_be - set the CAL kind and write a value MSB first (class CAL)
@ Replaces : nothing in v2.05 (sets the rule kind, then the byte split of eeprom_write_u16_be / _u32_be)
@ In       : r0 = offset, r1 = value, r2 = width (2 or 4), r3 = kind K_*
@ Out      : r0 = status
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ RAM      : writes nvm_cal_kind
@ -----------------------------------------------------------------------------
LFUNC nvm_cal_write_be
    push {r4, lr}
    ldr r12, =nvm_cal_kind
    strb r3, [r12]
    movs r3, #NVM_CLASS_CAL
    bl nvm_write_be
    pop {r4, pc}
ENDFUNC nvm_cal_write_be

@ -----------------------------------------------------------------------------
@ nvm_combine - combined status: keep the first non-zero status
@ Replaces : nothing in v2.05 (v2.05 writers return no status)
@ In       : r0 = new status, r1 = combined status so far
@ Out      : r0 = combined status
@ Clobbers : flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_combine
    cmp r1, #0
    it ne                                   @ an earlier non-zero status wins
    movne r0, r1
    bx lr
ENDFUNC nvm_combine

@ =============================================================================
@ Public writers
@ =============================================================================

@ -----------------------------------------------------------------------------
@ nvm_write_setting - write a setting (class SETTINGS)
@ Replaces : the SET-side calls of eeprom_write_u8 0x080120D0 and eeprom_write_u16_be 0x080120A8 (EMAP 7.1:
@            rotary memory 0x08..0x0E, settings 0x10, 0x14, 0x16, 0x18..0x19, 0x1A, 0x1B, 0x1E)
@ In       : r0 = offset, r1 = value, r2 = width (1, 2, 4); requires nvm_arm(NVM_KEY_SETTINGS) just before
@ Out      : r0 = 0 written and verified (or unchanged), 1 refused, 2 failed
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ Spec     : EEPROM_MAP.md 7.1, 9.2; DESIGN.md Appendix C.2
@ -----------------------------------------------------------------------------
FUNC nvm_write_setting
    push {r4-r6, lr}
    mov r4, r0
    mov r5, r1
    mov r6, r2
    movs r0, #NVM_CLASS_SETTINGS
    bl nvm_session_open
    cbnz r0, 1f                             @ refused: r0 = 1
    mov r0, r4
    mov r1, r5
    mov r2, r6
    movs r3, #NVM_CLASS_SETTINGS
    bl nvm_write_be
    mov r4, r0
    bl nvm_session_close
    mov r0, r4
1:  pop {r4-r6, pc}
ENDFUNC nvm_write_setting

@ -----------------------------------------------------------------------------
@ nvm_write_ident - write the date code or the serial number (class IDENT)
@ Replaces : the writes of 0x08010F74 (date code, eeprom_write_u16_be(1, ...) 0x08010F7E) and 0x08010FB8
@            (serial, eeprom_write_u32_be(3, ...) 0x08010FC2)
@ In       : r0 = offset (0x001: u16 date code, only while 0x2000808B != 0; 0x003: u32 serial), r1 = value;
@            requires nvm_arm(NVM_KEY_IDENT) just before
@ Out      : r0 = status (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ Spec     : EEPROM_MAP.md 4 (0x001..0x006), 9.2
@ -----------------------------------------------------------------------------
FUNC nvm_write_ident
    push {r4, r5, r6, lr}
    mov r4, r0
    mov r5, r1
    movs r0, #NVM_CLASS_IDENT
    bl nvm_session_open
    cbnz r0, 3f
    movs r2, #2                             @ 0x001: u16 BE
    cmp r4, #1
    beq 1f
    movs r2, #4                             @ 0x003: u32 BE
    cmp r4, #3
    beq 1f
    bl nvm_refuse_count                     @ any other offset: refuse
    movs r6, #1
    b 2f
1:  mov r0, r4
    mov r1, r5
    movs r3, #NVM_CLASS_IDENT
    bl nvm_write_be
    mov r6, r0
2:  bl nvm_session_close
    mov r0, r6
3:  pop {r4, r5, r6, pc}
ENDFUNC nvm_write_ident

@ -----------------------------------------------------------------------------
@ nvm_write_userzero - write one user current-zero record (class USERZERO)
@ Replaces : the writes of 0x080114BC current_extra_store (0xA5 to the record base 0x080114FE, then the i32 BE
@            value to base+1..base+4 0x08011508)
@ In       : r0 = mode (16..21), r1 = value (i32); requires nvm_arm(NVM_KEY_USERZERO) just before
@ Out      : r0 = status (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ Spec     : EEPROM_MAP.md 3 (current_extra_offset 0x0801154E: 0x4D0 + 8 * (mode - 16)), 4, 9.2
@ -----------------------------------------------------------------------------
FUNC nvm_write_userzero
    push {r4, r5, r6, lr}
    sub sp, sp, #8                          @ [sp] = A5, [sp+1..4] = value BE
    mov r4, r0
    mov r5, r1
    movs r0, #NVM_CLASS_USERZERO
    bl nvm_session_open
    cbnz r0, 3f
    sub r4, r4, #16                         @ r4 = mode - 16
    cmp r4, #5
    bls 1f
    bl nvm_refuse_count                     @ not a current mode: refuse
    movs r6, #1
    b 2f
1:  movs r0, #NVM_MARKER
    strb r0, [sp]
    rev r0, r5                              @ r0 low byte = value bits 31..24 (MSB first)
    strb r0, [sp, #1]
    lsrs r1, r0, #8
    strb r1, [sp, #2]
    lsrs r1, r0, #16
    strb r1, [sp, #3]
    lsrs r1, r0, #24
    strb r1, [sp, #4]
    movs r0, #NVM_CLASS_USERZERO
    mov r1, #NVM_USERZERO_BASE
    add r1, r1, r4, lsl #3                  @ record base 0x4D0 + 8 * (mode - 16)
    movs r2, #5
    mov r3, sp
    bl nvm_write_bytes
    mov r6, r0
2:  bl nvm_session_close
    mov r0, r6
3:  add sp, sp, #8
    pop {r4, r5, r6, pc}
ENDFUNC nvm_write_userzero

@ -----------------------------------------------------------------------------
@ nvm_marker_write - write the calibration marker 0x1F or 0x26 (class CAL)
@ Replaces : the write loops of 0x080104D4 (marker 0x1F) and 0x08010F28 (marker 0x26): up to 10 times write
@            0xA5, read back, stop when equal (0x080104DA..0x080104F4, 0x08010F2E..0x08010F48)
@ In       : r0 = 0x1F or 0x26; requires nvm_arm(NVM_KEY_CAL) just before
@ Out      : r0 = status of the last write (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ Spec     : EEPROM_MAP.md 3, 4 (0x01F, 0x026), 9.2
@ -----------------------------------------------------------------------------
FUNC nvm_marker_write
    push {r4-r6, lr}
    sub sp, sp, #8                          @ [sp] = 0xA5
    mov r4, r0                              @ r4 = marker offset
    movs r0, #NVM_CLASS_CAL
    bl nvm_session_open
    cbnz r0, 9f
    movs r0, #K_MARK1F
    cmp r4, #0x1F
    beq 1f
    movs r0, #K_MARK26
    cmp r4, #0x26
    beq 1f
    bl nvm_refuse_count                     @ any other offset: refuse
    movs r6, #1
    b 8f
1:  ldr r1, =nvm_cal_kind
    strb r0, [r1]
    movs r0, #NVM_MARKER
    strb r0, [sp]
    movs r5, #0                             @ r5 = loop counter (0x080104D6)
2:  cmp r5, #10                             @ at most 10 rounds (0x080104DC)
    bhs 8f
    movs r0, #NVM_CLASS_CAL
    mov r1, r4
    movs r2, #1
    mov r3, sp
    bl nvm_write_bytes
    mov r6, r0
    cmp r6, #1
    beq 8f                                  @ refused: no further round
    mov r0, r4
    bl nvm_ee_read                          @ read back (0x080104EA)
    cmp r0, #NVM_MARKER
    beq 8f                                  @ equal: done (0x080104F0)
    adds r5, r5, #1
    b 2b
8:  bl nvm_session_close
    mov r0, r6
9:  add sp, sp, #8
    pop {r4-r6, pc}
ENDFUNC nvm_marker_write

@ -----------------------------------------------------------------------------
@ cal_record_write - write a calibration value (class CAL)
@ Replaces : 0x08011B40 cal_record_write
@ In       : r0 = kind (0 offset, 1 gain, 2, 3, 0x96 OHM range-6 weight, 0xC8 board offset), r1 = value
@            (kinds 0, 2, 3); requires nvm_arm(NVM_KEY_CAL) just before
@ Out      : r0 = status (0, 1, 2); v2.05 returns nothing and every v2.05 caller ignores the result
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C (computed offset, as v2.05), 0x20007FBE (clamped, kind 0xC8), 0x20007E14
@            (clamped by fn_08011924, kind 0x96) also when the call is refused (only the EEPROM writes are
@            refused); reads 0x2000803C, 0x2000803D, 0x200080B7, 0x20007E18, 0x20007E10, 0x20007FDF
@ Spec     : EEPROM_MAP.md 7.3; listing 0x08011B40..0x08011DCC
@ Deviation: OF-07, NF-09, NF-16 (refusals by the rule check, nvm_cal_expect)
@ -----------------------------------------------------------------------------
FUNC cal_record_write
    push {r4-r6, lr}
    uxtb r4, r0                             @ r4 = kind
    mov r5, r1                              @ r5 = value
    movs r0, #NVM_CLASS_CAL
    bl nvm_session_open
    mov r6, r0                              @ r6 = 1 when refused: the body still makes the v2.05 RAM changes,
    mov r0, r4                              @ its EEPROM writes find no session and are refused
    mov r1, r5
    bl nvm_crw_body
    cbnz r6, 9f
    mov r4, r0
    bl nvm_session_close                    @ close only a session this call opened
    mov r0, r4
    pop {r4-r6, pc}
9:  movs r0, #1
    pop {r4-r6, pc}
ENDFUNC cal_record_write

@ -----------------------------------------------------------------------------
@ nvm_crw_body - body of cal_record_write inside an open CAL session
@ Replaces : 0x08011B44..0x08011DCC (body of cal_record_write)
@ In       : r0 = kind, r1 = value
@ Out      : r0 = status
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_crw_body
    push {r4-r6, lr}
    mov r4, r0                              @ r4 = kind
    mov r5, r1                              @ r5 = value
    cmp r4, #0xC8
    bne .Lcrw_not_c8
    @ kind 0xC8: board temperature offset to 0x2E0 (0x08011B4C..0x08011B8A)
    mov r0, #0x2E0
    ldr r1, =v_20007D5C
    str r0, [r1]                            @ 0x20007D5C = 0x2E0
    ldr r2, =v_20007FBE
    ldrsh r1, [r2]                          @ signed board offset
    cmp r1, #1000
    bgt 1f                                  @ > 1000 -> 0 (0x08011B5E)
    cmn r1, #1000
    bge 2f                                  @ >= -1000 kept (0x08011B6C)
1:  movs r1, #0
    strh r1, [r2]                           @ 0x20007FBE = 0 (0x08011B78)
2:  ldrh r1, [r2]                           @ value as u16 (0x08011B7E)
    movs r2, #2
    movs r3, #K_BOARD
    bl nvm_cal_write_be                     @ u16 BE at 0x2E0 (0x08011B8A)
    pop {r4-r6, pc}
.Lcrw_not_c8:
    cmp r4, #0x96
    bne .Lcrw_not_96
    @ kind 0x96: OHM range-6 weight to 0x178 (0x08011B96..0x08011BA4)
    bl fn_08011924                          @ clamp 0x20007E14 to -3000..3000
    ldr r1, =v_20007E14
    ldr r1, [r1]
    mov r0, #0x178
    movs r2, #4
    movs r3, #K_OHMW
    bl nvm_cal_write_be
    pop {r4-r6, pc}
.Lcrw_not_96:
    ldr r0, =meter_mode
    ldrb r6, [r0]                           @ r6 = meter_mode
    sub r0, r6, #13                         @ VA modes 13..15 (0x08011BAA..0x08011BC0)
    cmp r0, #2
    bls 1f
    sub r0, r6, #22                         @ VA modes 22..24 (0x08011BCC..0x08011BE2)
    cmp r0, #2
    bhi .Lcrw_not_va
1:  mov r0, r4
    bl nvm_va_body                          @ fn_08011DCE(kind) (0x08011BC6, 0x08011BE8)
    pop {r4-r6, pc}
.Lcrw_not_va:
    cmp r4, #0
    bne .Lcrw_not_k0
    @ kind 0: offset word (0x08011BF4..0x08011C4C)
    bl nvm_crw_base                         @ r0 = T[mode] + 16*range, or 0x2D0 for ACV/ACmV peak
    ldr r1, =v_20007D5C
    str r0, [r1]
    mov r1, r5
    movs r2, #4
    movs r3, #K_OFF
    bl nvm_cal_write_be
    pop {r4-r6, pc}
.Lcrw_not_k0:
    cmp r4, #1
    bne .Lcrw_not_k1
    @ kind 1: gain word (0x08011C58..0x08011D38)
    cmp r6, #6
    bne 2f
    ldr r0, =v205_tab_08028EE8
    ldrh r0, [r0, #12]                      @ T[6]
    adds r0, r0, #4                         @ + 4 = frequency reference word 0x104 (0x08011C6C)
    ldr r1, =v_20007D5C
    str r0, [r1]
    ldr r1, =freq_reference
    ldr r1, [r1]                            @ value = 0x20007E18 (0x08011C78)
    movs r2, #4
    movs r3, #K_GAIN
    bl nvm_cal_write_be
    pop {r4-r6, pc}
2:  bl nvm_crw_base                         @ R (peak: 0x2D0)
    adds r0, r0, #4                         @ gain word R+4 (0x08011CA6, 0x08011CD0)
    ldr r1, =v_20007D5C
    str r0, [r1]
    @ D: 1e4 in mode 12 range 4 with 0x20007FDF != 0, 1e5 other mode 12, else 1e6 (0x08011CDA..0x08011D24)
    ldr r0, =0x49742400                     @ 1e6
    cmp r6, #12
    bne 3f
    ldr r0, =0x47C35000                     @ 1e5
    ldr r1, =meter_range
    ldrb r1, [r1]
    cmp r1, #4
    bne 3f
    ldr r1, =v_20007FDF
    ldrb r1, [r1]
    cmp r1, #0
    beq 3f
    ldr r0, =0x461C4000                     @ 1e4
3:  ldr r1, =cal_gain
    ldr r1, [r1]                            @ 0x20007E10
    bl fn_08013090                          @ fmul(D, gain)
    bl fn_08013370                          @ f2iz
    mov r1, r0
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    movs r2, #4
    movs r3, #K_GAIN
    bl nvm_cal_write_be                     @ (0x08011D38)
    pop {r4-r6, pc}
.Lcrw_not_k1:
    cmp r4, #2
    bne .Lcrw_not_k2
    @ kind 2: R+8 <- value (0x08011D44..0x08011D76); never called by v2.05, refused by the rule
    bl nvm_crw_tbase
    adds r0, r0, #8
    ldr r1, =v_20007D5C
    str r0, [r1]
    mov r1, r5
    movs r2, #4
    movs r3, #K_K2
    bl nvm_cal_write_be
    pop {r4-r6, pc}
.Lcrw_not_k2:
    cmp r4, #3
    bne .Lcrw_none
    @ kind 3: R+0xC <- f2iz(i2f(10000 * value)) (0x08011D82..0x08011DC8); never called, refused by the rule
    bl nvm_crw_tbase
    adds r0, r0, #12
    ldr r1, =v_20007D5C
    str r0, [r1]
    movw r0, #10000
    mul r0, r0, r5
    bl fn_08012F60                          @ i2f
    bl fn_08013370                          @ f2iz
    mov r1, r0
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    movs r2, #4
    movs r3, #K_K3
    bl nvm_cal_write_be
    pop {r4-r6, pc}
.Lcrw_none:
    movs r0, #0                             @ any other kind: v2.05 writes nothing (0x08011D80)
    pop {r4-r6, pc}
ENDFUNC nvm_crw_body

@ -----------------------------------------------------------------------------
@ nvm_crw_base - record base of cal_record_write kinds 0 and 1
@ Replaces : the record address computations 0x08011BF4..0x08011C42 and 0x08011C86..0x08011CD8
@ In       : -
@ Out      : r0 = 0x2D0 for meter_mode 2 or 4 with peak_hold 0x200080B7 == 1 (T[25], 0x08011C0E..0x08011C12),
@            else T[meter_mode] + 16 * meter_range (0x08011C1C..0x08011C3A)
@ Clobbers : r1, r2, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_crw_base
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cmp r0, #2
    beq 1f
    cmp r0, #4
    bne nvm_crw_tbase
1:  ldr r1, =v_200080B7
    ldrb r1, [r1]
    cmp r1, #1
    bne nvm_crw_tbase
    ldr r0, =v205_tab_08028EE8
    ldrh r0, [r0, #T_PEAK_ENTRY]
    bx lr
ENDFUNC nvm_crw_base

@ -----------------------------------------------------------------------------
@ nvm_crw_tbase - T[meter_mode] + 16 * meter_range
@ Replaces : the T[mode] + 16 * range computations of 0x08011B40 and 0x0801159C
@ In       : -
@ Out      : r0 = record base
@ Clobbers : r1, r2
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_crw_tbase
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =v205_tab_08028EE8
    ldrh r0, [r1, r0, lsl #1]               @ T[mode]
    ldr r1, =meter_range
    ldrb r1, [r1]
    add r0, r0, r1, lsl #4                  @ + 16 * range
    bx lr
ENDFUNC nvm_crw_tbase

@ -----------------------------------------------------------------------------
@ fn_08011DCE - write the VA calibration words (class CAL)
@ Replaces : 0x08011DCE (cal_record_write_va)
@ In       : r0 = kind (0 offsets, 1 gains); requires nvm_arm(NVM_KEY_CAL) just before
@ Out      : r0 = status (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C; reads 0x20007E24, 0x20007E28, 0x20007E2C, 0x20007E30
@ Spec     : EEPROM_MAP.md 3, 7.3
@ -----------------------------------------------------------------------------
FUNC fn_08011DCE
    push {r4-r6, lr}
    uxtb r4, r0
    movs r0, #NVM_CLASS_CAL
    bl nvm_session_open
    mov r6, r0                              @ r6 = 1 when refused: body runs, its writes are refused
    mov r0, r4
    bl nvm_va_body
    cbnz r6, 9f
    mov r4, r0
    bl nvm_session_close
    mov r0, r4
    pop {r4-r6, pc}
9:  movs r0, #1
    pop {r4-r6, pc}
ENDFUNC fn_08011DCE

@ -----------------------------------------------------------------------------
@ nvm_va_body - body of fn_08011DCE inside an open CAL session
@ Replaces : 0x08011DD2..0x08011E7C (body of fn_08011DCE)
@ In       : r0 = kind
@ Out      : r0 = combined status
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_va_body
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = kind
    movs r5, #0                             @ r5 = combined status
    cmp r4, #0
    bne 1f
    @ kind 0 (0x08011DD8..0x08011E0E)
    bl nvm_crw_tbase                        @ cal_record_base(0) 0x0801159C
    ldr r1, =v_20007D5C
    str r0, [r1]
    ldr r1, =v_20007E24
    ldr r1, [r1]                            @ offset 1
    movs r2, #4
    movs r3, #K_VA_OFF1
    bl nvm_cal_write_be
    mov r5, r0
    bl nvm_crw_tbase                        @ cal_record_base(1): the argument is ignored (0x0801159C)
    adds r0, r0, #8                         @ R+8 (0x08011DFE)
    ldr r1, =v_20007D5C
    str r0, [r1]
    ldr r1, =v_20007E28
    ldr r1, [r1]                            @ offset 2
    movs r2, #4
    movs r3, #K_VA_OFF2
    bl nvm_cal_write_be
    mov r1, r5
    bl nvm_combine
    pop {r4, r5, r6, pc}
1:  cmp r4, #1
    bne 8f
    @ kind 1 (0x08011E1A..0x08011E78)
    bl nvm_crw_tbase
    adds r0, r0, #4                         @ R+4 (0x08011E20)
    ldr r1, =v_20007D5C
    str r0, [r1]
    ldr r0, =0x49742400                     @ 1e6
    ldr r1, =v_20007E2C
    ldr r1, [r1]
    bl fn_08013090                          @ fmul(1e6, gain 1)
    bl fn_08013370                          @ f2iz
    mov r1, r0
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    movs r2, #4
    movs r3, #K_VA_GAIN1
    bl nvm_cal_write_be
    mov r5, r0
    bl nvm_crw_tbase
    adds r0, r0, #4                         @ R+4 then +8 = R+0xC (0x08011E4C..0x08011E58)
    adds r0, r0, #8
    ldr r1, =v_20007D5C
    str r0, [r1]
    ldr r0, =0x49742400                     @ 1e6
    ldr r1, =v_20007E30
    ldr r1, [r1]
    bl fn_08013090
    bl fn_08013370
    mov r1, r0
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    movs r2, #4
    movs r3, #K_VA_GAIN2
    bl nvm_cal_write_be
    mov r1, r5
    bl nvm_combine
    pop {r4, r5, r6, pc}
8:  movs r0, #0                             @ other kinds: nothing (0x08011E18)
    pop {r4, r5, r6, pc}
ENDFUNC nvm_va_body

@ -----------------------------------------------------------------------------
@ fn_08011E88 - write AC calibration words (class CAL)
@ Replaces : 0x08011E88 (ac_words_write)
@ In       : r0 = mode, r1 = range, r2 = selector (1..4 one word, 0x64 all four); requires
@            nvm_arm(NVM_KEY_CAL) just before
@ Out      : r0 = status (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x20007D5C; clamps 0x20007E4C..0x20007E58 (fn_080119F4) before writing them
@ Spec     : EEPROM_MAP.md 3, 7.3
@ -----------------------------------------------------------------------------
FUNC fn_08011E88
    push {r4-r8, lr}
    uxtb r4, r0
    uxtb r5, r1
    uxtb r6, r2
    movs r0, #NVM_CLASS_CAL
    bl nvm_session_open
    mov r7, r0                              @ r7 = 1 when refused: body (RAM clamps) runs, writes are refused
    mov r0, r4
    mov r1, r5
    mov r2, r6
    bl nvm_acw_body
    cbnz r7, 9f
    mov r4, r0
    bl nvm_session_close
    mov r0, r4
    pop {r4-r8, pc}
9:  movs r0, #1
    pop {r4-r8, pc}
ENDFUNC fn_08011E88

@ -----------------------------------------------------------------------------
@ nvm_acw_body - body of fn_08011E88 inside an open CAL session
@ Replaces : 0x08011E90..0x08011F36 (body of fn_08011E88)
@ In       : r0 = mode, r1 = range, r2 = selector
@ Out      : r0 = combined status
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC nvm_acw_body
    push {r4-r8, lr}
    mov r6, r2                              @ r6 = selector
    ldr r3, =nvm_cal_amode
    strb r0, [r3]                           @ arguments for the rule check
    strb r1, [r3, #1]
    bl fn_080115CC                          @ R' = ac_words_base(mode, range) (0x08011E98)
    ldr r1, =v_20007D5C
    str r0, [r1]
    movs r5, #0                             @ r5 = combined status
    movs r4, #0                             @ r4 = word index 0..3
1:  adds r0, r4, #1                         @ word number 1..4
    cmp r6, r0
    beq 2f
    cmp r6, #0x64                           @ 0x64 selects every word
    bne 3f
2:  mov r0, r4
    bl fn_080119F4                          @ clamp RAM word r4 (0x08011EAE, 0x08011ED2, 0x08011EF8, 0x08011F1E)
    ldr r1, =v_20007E4C
    ldr r1, [r1, r4, lsl #2]                @ 0x20007E4C + 4 * index
    uxth r1, r1                             @ u16 (0x08011EBA)
    ldr r0, =v_20007D5C
    ldr r0, [r0]
    add r0, r0, r4, lsl #1                  @ R' + 2 * index
    movs r2, #2
    add r3, r4, #K_ACW1
    bl nvm_cal_write_be
    mov r1, r5
    bl nvm_combine
    mov r5, r0
3:  adds r4, r4, #1
    cmp r4, #4
    blo 1b
    mov r0, r5
    pop {r4-r8, pc}
ENDFUNC nvm_acw_body

@ -----------------------------------------------------------------------------
@ fn_08011F38 - clear the AC calibration words in RAM and EEPROM (class CAL)
@ Replaces : 0x08011F38 (ac_words_clear)
@ In       : -; requires nvm_arm(NVM_KEY_CAL) just before
@ Out      : r0 = status (0, 1, 2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes 0x2000809C..0x2000809F = 0, 0x20007E4C..0x20007E58 = 0 (0x08011F3A..0x08011F66)
@ Spec     : EEPROM_MAP.md 3, 7.3
@ -----------------------------------------------------------------------------
FUNC fn_08011F38
    push {r4, r5, r6, lr}
    movs r0, #NVM_CLASS_CAL
    bl nvm_session_open
    mov r5, r0                              @ r5 = 1 when refused: the RAM clears still run, writes refused
    movs r0, #0
    ldr r1, =v_2000809C
    strb r0, [r1, #3]                       @ 0x2000809F (order of 0x08011F3C..0x08011F52)
    strb r0, [r1, #2]                       @ 0x2000809E
    strb r0, [r1, #1]                       @ 0x2000809D
    strb r0, [r1]                           @ 0x2000809C
    ldr r1, =v_20007E4C
    str r0, [r1, #12]                       @ 0x20007E58 (0x08011F56..0x08011F66)
    str r0, [r1, #8]                        @ 0x20007E54
    str r0, [r1, #4]                        @ 0x20007E50
    str r0, [r1]                            @ 0x20007E4C
    ldr r0, =meter_mode
    ldrb r0, [r0]
    ldr r1, =meter_range
    ldrb r1, [r1]
    movs r2, #0x64
    bl nvm_acw_body                         @ fn_08011E88(mode, range, 0x64) (0x08011F72)
    cbnz r5, 9f
    mov r4, r0
    bl nvm_session_close
    mov r0, r4
    pop {r4, r5, r6, pc}
9:  movs r0, #1
    pop {r4, r5, r6, pc}
ENDFUNC fn_08011F38

@ -----------------------------------------------------------------------------
@ nvm_restore - restore EEPROM 0x000..0x4AF (and the user-zero records) from a cal.bin image (class RESTORE)
@ Replaces : the write and verify loops of 0x0801CF06 calbin_load (0x0801D078..0x0801D0CA: 1200 calls of
@            eeprom_write_u8_wrapper 0x08010504, then read all back into a stack copy and compare)
@ In       : r0 = buffer, r1 = length: 1200 restores 0x000..0x4AF; 1248 also restores bytes +0..+4 of each
@            user-zero slot from file bytes 1200 + 8k + 0..4 (OF-12); requires nvm_arm(NVM_KEY_RESTORE)
@ Out      : r0 = 0 restored and verified, 8 refused before any write (length, token, low battery),
@            9 the write stopped or a byte differs afterwards (first mismatch, as v2.05 0x0801D0C2)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main (after the whole file has been read and its size accepted)
@ Spec     : DESIGN.md 7.3; EEPROM_MAP.md 8, 9.2
@ Deviation: OF-12 (1248-byte image), OPT-07 (compared with the EEPROM directly, no 1200-byte stack copy)
@ -----------------------------------------------------------------------------
FUNC nvm_restore
    push {r4, lr}
    bl nvm_restore_begin
    cbnz r0, 9f                             @ 8: nothing written
1:  bl nvm_restore_next
    cmp r0, #0
    beq 1b                                  @ more bytes
    cmp r0, #1
    bne 9f                                  @ 9: stopped
    bl nvm_restore_verify
9:  pop {r4, pc}
ENDFUNC nvm_restore

@ -----------------------------------------------------------------------------
@ nvm_restore_begin - open a RESTORE session for a cal.bin image
@ Replaces : nothing in v2.05 (first part of nvm_restore; state-machine form for IMP-06)
@ In       : r0 = buffer, r1 = length (1200 or 1248); requires nvm_arm(NVM_KEY_RESTORE) just before
@ Out      : r0 = 0 session open (nvm_restore_next writes), 8 refused, nothing written
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : writes nvm_rst_buf, nvm_rst_len, nvm_rst_pos; the session stays open until the last byte or a
@            refusal (any other writer call in between replaces the session and stops the restore)
@ -----------------------------------------------------------------------------
FUNC nvm_restore_begin
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = buffer
    mov r5, r1                              @ r5 = length
    movs r0, #NVM_CLASS_RESTORE
    bl nvm_session_open
    cbnz r0, 8f                             @ not armed or low battery
    movw r0, #1200
    cmp r5, r0
    beq 1f
    movw r0, #1248
    cmp r5, r0
    beq 1f
    bl nvm_refuse_count                     @ any other length: refused before any write
    bl nvm_session_close
    b 8f
1:  ldr r1, =nvm_rst_buf
    str r4, [r1]
    strh r5, [r1, #4]                       @ nvm_rst_len
    movs r0, #0
    strh r0, [r1, #6]                       @ nvm_rst_pos
    pop {r4, r5, r6, pc}
8:  movs r0, #8
    pop {r4, r5, r6, pc}
ENDFUNC nvm_restore_begin

@ -----------------------------------------------------------------------------
@ nvm_restore_next - write the next 16 bytes of the RESTORE session
@ Replaces : part of the write loop 0x0801D078..0x0801D090 of calbin_load (per byte eeprom_write_u8_wrapper
@            0x08010504), extended by the user-zero bytes of a 1248-byte image (OF-12)
@ In       : -
@ Out      : r0 = 0 more bytes remain, 1 every byte written (session closed), 9 stopped (no session or a
@            refusal at the store; session closed)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ RAM      : nvm_rst_pos
@ -----------------------------------------------------------------------------
FUNC nvm_restore_next
    push {r4-r8, lr}
    ldr r0, =nvm_session
    ldrb r0, [r0]
    cmp r0, #(NVM_SESSION_TAG | NVM_CLASS_RESTORE)
    bne .Lnrn_stop                          @ no RESTORE session
    ldr r4, =nvm_rst_buf                    @ r4 = state block
    ldrh r5, [r4, #6]                       @ r5 = position
    movw r6, #1200                          @ r6 = number of bytes: 1200, or 1200 + 30 for 1248
    ldrh r0, [r4, #4]
    cmp r0, r6
    it ne                                   @ 1248-byte image: 6 slots of 5 bytes more
    addne r6, r6, #30
    movs r7, #16                            @ r7 = bytes left in this step
1:  cmp r5, r6
    bhs .Lnrn_done
    cbz r7, .Lnrn_more
    ldr r3, [r4]                            @ buffer
    movw r0, #1200
    cmp r5, r0
    bhs 2f
    mov r1, r5                              @ 0x000..0x4AF: offset = position
    add r3, r3, r5                          @ source = buffer + position
    b 3f
2:  sub r0, r5, r0                          @ slot byte index 0..29
    movs r2, #5
    udiv r8, r0, r2                         @ k = index / 5
    mls r2, r8, r2, r0                      @ j = index - 5k
    mov r1, #NVM_USERZERO_BASE
    add r1, r1, r8, lsl #3
    add r1, r1, r2                          @ offset = 0x4D0 + 8k + j
    movw r0, #1200
    add r3, r3, r0
    add r3, r3, r8, lsl #3
    add r3, r3, r2                          @ source = buffer + 1200 + 8k + j
3:  movs r0, #NVM_CLASS_RESTORE
    movs r2, #1
    bl nvm_write_bytes
    cmp r0, #1
    beq .Lnrn_stop                          @ refused at the store: stop
    adds r5, r5, #1
    strh r5, [r4, #6]
    subs r7, r7, #1
    b 1b
.Lnrn_more:
    movs r0, #0
    pop {r4-r8, pc}
.Lnrn_done:
    bl nvm_session_close
    movs r0, #1
    pop {r4-r8, pc}
.Lnrn_stop:
    bl nvm_session_close
    movs r0, #9
    pop {r4-r8, pc}
ENDFUNC nvm_restore_next

@ -----------------------------------------------------------------------------
@ nvm_restore_verify - compare the EEPROM with the restored image
@ Replaces : the read-back and compare loops of calbin_load (0x0801D092..0x0801D0CA), compared with the
@            EEPROM directly (OPT-07)
@ In       : - (nvm_rst_buf, nvm_rst_len of the last nvm_restore_begin)
@ Out      : r0 = 0 every restored byte equal, 9 first mismatch
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC nvm_restore_verify
    push {r4-r8, lr}
    ldr r4, =nvm_rst_buf
    ldr r5, [r4]                            @ r5 = buffer
    ldrh r4, [r4, #4]                       @ r4 = length
    movs r6, #0                             @ compare 0x000..0x4AF
1:  mov r0, r6
    bl nvm_ee_read
    ldrb r1, [r5, r6]
    cmp r0, r1
    bne 9f
    adds r6, r6, #1
    movw r0, #1200
    cmp r6, r0
    blo 1b
    movw r0, #1248
    cmp r4, r0
    bne 8f
    movs r7, #0                             @ r7 = 8k
2:  movs r8, #0                             @ r8 = j
3:  mov r0, #NVM_USERZERO_BASE
    add r0, r0, r7
    add r0, r0, r8
    bl nvm_ee_read
    movw r1, #1200
    add r1, r1, r5
    add r1, r1, r7
    ldrb r1, [r1, r8]
    cmp r0, r1
    bne 9f
    add r8, r8, #1
    cmp r8, #5
    blo 3b
    adds r7, r7, #8
    cmp r7, #48
    blo 2b
8:  movs r0, #0
    pop {r4-r8, pc}
9:  movs r0, #9
    pop {r4-r8, pc}
ENDFUNC nvm_restore_verify

@ =============================================================================
@ Readers
@ =============================================================================

@ -----------------------------------------------------------------------------
@ eeprom_read_byte - one EEPROM byte (cache after cal_cache_load)
@ Replaces : 0x0801204C eeprom_read_byte
@ In       : r0 = offset
@ Out      : r0 = byte (cal_cache when cal_cache_valid != 0, else the EEPROM); 0 for an offset above 0x4FF
@ Clobbers : r1, flags
@ Context  : main
@ Spec     : DESIGN.md 6.20 (OPT-08), 6.21; EEPROM_MAP.md 2.2
@ -----------------------------------------------------------------------------
FUNC eeprom_read_byte
    cmp r0, #0x500                          @ outside the cache image: defined result 0
    bhs 2f
    ldr r1, =cal_cache_valid
    ldrb r1, [r1]
    cbz r1, 1f
    ldr r1, =cal_cache
    ldrb r0, [r1, r0]                       @ cache = EEPROM image (OPT-08)
    bx lr
1:  b nvm_ee_read                           @ before cal_cache_load: the EEPROM itself
2:  movs r0, #0
    bx lr
ENDFUNC eeprom_read_byte

@ -----------------------------------------------------------------------------
@ eeprom_read_u8 - one EEPROM byte as u8
@ Replaces : 0x0801203A eeprom_read_u8
@ In       : r0 = offset
@ Out      : r0 = byte
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC eeprom_read_u8
    b eeprom_read_byte                      @ the byte is already zero-extended (0x08012048 uxtb)
ENDFUNC eeprom_read_u8

@ -----------------------------------------------------------------------------
@ eeprom_read_u8_wrapper - one EEPROM byte as u8
@ Replaces : 0x080104F8 eeprom_read_u8_wrapper (calls eeprom_read_u8, 0x080104FE)
@ In       : r0 = offset
@ Out      : r0 = byte
@ Clobbers : r1, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC eeprom_read_u8_wrapper
    b eeprom_read_byte
ENDFUNC eeprom_read_u8_wrapper

@ -----------------------------------------------------------------------------
@ eeprom_read_u16_be - big-endian u16
@ Replaces : 0x08012000 eeprom_read_u16_be (b0 * 0x100 + b1, 0x08012022..0x08012036)
@ In       : r0 = offset
@ Out      : r0 = value 0..0xFFFF
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC eeprom_read_u16_be
    push {r4, r5, r6, lr}
    mov r4, r0
    bl eeprom_read_byte                     @ high byte at offset
    mov r5, r0
    adds r0, r4, #1
    bl eeprom_read_byte                     @ low byte at offset + 1
    orr r0, r0, r5, lsl #8
    pop {r4, r5, r6, pc}
ENDFUNC eeprom_read_u16_be

@ -----------------------------------------------------------------------------
@ fn_08011FD4 - big-endian s16
@ Replaces : 0x08011FD4 (eeprom_read_s16_be: u16, minus 0x10000 when >= 0x8000, 0x08011FE4..0x08011FF0)
@ In       : r0 = offset
@ Out      : r0 = value -32768..32767
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_08011FD4
    push {r4, lr}
    bl eeprom_read_u16_be
    sxth r0, r0                             @ same as v2.05 u16 + 0xFFFF0000 for values >= 0x8000
    pop {r4, pc}
ENDFUNC fn_08011FD4

@ -----------------------------------------------------------------------------
@ eeprom_read_u32_be - big-endian u32
@ Replaces : 0x08011F80 eeprom_read_u32_be (b0 << 24 + b1 << 16 + b2 << 8 + b3, 0x08011FA6..0x08011FCE)
@ In       : r0 = offset
@ Out      : r0 = value
@ Clobbers : r1-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC eeprom_read_u32_be
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = offset
    movs r5, #0                             @ r5 = value
    movs r6, #0                             @ r6 = byte index
1:  adds r0, r4, r6
    bl eeprom_read_byte
    orr r5, r0, r5, lsl #8                  @ value = value * 256 + byte, MSB first
    adds r6, r6, #1
    cmp r6, #4
    blo 1b
    mov r0, r5
    pop {r4, r5, r6, pc}
ENDFUNC eeprom_read_u32_be

@ -----------------------------------------------------------------------------
@ nvm_read_block - copy EEPROM bytes directly (not through the cache)
@ Replaces : nothing in v2.05 (new; used by cal_cache_load, which must not hold the EEPROM base itself,
@            DESIGN.md 9.3 item 2)
@ In       : r0 = first offset, r1 = destination, r2 = count (offset + count <= 0x500)
@ Out      : r0 = 0 copied, 1 refused (range above 0x4FF, nothing copied)
@ Clobbers : r1-r3, r12, flags (AAPCS)
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC nvm_read_block
    push {r4-r6, lr}
    mov r4, r0                              @ r4 = offset
    mov r5, r1                              @ r5 = destination
    adds r6, r0, r2                         @ r6 = end offset
    cmp r6, #0x500
    bhi 3f
    cmp r6, r4
    blo 3f                                  @ wrapped count
1:  cmp r4, r6
    bhs 2f
    mov r0, r4
    bl nvm_ee_read
    strb r0, [r5], #1
    adds r4, r4, #1
    b 1b
2:  movs r0, #0
    pop {r4-r6, pc}
3:  movs r0, #1
    pop {r4-r6, pc}
ENDFUNC nvm_read_block

@ =============================================================================
@ Record addressing (pure functions)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ fn_0801159C - calibration record base of the current mode and range
@ Replaces : 0x0801159C (cal_record_base): T[meter_mode] + (meter_range << 4) as u16; the argument is ignored
@ In       : r0 = ignored (v2.05 callers pass 0 or 1)
@ Out      : r0 = record offset
@ Clobbers : r1, r2
@ Context  : any
@ -----------------------------------------------------------------------------
FUNC fn_0801159C
    ldr r2, =v205_tab_08028EE8
    ldr r1, =meter_mode
    ldrb r1, [r1]
    ldrh r0, [r2, r1, lsl #1]               @ T[mode] (0x080115A8)
    ldr r1, =meter_range
    ldrb r1, [r1]
    add r0, r0, r1, lsl #4                  @ + 16 * range (0x080115B6)
    uxth r0, r0                             @ u16 (0x080115BA)
    bx lr
ENDFUNC fn_0801159C

@ -----------------------------------------------------------------------------
@ fn_080115CC - base of the AC calibration words of a mode and range
@ Replaces : 0x080115CC (ac_words_base): sub forced to 1 for modes 16 and 18 (0x080115D6..0x080115E8);
@            T[mode] + 8 + 16 * sub as u16 (0x080115EA..0x08011600)
@ In       : r0 = mode, r1 = range
@ Out      : r0 = offset
@ Clobbers : r1, r2
@ Context  : any
@ -----------------------------------------------------------------------------
FUNC fn_080115CC
    uxtb r0, r0
    uxtb r1, r1
    cmp r0, #16
    beq 1f
    cmp r0, #18
    bne 2f
1:  movs r1, #1                             @ modes 16, 18: sub = 1
2:  ldr r2, =v205_tab_08028EE8
    ldrh r0, [r2, r0, lsl #1]               @ T[mode]
    adds r0, r0, #8
    uxth r0, r0                             @ (0x080115F8)
    add r0, r0, r1, lsl #4
    uxth r0, r0                             @ (0x08011600)
    bx lr
ENDFUNC fn_080115CC

    .section .rodata.nvm, "a", %progbits
nvm_va_add:
    .byte 0, 8, 4, 12                       @ K_VA_OFF1, K_VA_OFF2, K_VA_GAIN1, K_VA_GAIN2 offsets from R

    .section .text.nvm, "ax", %progbits
    .ltorg
