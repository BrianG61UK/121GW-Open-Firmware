@ =============================================================================
@ keys.s - KEY: the eight front-panel keys PG8..PG15 (sampling, debounce, press / release / hold, auto-repeat,
@          remote key injection)
@
@ Replaces the v2.05 functions sample_pg8_15 0x08016BCA, process_pg8_15_press_release 0x0801688C, FUN_0801680C,
@ FUN_0801682C, FUN_08016A64, FUN_08016B4C, FUN_08016B7C, FUN_08016BB8 and FUN_08014AE6 (DESIGN.md 6.9, Appendix A
@ KEY).  The key actions are in short.s (short press) and long.s (long press).
@
@ How a key press travels (analysis/keys_setup.md 1 and 2.1):
@   every 10 ms (loop step 4, TIM2 flag 0x200080D0) the main loop calls fn_0801680C, which runs
@     process_pg8_15_press_release  samples PG8..PG15, accepts a sample after two equal reads, tracks the hold
@                                   time, queues a short press until the key is released and fires a long press
@                                   after 50 ticks (0.50 s)
@     fn_0801682C                   turns a pending event into the short-press or long-press action
@     fn_08014AE6                   does the same for a key code that arrived over the serial link
@ Key bits: bit k of the sample is the key on PG(8+k), active low: 0x01 MODE, 0x02 SETUP, 0x04 MIN/MAX, 0x08 MEM,
@ 0x10 RANGE, 0x20 HOLD, 0x40 REL, 0x80 PEAK; 0x28 = MEM + HOLD (long press only).
@
@ Deviation OF-43 (new defect found while porting, see firmware/requests/W4_to_W10.md): v2.05 counts the debounce
@ stable count and the hold time in bytes without a limit; after 205 ticks past the long press the hold time wraps
@ to 0 and the key is taken for a new press, so a key held for about 3.1 s fires its long-press action a second time
@ (and again every 257 ticks, 2.57 s).  Both counters stop at 0xFF here.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "key.inc"

    .section .text.key.keys, "ax", %progbits

@ -----------------------------------------------------------------------------
@ sample_pg8_15 - read the eight key inputs PG8..PG15 into one byte
@ Replaces : 0x08016BCA sample_pg8_15 (v2.05)
@ In       : -
@ Out      : key_sample (0x2000806A): bit k set = key on PG(8+k) pressed (inputs are active low)
@ Clobbers : r0, r1, flags
@ Context  : main (called by process_pg8_15_press_release every 10 ms)
@ RAM      : writes 0x2000806A (key_sample); reads GPIOG_IDR 0x40021C10 (halfword)
@ Spec     : analysis/keys_setup.md 1 (bit to key table)
@ -----------------------------------------------------------------------------
FUNC sample_pg8_15

@ key_sample = 0, then test the eight pins one after the other.  Each test loads GPIOG_IDR and shifts it left
@ so that the pin under test reaches bit 31: shift = 0x17 - k for PG(8+k).  N (bmi) set = pin high = key up.
    movs r0, #0                         @ 08016BCA
    ldr r1, =key_sample                 @ 08016BCC
    strb r0, [r1]                       @ 08016BCE

@ PG8 = bit 0 = MODE (the first test stores 1, the others OR their bit in)
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016BD0
    ldrh r0, [r0]                       @ 08016BD2
    lsls r0, r0, #0x17                  @ 08016BD4
    bmi .L8016bca_08016BDE              @ 08016BD6
    movs r0, #1                         @ 08016BD8
    ldr r1, =key_sample                 @ 08016BDA
    strb r0, [r1]                       @ 08016BDC

@ PG9 = bit 1 = SETUP
@ reached from 08016BD6 bmi (negative) after lsls r0, r0, #0x17
.L8016bca_08016BDE:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016BDE
    ldrh r0, [r0]                       @ 08016BE0
    lsls r0, r0, #0x16                  @ 08016BE2
    bmi .L8016bca_08016BF2              @ 08016BE4
    ldr r0, =key_sample                 @ 08016BE6
    ldrb r0, [r0]                       @ 08016BE8
    orrs r0, r0, #2                     @ 08016BEA
    ldr r1, =key_sample                 @ 08016BEE
    strb r0, [r1]                       @ 08016BF0

@ PG10 = bit 2 = MIN/MAX
@ reached from 08016BE4 bmi (negative) after lsls r0, r0, #0x16
.L8016bca_08016BF2:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016BF2
    ldrh r0, [r0]                       @ 08016BF4
    lsls r0, r0, #0x15                  @ 08016BF6
    bmi .L8016bca_08016C06              @ 08016BF8
    ldr r0, =key_sample                 @ 08016BFA
    ldrb r0, [r0]                       @ 08016BFC
    orrs r0, r0, #4                     @ 08016BFE
    ldr r1, =key_sample                 @ 08016C02
    strb r0, [r1]                       @ 08016C04

@ PG11 = bit 3 = MEM
@ reached from 08016BF8 bmi (negative) after lsls r0, r0, #0x15
.L8016bca_08016C06:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016C06
    ldrh r0, [r0]                       @ 08016C08
    lsls r0, r0, #0x14                  @ 08016C0A
    bmi .L8016bca_08016C1A              @ 08016C0C
    ldr r0, =key_sample                 @ 08016C0E
    ldrb r0, [r0]                       @ 08016C10
    orrs r0, r0, #8                     @ 08016C12
    ldr r1, =key_sample                 @ 08016C16
    strb r0, [r1]                       @ 08016C18

@ PG12 = bit 4 = RANGE
@ reached from 08016C0C bmi (negative) after lsls r0, r0, #0x14
.L8016bca_08016C1A:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016C1A
    ldrh r0, [r0]                       @ 08016C1C
    lsls r0, r0, #0x13                  @ 08016C1E
    bmi .L8016bca_08016C2E              @ 08016C20
    ldr r0, =key_sample                 @ 08016C22
    ldrb r0, [r0]                       @ 08016C24
    orrs r0, r0, #0x10                  @ 08016C26
    ldr r1, =key_sample                 @ 08016C2A
    strb r0, [r1]                       @ 08016C2C

@ PG13 = bit 5 = HOLD
@ reached from 08016C20 bmi (negative) after lsls r0, r0, #0x13
.L8016bca_08016C2E:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016C2E
    ldrh r0, [r0]                       @ 08016C30
    lsls r0, r0, #0x12                  @ 08016C32
    bmi .L8016bca_08016C42              @ 08016C34
    ldr r0, =key_sample                 @ 08016C36
    ldrb r0, [r0]                       @ 08016C38
    orrs r0, r0, #0x20                  @ 08016C3A
    ldr r1, =key_sample                 @ 08016C3E
    strb r0, [r1]                       @ 08016C40

@ PG14 = bit 6 = REL
@ reached from 08016C34 bmi (negative) after lsls r0, r0, #0x12
.L8016bca_08016C42:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016C42
    ldrh r0, [r0]                       @ 08016C44
    lsls r0, r0, #0x11                  @ 08016C46
    bmi .L8016bca_08016C56              @ 08016C48
    ldr r0, =key_sample                 @ 08016C4A
    ldrb r0, [r0]                       @ 08016C4C
    orrs r0, r0, #0x40                  @ 08016C4E
    ldr r1, =key_sample                 @ 08016C52
    strb r0, [r1]                       @ 08016C54

@ PG15 = bit 7 = PEAK
@ reached from 08016C48 bmi (negative) after lsls r0, r0, #0x11
.L8016bca_08016C56:
    ldr r0, =GPIOG_BASE + GPIO_IDR      @ 08016C56
    ldrh r0, [r0]                       @ 08016C58
    lsls r0, r0, #0x10                  @ 08016C5A
    bmi .L8016bca_08016C6A              @ 08016C5C
    ldr r0, =key_sample                 @ 08016C5E
    ldrb r0, [r0]                       @ 08016C60
    orrs r0, r0, #0x80                  @ 08016C62
    ldr r1, =key_sample                 @ 08016C66
    strb r0, [r1]                       @ 08016C68
@ reached from 08016C5C bmi (negative) after lsls r0, r0, #0x10
.L8016bca_08016C6A:
    bx lr                               @ 08016C6A
ENDFUNC sample_pg8_15
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016B7C - is the code exactly one key or dial contact
@ Replaces : 0x08016B7C FUN_08016B7C (v2.05)
@ In       : r0 = key bits (key_sample or dial_sample)
@ Out      : r0 = 1 for 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, else 0
@ Clobbers : r1, r2, flags
@ Context  : main (KEY press detection and DIAL debounce)
@ Spec     : analysis/keys_setup.md 2.1; analysis/rotary.md 1 (one-hot check)
@ -----------------------------------------------------------------------------
FUNC fn_08016B7C

@ r1 = 0 (result), r2 = code; any compare that hits sets the result to 1
    movs r1, r0                         @ 08016B7C
    movs r0, #0                         @ 08016B7E
    uxtb r1, r1                         @ 08016B80
    cmp r1, #1                          @ 08016B82
    beq .L8016b7c_08016BB0              @ 08016B84
    uxtb r1, r1                         @ 08016B86
    cmp r1, #2                          @ 08016B88
    beq .L8016b7c_08016BB0              @ 08016B8A
    uxtb r1, r1                         @ 08016B8C
    cmp r1, #4                          @ 08016B8E
    beq .L8016b7c_08016BB0              @ 08016B90
    uxtb r1, r1                         @ 08016B92
    cmp r1, #8                          @ 08016B94
    beq .L8016b7c_08016BB0              @ 08016B96
    uxtb r1, r1                         @ 08016B98
    cmp r1, #0x10                       @ 08016B9A
    beq .L8016b7c_08016BB0              @ 08016B9C
    uxtb r1, r1                         @ 08016B9E
    cmp r1, #0x20                       @ 08016BA0
    beq .L8016b7c_08016BB0              @ 08016BA2
    uxtb r1, r1                         @ 08016BA4
    cmp r1, #0x40                       @ 08016BA6
    beq .L8016b7c_08016BB0              @ 08016BA8
    uxtb r1, r1                         @ 08016BAA
    cmp r1, #0x80                       @ 08016BAC
    bne .L8016b7c_08016BB4              @ 08016BAE
@ reached from 08016B84 beq (equal / zero) after cmp r1, #1
@              and from 08016B8A beq (equal / zero) after cmp r1, #2
@              and from 08016B90 beq (equal / zero) after cmp r1, #4
@              ... and 4 more
.L8016b7c_08016BB0:
    movs r2, #1                         @ 08016BB0
    movs r0, r2                         @ 08016BB2
@ reached from 08016BAE bne (not equal / non-zero) after cmp r1, #0x80
.L8016b7c_08016BB4:
    uxtb r0, r0                         @ 08016BB4
    bx lr                               @ 08016BB6
ENDFUNC fn_08016B7C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016B4C - may this key fire a long press
@ Replaces : 0x08016B4C FUN_08016B4C (v2.05)
@ In       : r0 = key bits
@ Out      : r0 = 1 for 0x01, 0x02, 0x04, 0x08, 0x10, 0x28, 0x40, 0x80, else 0
@ Clobbers : r1, r2, flags
@ Context  : main (process_pg8_15_press_release when the hold time reaches 50 ticks)
@ Spec     : analysis/keys_setup.md 2.1: HOLD (0x20) has no long press, MEM + HOLD (0x28) has one
@ -----------------------------------------------------------------------------
FUNC fn_08016B4C

@ as fn_08016B7C but 0x28 (MEM + HOLD) is accepted and 0x20 (HOLD) is not
    movs r1, r0                         @ 08016B4C
    movs r0, #0                         @ 08016B4E
    uxtb r1, r1                         @ 08016B50
    movs r2, r1                         @ 08016B52
    cmp r2, #1                          @ 08016B54
    beq .L8016b4c_08016B74              @ 08016B56
    cmp r2, #2                          @ 08016B58
    beq .L8016b4c_08016B74              @ 08016B5A
    cmp r2, #4                          @ 08016B5C
    beq .L8016b4c_08016B74              @ 08016B5E
    cmp r2, #8                          @ 08016B60
    beq .L8016b4c_08016B74              @ 08016B62
    cmp r2, #0x10                       @ 08016B64
    beq .L8016b4c_08016B74              @ 08016B66
    cmp r2, #0x28                       @ 08016B68
    beq .L8016b4c_08016B74              @ 08016B6A
    cmp r2, #0x40                       @ 08016B6C
    beq .L8016b4c_08016B74              @ 08016B6E
    cmp r2, #0x80                       @ 08016B70
    bne .L8016b4c_08016B78              @ 08016B72
@ reached from 08016B56 beq (equal / zero) after cmp r2, #1
@              and from 08016B5A beq (equal / zero) after cmp r2, #2
@              and from 08016B5E beq (equal / zero) after cmp r2, #4
@              ... and 4 more
.L8016b4c_08016B74:
    movs r2, #1                         @ 08016B74
    movs r0, r2                         @ 08016B76
@ reached from 08016B72 bne (not equal / non-zero) after cmp r2, #0x80
.L8016b4c_08016B78:
    uxtb r0, r0                         @ 08016B78
    bx lr                               @ 08016B7A
ENDFUNC fn_08016B4C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016BB8 - is the code the MEM + HOLD combination
@ Replaces : 0x08016BB8 FUN_08016BB8 (v2.05)
@ In       : r0 = key bits
@ Out      : r0 = 1 when the code is 0x28 (MEM + HOLD), else 0
@ Clobbers : r1, flags
@ Context  : main (process_pg8_15_press_release)
@ Spec     : analysis/keys_setup.md 1 (combination 0x28)
@ -----------------------------------------------------------------------------
FUNC fn_08016BB8
    movs r1, r0                         @ 08016BB8
    movs r0, #0                         @ 08016BBA
    uxtb r1, r1                         @ 08016BBC
    cmp r1, #0x28                       @ 08016BBE
    bne .L8016bb8_08016BC6              @ 08016BC0
    movs r2, #1                         @ 08016BC2
    movs r0, r2                         @ 08016BC4
@ reached from 08016BC0 bne (not equal / non-zero) after cmp r1, #0x28
.L8016bb8_08016BC6:
    uxtb r0, r0                         @ 08016BC6
    bx lr                               @ 08016BC8
ENDFUNC fn_08016BB8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016A64 - auto-repeat of REL and PEAK in MEM view and while a setup item is edited
@ Replaces : 0x08016A64 FUN_08016A64 (v2.05)
@ In       : r0 = 0 reset the repeat state; 1 count one tick of the held key
@ Out      : -
@ Clobbers : r1, r2, r3, flags
@ Context  : main (process_pg8_15_press_release, 0x080169E2 held key, 0x08016A04 new press)
@ RAM      : key_rep_phase 0x200080F2, key_rep_count 0x200080F3; writes key_short_ev 0x20008067 and
@            key_short_code 0x2000806B (a repeat is a synthetic short press); reads key_mem_view 0x20007FE4,
@            key_sample 0x2000806A
@ Spec     : analysis/keys_setup.md 2.1: first repeat after more than 3 ticks in MEM view or more than 50 ticks in
@            edit, then 5 repeats every 31 ticks, then a repeat every 11 ticks
@ -----------------------------------------------------------------------------
FUNC fn_08016A64

@ argument 0: forget the repeat state
    uxtb r0, r0                         @ 08016A64
    cmp r0, #0                          @ 08016A66
    bne .L8016a64_08016A78              @ 08016A68
    movs r2, #0                         @ 08016A6A
    ldr r3, =key_rep_phase              @ 08016A6C
    strb r2, [r3]                       @ 08016A6E
    movs r2, #0                         @ 08016A70
    ldr r3, =key_rep_count              @ 08016A72
    strb r2, [r3]                       @ 08016A74
    b .L8016a64_08016B2E                @ 08016A76

@ argument 1.  Phase 0 = waiting for the first repeat, phases 1..5 = slow repeats, phase 6 = fast repeats.
@ reached from 08016A68 bne (not equal / non-zero) after cmp r0, #0
.L8016a64_08016A78:
    ldr r2, =key_rep_phase              @ 08016A78
    ldrb r2, [r2]                       @ 08016A7A
    cmp r2, #0                          @ 08016A7C
    beq .L8016a64_08016A8C              @ 08016A7E
    subs r2, r2, #1                     @ 08016A80
    cmp r2, #4                          @ 08016A82
    bls .L8016a64_08016AD0              @ 08016A84
    subs r2, r2, #5                     @ 08016A86
    beq .L8016a64_08016B02              @ 08016A88
    b .L8016a64_08016B2E                @ 08016A8A

@ phase 0: the delay is 3 ticks in MEM view, 50 ticks in setup edit; count one tick; when the count has passed
@ the delay: phase 1, count 0, queue a short press of the held key
@ reached from 08016A7E beq (equal / zero) after cmp r2, #0
.L8016a64_08016A8C:
    ldr r2, =key_mem_view               @ 08016A8C
    ldrb r2, [r2]                       @ 08016A8E
    cmp r2, #0                          @ 08016A90
    beq .L8016a64_08016A9A              @ 08016A92
    movs r2, #3                         @ 08016A94
    movs r1, r2                         @ 08016A96
    b .L8016a64_08016A9E                @ 08016A98
@ reached from 08016A92 beq (equal / zero) after cmp r2, #0
.L8016a64_08016A9A:
    movs r2, #0x32                      @ 08016A9A
    movs r1, r2                         @ 08016A9C
@ reached from 08016A98 b (jump)
.L8016a64_08016A9E:
    ldr r2, =key_rep_count              @ 08016A9E
    ldrb r2, [r2]                       @ 08016AA0
    adds r2, r2, #1                     @ 08016AA2
    ldr r3, =key_rep_count              @ 08016AA4
    strb r2, [r3]                       @ 08016AA6
    movs r2, r1                         @ 08016AA8
    ldr r3, =key_rep_count              @ 08016AAA
    ldrb r3, [r3]                       @ 08016AAC
    uxtb r2, r2                         @ 08016AAE
    cmp r2, r3                          @ 08016AB0
    bcs .L8016a64_08016ACE              @ 08016AB2
    movs r2, #1                         @ 08016AB4
    ldr r3, =key_rep_phase              @ 08016AB6
    strb r2, [r3]                       @ 08016AB8
    movs r2, #0                         @ 08016ABA
    ldr r3, =key_rep_count              @ 08016ABC
    strb r2, [r3]                       @ 08016ABE
    movs r2, #1                         @ 08016AC0
    ldr r3, =key_short_ev               @ 08016AC2
    strb r2, [r3]                       @ 08016AC4
    ldr r2, =key_sample                 @ 08016AC6
    ldrb r2, [r2]                       @ 08016AC8
    ldr r3, =key_short_code             @ 08016ACA
    strb r2, [r3]                       @ 08016ACC
@ reached from 08016AB2 bcs (unsigned >=) after cmp r2, r3
.L8016a64_08016ACE:
    b .L8016a64_08016B2E                @ 08016ACE

@ phases 1..5: count one tick; at 31 ticks: next phase, count 0, queue a short press
@ reached from 08016A84 bls (unsigned <=) after cmp r2, #4
.L8016a64_08016AD0:
    ldr r2, =key_rep_count              @ 08016AD0
    ldrb r2, [r2]                       @ 08016AD2
    adds r2, r2, #1                     @ 08016AD4
    ldr r3, =key_rep_count              @ 08016AD6
    strb r2, [r3]                       @ 08016AD8
    ldr r2, =key_rep_count              @ 08016ADA
    ldrb r2, [r2]                       @ 08016ADC
    cmp r2, #0x1F                       @ 08016ADE
    blt .L8016a64_08016B00              @ 08016AE0
    ldr r2, =key_rep_phase              @ 08016AE2
    ldrb r2, [r2]                       @ 08016AE4
    adds r2, r2, #1                     @ 08016AE6
    ldr r3, =key_rep_phase              @ 08016AE8
    strb r2, [r3]                       @ 08016AEA
    movs r2, #0                         @ 08016AEC
    ldr r3, =key_rep_count              @ 08016AEE
    strb r2, [r3]                       @ 08016AF0
    movs r2, #1                         @ 08016AF2
    ldr r3, =key_short_ev               @ 08016AF4
    strb r2, [r3]                       @ 08016AF6
    ldr r2, =key_sample                 @ 08016AF8
    ldrb r2, [r2]                       @ 08016AFA
    ldr r3, =key_short_code             @ 08016AFC
    strb r2, [r3]                       @ 08016AFE
@ reached from 08016AE0 blt (signed <) after cmp r2, #0x1F
.L8016a64_08016B00:
    b .L8016a64_08016B2E                @ 08016B00

@ phase 6: count one tick; at 11 ticks: stay in phase 6, count 0, queue a short press
@ reached from 08016A88 beq (equal / zero) after subs r2, r2, #5
.L8016a64_08016B02:
    ldr r2, =key_rep_count              @ 08016B02
    ldrb r2, [r2]                       @ 08016B04
    adds r2, r2, #1                     @ 08016B06
    ldr r3, =key_rep_count              @ 08016B08
    strb r2, [r3]                       @ 08016B0A
    ldr r2, =key_rep_count              @ 08016B0C
    ldrb r2, [r2]                       @ 08016B0E
    cmp r2, #0xB                        @ 08016B10
    blt .L8016a64_08016B2E              @ 08016B12
    movs r2, #6                         @ 08016B14
    ldr r3, =key_rep_phase              @ 08016B16
    strb r2, [r3]                       @ 08016B18
    movs r2, #0                         @ 08016B1A
    ldr r3, =key_rep_count              @ 08016B1C
    strb r2, [r3]                       @ 08016B1E
    movs r2, #1                         @ 08016B20
    ldr r3, =key_short_ev               @ 08016B22
    strb r2, [r3]                       @ 08016B24
    ldr r2, =key_sample                 @ 08016B26
    ldrb r2, [r2]                       @ 08016B28
    ldr r3, =key_short_code             @ 08016B2A
    strb r2, [r3]                       @ 08016B2C

@ return (also for phases above 6, which cannot occur)
@ reached from 08016A76 b (jump)
@              and from 08016A8A b (jump)
@              and from 08016ACE b (jump)
@              ... and 2 more
.L8016a64_08016B2E:
    bx lr                               @ 08016B2E
ENDFUNC fn_08016A64
    .ltorg

@ -----------------------------------------------------------------------------
@ process_pg8_15_press_release - debounce the keys, detect press, release and 0.5 s hold
@ Replaces : 0x0801688C process_pg8_15_press_release (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 is saved: it replaces the unused r7 that v2.05 pushed for stack alignment)
@ Context  : main, once per 10 ms tick (via fn_0801680C, loop step 4; the power-on window calls that too)
@ RAM      : writes key_sample, key_prev, key_stable, key_hold, key_lockout, key_queued, key_queued_code,
@            key_short_ev, key_short_code, key_long_ev, key_long_code; reads key_window 0x2000022E,
@            key_win_b 0x200080CE, key_mem_view 0x20007FE4, key_setup_edit 0x2000806E
@ Spec     : analysis/keys_setup.md 2.1
@ Deviation: OF-43 (key_stable and key_hold saturate at 0xFF instead of wrapping); OF-48 (the queued press of REL / PEAK in
@            setup edit is dropped once the auto-repeat has stepped)
@ -----------------------------------------------------------------------------
FUNC process_pg8_15_press_release
    push {r4, lr}                       @ 0801688C

@ lockout: key_lockout (10 after an event, 5 in the power-on window) blocks new presses while it is non-zero;
@ it counts down one per tick
    ldr r0, =key_lockout                @ 0801688E
    ldrb r0, [r0]                       @ 08016892
    cmp r0, #0                          @ 08016894
    beq .Lpr_080168A6                   @ 08016896
    ldr r0, =key_lockout                @ 08016898
    ldrb r0, [r0]                       @ 0801689C
    subs r0, r0, #1                     @ 0801689E
    ldr r1, =key_lockout                @ 080168A0
    strb r0, [r1]                       @ 080168A4

@ sample the keys; a sample counts only after it has been seen on two ticks in a row
@ reached from 08016896 beq (equal / zero) after cmp r0, #0
.Lpr_080168A6:
    bl sample_pg8_15                    @ 080168A6
    ldr r0, =key_sample                 @ 080168AA
    ldrb r0, [r0]                       @ 080168AE
    ldr r1, =key_prev                   @ 080168B0
    ldrb r1, [r1]                       @ 080168B4
    cmp r0, r1                          @ 080168B6
    beq .Lpr_same                       @ 080168B8
    ldr r0, =key_sample                 @ 080168BA
    ldrb r0, [r0]                       @ 080168BE
    ldr r1, =key_prev                   @ 080168C0
    strb r0, [r1]                       @ 080168C4
    movs r0, #0                         @ 080168C6
    ldr r1, =key_stable                 @ 080168C8
    strb r0, [r1]                       @ 080168CC
    b .Lpr_done                         @ 080168CE

@ same sample as before: count it (OF-43: the count stops at 0xFF).  Fewer than two equal samples: nothing yet
@ reached from 080168B8 beq (equal / zero) after cmp r0, r1
.Lpr_same:
    ldr r0, =key_stable                 @ 080168D0
    ldrb r0, [r0]                       @ 080168D4
    adds r0, r0, #1                         @ 080168D6 replaces v2.05 adds r0,r0,#0x1
    cmp r0, #0x100                    @ OF-43: stop at 0xFF instead of wrapping to 0
    it eq                             @ r0 was 0xFF
    subeq r0, r0, #1                  @ keep 0xFF
    ldr r1, =key_stable                 @ 080168D8
    strb r0, [r1]                       @ 080168DC
    ldr r0, =key_stable                 @ 080168DE
    ldrb r0, [r0]                       @ 080168E2
    cmp r0, #2                          @ 080168E4
    blt .Lpr_done                       @ 080168E6

@ two equal samples: act on them.  A non-zero sample = a key is down
    ldr r0, =key_sample                 @ 080168EA
    ldrb r0, [r0]                       @ 080168EE
    cmp r0, #0                          @ 080168F0
    bne .Lpr_keydown                    @ 080168F2

@ no key down: forget the hold time and keep the stable count at 2 so that it does not run up again.  A queued
@ short press fires now, because its key has been released (lockout 10, event for fn_0801682C)
.Lpr_released:
    movs r0, #0                         @ 080168F4
    ldr r1, =key_hold                   @ 080168F6
    strb r0, [r1]                       @ 080168FA
    movs r0, #2                         @ 080168FC
    ldr r1, =key_stable                 @ 080168FE
    strb r0, [r1]                       @ 08016902
    ldr r0, =key_queued                 @ 08016904
    ldrb r0, [r0]                       @ 08016908
    cmp r0, #1                          @ 0801690A
    bne .Lpr_done                       @ 0801690C
    movs r0, #0                         @ 08016910
    ldr r1, =key_queued                 @ 08016912
    strb r0, [r1]                       @ 08016916
    movs r0, #0xA                       @ 08016918
    ldr r1, =key_lockout                @ 0801691A
    strb r0, [r1]                       @ 0801691E
    movs r0, #1                         @ 08016920
    ldr r1, =key_short_ev               @ 08016922
    strb r0, [r1]                       @ 08016926
    ldr r0, =key_queued_code            @ 08016928
    ldrb r0, [r0]                       @ 0801692C
    ldr r1, =key_short_code             @ 0801692E
    strb r0, [r1]                       @ 08016932
    b .Lpr_done                         @ 08016934

@ a key is down: only one single key or the MEM + HOLD combination counts, any other combination is ignored
@ reached from 080168F2 bne (not equal / non-zero) after cmp r0, #0
.Lpr_keydown:
    bl pwr_bl_wake                      @ IMP-07: switched off by the timer? then this press only switches it on again
    cbz r0, 1f
    movs r0, #0x33
    ldr r1, =key_hold
    strb r0, [r1]                       @ the press counts as already held past the long-press time (as at 0x08016976):
    movs r0, #0                         @ no long press fires while it stays down ...
    ldr r1, =key_queued
    strb r0, [r1]                       @ ... and no short press at the release
    b .Lpr_done
1:  bl pwr_bl_restart                   @ IMP-07: any key press restarts the backlight auto-off countdown (every tick while down)
    ldr r0, =key_sample                 @ 08016936
    ldrb r0, [r0]                       @ 0801693A
    bl fn_08016B7C                      @ 0801693C
    cmp r0, #0                          @ 08016940
    bne .Lpr_counted                    @ 08016942
    ldr r0, =key_sample                 @ 08016944
    ldrb r0, [r0]                       @ 08016948
    bl fn_08016BB8                      @ 0801694A
    cmp r0, #0                          @ 0801694E
    beq .Lpr_done                       @ 08016950

@ hold time zero = a new press, non-zero = the key was already down on an earlier tick
@ reached from 08016942 bne (not equal / non-zero) after cmp r0, #0
.Lpr_counted:
    ldr r0, =key_hold                   @ 08016954
    ldrb r0, [r0]                       @ 08016958
    cmp r0, #0                          @ 0801695A
    beq .Lpr_newpress                   @ 0801695C

@ key held another tick: count the hold time (OF-43: it stops at 0xFF)
.Lpr_held:
    ldr r0, =key_hold                   @ 0801695E
    ldrb r0, [r0]                       @ 08016962
    adds r0, r0, #1                         @ 08016964 replaces v2.05 adds r0,r0,#0x1
    cmp r0, #0x100                    @ OF-43: stop at 0xFF instead of wrapping to 0
    it eq                             @ r0 was 0xFF
    subeq r0, r0, #1                  @ keep 0xFF
    ldr r1, =key_hold                   @ 08016966
    strb r0, [r1]                       @ 0801696A
    ldr r0, =key_hold                   @ 0801696C
    ldrb r0, [r0]                       @ 08016970

@ 50 ticks (0.50 s) held = long press: mark the hold as done (0x33) and drop the queued short press
    cmp r0, #0x32                       @ 08016972
    bne .Lpr_held_other                 @ 08016974
    movs r0, #0x33                      @ 08016976
    ldr r1, =key_hold                   @ 08016978
    strb r0, [r1]                       @ 0801697C
    movs r0, #0                         @ 0801697E
    ldr r1, =key_queued                 @ 08016980
    strb r0, [r1]                       @ 08016984

@ a key without a long-press action (HOLD alone) just loses its short press; the others queue a long press
    ldr r0, =key_sample                 @ 08016986
    ldrb r0, [r0]                       @ 0801698A
    bl fn_08016B4C                      @ 0801698C
    cmp r0, #0                          @ 08016990
    beq .Lpr_done                       @ 08016992

@ long-press event: key_long_ev = 1, key_long_code = key_sample, lockout 10
    movs r0, #1                         @ 08016994
    ldr r1, =key_long_ev                @ 08016996
    strb r0, [r1]                       @ 0801699A
    ldr r0, =key_sample                 @ 0801699C
    ldrb r0, [r0]                       @ 080169A0
    ldr r1, =key_long_code              @ 080169A2
    strb r0, [r1]                       @ 080169A6
    movs r0, #0xA                       @ 080169A8
    ldr r1, =key_lockout                @ 080169AA
    strb r0, [r1]                       @ 080169AE
    b .Lpr_done                         @ 080169B0

@ hold time is not 50: in MEM view or setup edit REL and PEAK are pinned to hold time 1 so that they never
@ reach a long press; fn_08016A64 auto-repeats them instead
@ reached from 08016974 bne (not equal / non-zero) after cmp r0, #0x32
.Lpr_held_other:
    ldr r0, =key_mem_view               @ 080169B2
    ldrb r0, [r0]                       @ 080169B4
    ldr r1, =key_setup_edit             @ 080169B6
    ldrb r1, [r1]                       @ 080169BA
    orrs r0, r1                         @ 080169BC
    uxtb r0, r0                         @ 080169BE
    cmp r0, #0                          @ 080169C0
    beq .Lpr_done                       @ 080169C2
    ldr r0, =key_sample                 @ 080169C4
    ldrb r0, [r0]                       @ 080169C8
    cmp r0, #0x40                       @ 080169CA
    beq .Lpr_080169D8                   @ 080169CC
    ldr r0, =key_sample                 @ 080169CE
    ldrb r0, [r0]                       @ 080169D2
    cmp r0, #0x80                       @ 080169D4
    bne .Lpr_done                       @ 080169D6
@ reached from 080169CC beq (equal / zero) after cmp r0, #0x40
.Lpr_080169D8:
    movs r0, #1                         @ 080169D8
    ldr r1, =key_hold                   @ 080169DA
    strb r0, [r1]                       @ 080169DE
    movs r0, #1                         @ 080169E0
    bl fn_08016A64                      @ 080169E2
    @ OF-48: the press of REL / PEAK in setup edit is queued at 0x08016A4E and v2.05 dispatches it at the release even after the
    @ auto-repeat has stepped (the hold time stays at 1, so the cancel at 0x08016984 never runs): a hold of more than 0.5 s
    @ stepped once more at the release.  Once the first repeat has fired (key_rep_phase != 0) the queued press is dropped.
    @ A press shorter than the repeat delay (50 ticks in edit) still steps once, at the release, as in v2.05.  (In the MEM
    @ view nothing is queued, so the store changes nothing there.)
    ldr r0, =key_rep_phase
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lpr_done                       @ no repeat yet: the queued press stays
    movs r0, #0
    ldr r1, =key_queued
    strb r0, [r1]                       @ the repeat has stepped: no second step at the release
    b .Lpr_done                         @ 080169E6

@ hold time 0 = a new press, accepted only when the lockout has run out
@ reached from 0801695C beq (equal / zero) after cmp r0, #0
.Lpr_newpress:
    ldr r0, =key_lockout                @ 080169E8
    ldrb r0, [r0]                       @ 080169EC
    cmp r0, #0                          @ 080169EE
    bne .Lpr_done                       @ 080169F0

@ start of a press: stable count 2, hold time 1, auto-repeat state reset
    movs r0, #2                         @ 080169F2
    ldr r1, =key_stable                 @ 080169F4
    strb r0, [r1]                       @ 080169F8
    movs r0, #1                         @ 080169FA
    ldr r1, =key_hold                   @ 080169FC
    strb r0, [r1]                       @ 08016A00
    movs r0, #0                         @ 08016A02
    bl fn_08016A64                      @ 08016A04

@ power-on window open (key_window != 0) and no window sequence under way (key_win_b == 0): the short press
@ fires at once on the press, lockout 5 (keys_setup.md 2.1 and 3)
    ldr r0, =key_window                 @ 08016A08
    ldrh r0, [r0]                       @ 08016A0C
    cmp r0, #0                          @ 08016A0E
    beq .Lpr_08016A36                   @ 08016A10
    ldr r0, =key_win_b                  @ 08016A12
    ldrb r0, [r0]                       @ 08016A14
    cmp r0, #0                          @ 08016A16
    bne .Lpr_08016A36                   @ 08016A18
    movs r0, #0                         @ 08016A1A
    ldr r1, =key_queued                 @ 08016A1C
    strb r0, [r1]                       @ 08016A1E
    movs r0, #5                         @ 08016A20
    ldr r1, =key_lockout                @ 08016A22
    strb r0, [r1]                       @ 08016A24
    movs r0, #1                         @ 08016A26
    ldr r1, =key_short_ev               @ 08016A28
    strb r0, [r1]                       @ 08016A2A
    ldr r0, =key_sample                 @ 08016A2C
    ldrb r0, [r0]                       @ 08016A2E
    ldr r1, =key_short_code             @ 08016A30
    strb r0, [r1]                       @ 08016A32
    b .Lpr_done                         @ 08016A34
    .ltorg

@ normal press: queue the short press until the key is released; in MEM view REL and PEAK are not queued
@ reached from 08016A10 beq (equal / zero) after cmp r0, #0
@              and from 08016A18 bne (not equal / non-zero) after cmp r0, #0
.Lpr_08016A36:
    ldr r0, =key_mem_view               @ 08016A36
    ldrb r0, [r0]                       @ 08016A38
    cmp r0, #0                          @ 08016A3A
    beq .Lpr_enqueue                    @ 08016A3C
    ldr r0, =key_sample                 @ 08016A3E
    ldrb r0, [r0]                       @ 08016A40
    cmp r0, #0x40                       @ 08016A42
    beq .Lpr_done                       @ 08016A44
    ldr r0, =key_sample                 @ 08016A46
    ldrb r0, [r0]                       @ 08016A48
    cmp r0, #0x80                       @ 08016A4A
    beq .Lpr_done                       @ 08016A4C
@ reached from 08016A3C beq (equal / zero) after cmp r0, #0
.Lpr_enqueue:
    movs r0, #1                         @ 08016A4E
    ldr r1, =key_queued                 @ 08016A50
    strb r0, [r1]                       @ 08016A52
    ldr r0, =key_sample                 @ 08016A54
    ldrb r0, [r0]                       @ 08016A56
    ldr r1, =key_queued_code            @ 08016A58
    strb r0, [r1]                       @ 08016A5A
@ reached from 080168CE b (jump)
@              and from 080168E6 blt (signed <) after cmp r0, #2
@              and from 0801690C bne (not equal / non-zero) after cmp r0, #1
@              ... and 11 more
.Lpr_done:
    pop {r4, pc}                        @ 08016A5C
ENDFUNC process_pg8_15_press_release
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801682C - run the pending short-press and long-press events
@ Replaces : 0x0801682C FUN_0801682C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (fn_0801680C)
@ RAM      : reads and clears key_short_ev 0x20008067 / key_long_ev 0x20008068; clears 0x2000801B, 0x2000801D
@            (log-record fields: any key press ends the record being composed, owner LOG / KEY)
@ Spec     : analysis/keys_setup.md 2.1
@ -----------------------------------------------------------------------------
FUNC fn_0801682C
    push {r4, lr}                       @ 0801682C

@ short-press event: clear it, clear 0x2000801B and 0x2000801D, run the short-press action for key_short_code
    ldr r0, =key_short_ev               @ 0801682E
    ldrb r0, [r0]                       @ 08016832
    cmp r0, #0                          @ 08016834
    beq .L801682c_0801685A              @ 08016836
    movs r0, #0                         @ 08016838
    ldr r1, =key_short_ev               @ 0801683A
    strb r0, [r1]                       @ 0801683E
    movs r0, #0                         @ 08016840
    ldr r1, =v_2000801B                 @ 08016842
    strb r0, [r1]                       @ 08016846
    movs r0, #0                         @ 08016848
    ldr r1, =v_2000801D                 @ 0801684A
    strb r0, [r1]                       @ 0801684E
    ldr r0, =key_short_code             @ 08016850
    ldrb r0, [r0]                       @ 08016854
    bl handle_pg8_15_short_press        @ 08016856

@ long-press event: the same for the long-press action
@ reached from 08016836 beq (equal / zero) after cmp r0, #0
.L801682c_0801685A:
    ldr r0, =key_long_ev                @ 0801685A
    ldrb r0, [r0]                       @ 0801685E
    cmp r0, #0                          @ 08016860
    beq .L801682c_08016886              @ 08016862
    movs r0, #0                         @ 08016864
    ldr r1, =key_long_ev                @ 08016866
    strb r0, [r1]                       @ 0801686A
    movs r0, #0                         @ 0801686C
    ldr r1, =v_2000801B                 @ 0801686E
    strb r0, [r1]                       @ 08016872
    movs r0, #0                         @ 08016874
    ldr r1, =v_2000801D                 @ 08016876
    strb r0, [r1]                       @ 0801687A
    ldr r0, =key_long_code              @ 0801687C
    ldrb r0, [r0]                       @ 08016880
    bl handle_pg8_15_long_press         @ 08016882
@ reached from 08016862 beq (equal / zero) after cmp r0, #0
.L801682c_08016886:
    pop {r4, pc}                        @ 08016886
ENDFUNC fn_0801682C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801680C - key processing of one 10 ms tick
@ Replaces : 0x0801680C FUN_0801680C (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved: replaces the unused r7 of v2.05)
@ Context  : main (loop step 4 of SYS; the power-on window loop of CAL calls it too, v2.05 0x0800EAB6)
@ RAM      : reads key_remote_ev 0x20008069 and key_remote_code 0x2000806D
@ Spec     : analysis/keys_setup.md 1, 2.1; DESIGN.md 3.5
@ -----------------------------------------------------------------------------
FUNC fn_0801680C
    push {r4, lr}                       @ 0801680C

@ first the physical keys, then their events, then a remote key code if the serial link left one
    bl process_pg8_15_press_release     @ 0801680E
    bl fn_0801682C                      @ 08016812

@ key_remote_ev != 0: run the remote key (fn_08014AE6 clears the flag)
    ldr r0, =key_remote_ev              @ 08016816
    ldrb r0, [r0]                       @ 0801681A
    cmp r0, #0                          @ 0801681C
    beq .L801680c_0801682A              @ 0801681E
    ldr r0, =key_remote_code            @ 08016820
    ldrb r0, [r0]                       @ 08016824
    bl fn_08014AE6                      @ 08016826
@ reached from 0801681E beq (equal / zero) after cmp r0, #0
.L801680c_0801682A:
    pop {r4, pc}                        @ 0801682A
ENDFUNC fn_0801680C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08014AE6 - run a key code received over the serial link
@ Replaces : 0x08014AE6 FUN_08014AE6 (v2.05)
@ In       : key_remote_code (0x2000806D): 1..8 short press, 0x81..0x88 long press
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r3 is pushed and popped only as stack padding, as in v2.05)
@ Context  : main (fn_0801680C)
@ RAM      : clears key_remote_ev 0x20008069 and 0x2000801B, 0x2000801D; reads key_remote_code 0x2000806D
@ Spec     : analysis/keys_setup.md 1 (Remote key injection)
@ -----------------------------------------------------------------------------
FUNC fn_08014AE6
    push {r3, r4, r5, lr}               @ 08014AE6
    movs r4, r0                         @ 08014AE8

@ r5 = key bits to inject (0 = none); consume the request and end the log-record composition as a key press does
    movs r5, #0                         @ 08014AEA
    movs r0, #0                         @ 08014AEC
    ldr r1, =key_remote_ev              @ 08014AEE
    strb r0, [r1]                       @ 08014AF2
    movs r0, #0                         @ 08014AF4
    ldr r1, =v_2000801B                 @ 08014AF6
    strb r0, [r1]                       @ 08014AF8
    movs r0, #0                         @ 08014AFA
    ldr r1, =v_2000801D                 @ 08014AFC
    strb r0, [r1]                       @ 08014AFE
    bl pwr_bl_restart                   @ IMP-07: a key injected over the serial link counts as a key press

@ codes 1..8 map to RANGE, HOLD, REL, PEAK, MODE, MIN/MAX, MEM, SETUP: a short press of that key
    ldr r0, =key_remote_code            @ 08014B00
    ldrb r0, [r0]                       @ 08014B04
    cmp r0, #1                          @ 08014B06
    beq .L8014ae6_08014B24              @ 08014B08
    bcc .L8014ae6_08014B52              @ 08014B0A
    cmp r0, #3                          @ 08014B0C
    beq .L8014ae6_08014B30              @ 08014B0E
    bcc .L8014ae6_08014B2A              @ 08014B10
    cmp r0, #5                          @ 08014B12
    beq .L8014ae6_08014B3C              @ 08014B14
    bcc .L8014ae6_08014B36              @ 08014B16
    cmp r0, #7                          @ 08014B18
    beq .L8014ae6_08014B48              @ 08014B1A
    bcc .L8014ae6_08014B42              @ 08014B1C
    cmp r0, #8                          @ 08014B1E
    beq .L8014ae6_08014B4E              @ 08014B20
    b .L8014ae6_08014B52                @ 08014B22
@ reached from 08014B08 beq (equal / zero) after cmp r0, #1
.L8014ae6_08014B24:
    movs r0, #0x10                      @ 08014B24
    movs r5, r0                         @ 08014B26
    b .L8014ae6_08014B52                @ 08014B28
@ reached from 08014B10 bcc (unsigned <) after cmp r0, #3
.L8014ae6_08014B2A:
    movs r0, #0x20                      @ 08014B2A
    movs r5, r0                         @ 08014B2C
    b .L8014ae6_08014B52                @ 08014B2E
@ reached from 08014B0E beq (equal / zero) after cmp r0, #3
.L8014ae6_08014B30:
    movs r0, #0x40                      @ 08014B30
    movs r5, r0                         @ 08014B32
    b .L8014ae6_08014B52                @ 08014B34
@ reached from 08014B16 bcc (unsigned <) after cmp r0, #5
.L8014ae6_08014B36:
    movs r0, #0x80                      @ 08014B36
    movs r5, r0                         @ 08014B38
    b .L8014ae6_08014B52                @ 08014B3A
@ reached from 08014B14 beq (equal / zero) after cmp r0, #5
.L8014ae6_08014B3C:
    movs r0, #1                         @ 08014B3C
    movs r5, r0                         @ 08014B3E
    b .L8014ae6_08014B52                @ 08014B40
@ reached from 08014B1C bcc (unsigned <) after cmp r0, #7
.L8014ae6_08014B42:
    movs r0, #4                         @ 08014B42
    movs r5, r0                         @ 08014B44
    b .L8014ae6_08014B52                @ 08014B46
@ reached from 08014B1A beq (equal / zero) after cmp r0, #7
.L8014ae6_08014B48:
    movs r0, #8                         @ 08014B48
    movs r5, r0                         @ 08014B4A
    b .L8014ae6_08014B52                @ 08014B4C
@ reached from 08014B20 beq (equal / zero) after cmp r0, #8
.L8014ae6_08014B4E:
    movs r0, #2                         @ 08014B4E
    movs r5, r0                         @ 08014B50

@ a short-press code was found: run handle_pg8_15_short_press
@ reached from 08014B0A bcc (unsigned <) after cmp r0, #1
@              and from 08014B22 b (jump)
@              and from 08014B28 b (jump)
@              ... and 6 more
.L8014ae6_08014B52:
    uxtb r5, r5                         @ 08014B52
    cmp r5, #0                          @ 08014B54
    beq .L8014ae6_08014B62              @ 08014B56
    movs r0, r5                         @ 08014B58
    uxtb r0, r0                         @ 08014B5A
    bl handle_pg8_15_short_press        @ 08014B5C
    b .L8014ae6_08014BC2                @ 08014B60

@ else codes 0x81..0x88 map to the same keys: a long press
@ reached from 08014B56 beq (equal / zero) after cmp r5, #0
.L8014ae6_08014B62:
    ldr r0, =key_remote_code            @ 08014B62
    ldrb r0, [r0]                       @ 08014B66
    cmp r0, #0x81                       @ 08014B68
    beq .L8014ae6_08014B86              @ 08014B6A
    bcc .L8014ae6_08014BB4              @ 08014B6C
    cmp r0, #0x83                       @ 08014B6E
    beq .L8014ae6_08014B92              @ 08014B70
    bcc .L8014ae6_08014B8C              @ 08014B72
    cmp r0, #0x85                       @ 08014B74
    beq .L8014ae6_08014B9E              @ 08014B76
    bcc .L8014ae6_08014B98              @ 08014B78
    cmp r0, #0x87                       @ 08014B7A
    beq .L8014ae6_08014BAA              @ 08014B7C
    bcc .L8014ae6_08014BA4              @ 08014B7E
    cmp r0, #0x88                       @ 08014B80
    beq .L8014ae6_08014BB0              @ 08014B82
    b .L8014ae6_08014BB4                @ 08014B84
@ reached from 08014B6A beq (equal / zero) after cmp r0, #0x81
.L8014ae6_08014B86:
    movs r0, #0x10                      @ 08014B86
    movs r5, r0                         @ 08014B88
    b .L8014ae6_08014BB4                @ 08014B8A
@ reached from 08014B72 bcc (unsigned <) after cmp r0, #0x83
.L8014ae6_08014B8C:
    movs r0, #0x20                      @ 08014B8C
    movs r5, r0                         @ 08014B8E
    b .L8014ae6_08014BB4                @ 08014B90
@ reached from 08014B70 beq (equal / zero) after cmp r0, #0x83
.L8014ae6_08014B92:
    movs r0, #0x40                      @ 08014B92
    movs r5, r0                         @ 08014B94
    b .L8014ae6_08014BB4                @ 08014B96
@ reached from 08014B78 bcc (unsigned <) after cmp r0, #0x85
.L8014ae6_08014B98:
    movs r0, #0x80                      @ 08014B98
    movs r5, r0                         @ 08014B9A
    b .L8014ae6_08014BB4                @ 08014B9C
@ reached from 08014B76 beq (equal / zero) after cmp r0, #0x85
.L8014ae6_08014B9E:
    movs r0, #1                         @ 08014B9E
    movs r5, r0                         @ 08014BA0
    b .L8014ae6_08014BB4                @ 08014BA2
@ reached from 08014B7E bcc (unsigned <) after cmp r0, #0x87
.L8014ae6_08014BA4:
    movs r0, #4                         @ 08014BA4
    movs r5, r0                         @ 08014BA6
    b .L8014ae6_08014BB4                @ 08014BA8
@ reached from 08014B7C beq (equal / zero) after cmp r0, #0x87
.L8014ae6_08014BAA:
    movs r0, #8                         @ 08014BAA
    movs r5, r0                         @ 08014BAC
    b .L8014ae6_08014BB4                @ 08014BAE
@ reached from 08014B82 beq (equal / zero) after cmp r0, #0x88
.L8014ae6_08014BB0:
    movs r0, #2                         @ 08014BB0
    movs r5, r0                         @ 08014BB2

@ a long-press code was found: run handle_pg8_15_long_press
@ reached from 08014B6C bcc (unsigned <) after cmp r0, #0x81
@              and from 08014B84 b (jump)
@              and from 08014B8A b (jump)
@              ... and 6 more
.L8014ae6_08014BB4:
    uxtb r5, r5                         @ 08014BB4
    cmp r5, #0                          @ 08014BB6
    beq .L8014ae6_08014BC2              @ 08014BB8
    movs r0, r5                         @ 08014BBA
    uxtb r0, r0                         @ 08014BBC
    bl handle_pg8_15_long_press         @ 08014BBE
@ reached from 08014B60 b (jump)
@              and from 08014BB8 beq (equal / zero) after cmp r5, #0
.L8014ae6_08014BC2:
    pop {r3, r4, r5, pc}                @ 08014BC2
ENDFUNC fn_08014AE6
    .ltorg
