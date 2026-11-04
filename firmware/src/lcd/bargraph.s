@ =============================================================================
@ bargraph.s - LCD: 26-segment bargraph, polarity, tick groups and range labels (DESIGN.md 6.7)
@
@ Replaces 0x08018B14 .. 0x08019408 of v2.05 (analysis/lcd_map.md section 3).  The bar count lives in 0x20008041; segment
@ k (1..25) is set when count >= k, segment 0 is set by bargraph_count_from_value.  The instruction streams are v2.05's.
@ Context: main only.
@
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.lcd.bargraph, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08018B14 - bargraph refresh on request
@ Replaces : 0x08018B14 FUN_08018B14 (v2.05, 58 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by fn_08016D34 when 0x2000805E is set
@ RAM      : clears 0x2000805E; reads meter_mode (0x2000803C); production: reads lowz_bar_hold (mres/lowz.s, LowZ settling
@            mean: the bargraph keeps its segments)
@ Spec     : analysis/lcd_map.md 3 (the bargraph is switched off for modes 5, 6, 7, 8, 12)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08018B14
    push {r7, lr}                            @ 08018B14
    movs r0, #0                              @ 08018B16
    ldr r1, =v_2000805E                      @ 08018B18 &bargraph update request
    strb r0, [r1, #0]                        @ 08018B1C
    ldr r0, =meter_mode                      @ 08018B1E &meter_mode
    ldrb r0, [r0, #0]                        @ 08018B22
    @ modes 6..8 (FREQ, PULSE, DUTY), 12 (CAP) and 5 (TEMP) show no bargraph: nothing is drawn
    cmp r0, #6                               @ 08018B24 branch if mode < 6 (6 = FREQ)
    blt .L08018B32                           @ 08018B26
    ldr r0, =meter_mode                      @ 08018B28 &meter_mode
    ldrb r0, [r0, #0]                        @ 08018B2C
    cmp r0, #9                               @ 08018B2E branch if mode < 9 (9 = OHM)
    blt .L08018B46                           @ 08018B30
.L08018B32:                                @ reached from 08018B26 blt (signed <); falls in
    ldr r0, =meter_mode                      @ 08018B32 &meter_mode
    ldrb r0, [r0, #0]                        @ 08018B36
    cmp r0, #12                              @ 08018B38 branch if mode == 12 (12 = CAP)
    beq .L08018B46                           @ 08018B3A
    ldr r0, =meter_mode                      @ 08018B3C &meter_mode
    ldrb r0, [r0, #0]                        @ 08018B40
    cmp r0, #5                               @ 08018B42 branch if mode != 5 (5 = TEMP)
    bne .L08018B48                           @ 08018B44
.L08018B46:                                @ reached from 08018B30 blt (signed <); 08018B3A beq (equal / zero); falls in
    b .L08018B4C                             @ 08018B46
.L08018B48:                                @ reached from 08018B44 bne (not equal / non-zero)
    @ every other mode: lcd_update_bargraph
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cbnz r0, 1f
    ldr r0, =lowz_bar_hold
    ldrb r0, [r0]
    cbnz r0, .L08018B4C                     @ LowZ settling mean after an AC/DC re-apply: the bar keeps its segments
1:
    bl lcd_update_bargraph                   @ 08018B48
.L08018B4C:                                @ reached from 08018B46 b; falls in
    pop {r0, pc}                             @ 08018B4C
ENDFUNC fn_08018B14
    .ltorg

@ -----------------------------------------------------------------------------
@ lcd_update_bargraph - set or clear the 25 bargraph segments for the current bar count
@ Replaces : 0x08018B80 lcd_update_bargraph (v2.05, 916 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : calls fn_08018F14 (which sets the count 0x20008041); read-modify-writes lcd_shadow words 0, 2, 4, 6
@ Spec     : analysis/lcd_map.md 3 (segment table). For k = 1..25: when count >= k the segment k is set, otherwise
@            fn_08019408(25, k) clears the segments k..25 and the following blocks are skipped over cheaply
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC lcd_update_bargraph
    push {r7, lr}                            @ 08018B80
    @ fn_08018F14 computes the bar count in 0x20008041 and the scale / polarity
    bl fn_08018F14                           @ 08018B82
    @ IMP-17: the same end state in one pass over the segment table: segments 1..count set, count+1..25 cleared, no other
    @ bit touched.  v2.05 calls fn_08019408(25, k) for every k above the count (up to 25 calls of up to 25 clear blocks);
    @ the production image updates the bargraph on every conversion, where that cascade took 28 % of the CPU in BEEP.
    ldr r0, =v_20008041
    ldrb r0, [r0]                            @ r0 = count (0..25)
    ldr r1, =lcd_bar_seg_table               @ entries of 2 bytes: word offset, bit mask (segment 1 first)
    ldr r2, =lcd_shadow
    movs r3, #1                              @ k = 1
1:  ldrb r12, [r1], #1                       @ word offset (0, 8, 16, 24)
    ldrb r7, [r1], #1                        @ bit mask (r7 and lr are saved by the push at the entry)
    ldr lr, [r2, r12]
    cmp r3, r0
    ite ls
    orrls lr, lr, r7                         @ k <= count: segment on
    bichi lr, lr, r7                         @ k > count: segment off
    str lr, [r2, r12]
    adds r3, r3, #1
    cmp r3, #25
    bls 1b
    b .L08018F0A                             @ the commit request, as v2.05
    @ segment 1 (w2 bit 1): count >= 1 sets it, otherwise clear segments 1..25
    ldr r0, =v_20008041                      @ 08018B86 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018B8A
    cmp r0, #0                               @ 08018B8C branch if bargraph segment count == 0
    beq .L08018BA2                           @ 08018B8E
    ldr r0, =lcd_shadow                      @ 08018B90 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018B94
    orrs.w r0, r0, #2                        @ 08018B96
    ldr r1, =lcd_shadow                      @ 08018B9A &LCD shadow
    str r0, [r1, #8]                         @ 08018B9E w2 |= 0x2: bargraph segment 1
    b .L08018BAA                             @ 08018BA0
.L08018BA2:                                @ reached from 08018B8E beq (equal / zero)
    movs r1, #1                              @ 08018BA2
    movs r0, #25                             @ 08018BA4
    bl fn_08019408                           @ 08018BA6
.L08018BAA:                                @ reached from 08018BA0 b; falls in
    @ segment 2 (w4 bit 1)
    ldr r0, =v_20008041                      @ 08018BAA &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018BAE
    cmp r0, #2                               @ 08018BB0 branch if bargraph segment count < 2
    blt .L08018BC6                           @ 08018BB2
    ldr r0, =lcd_shadow                      @ 08018BB4 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018BB8
    orrs.w r0, r0, #2                        @ 08018BBA
    ldr r1, =lcd_shadow                      @ 08018BBE &LCD shadow
    str r0, [r1, #16]                        @ 08018BC2 w4 |= 0x2: bargraph segment 2
    b .L08018BCE                             @ 08018BC4
.L08018BC6:                                @ reached from 08018BB2 blt (signed <)
    movs r1, #2                              @ 08018BC6
    movs r0, #25                             @ 08018BC8
    bl fn_08019408                           @ 08018BCA
.L08018BCE:                                @ reached from 08018BC4 b; falls in
    @ segment 3 (w6 bit 1)
    ldr r0, =v_20008041                      @ 08018BCE &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018BD2
    cmp r0, #3                               @ 08018BD4 branch if bargraph segment count < 3
    blt .L08018BEA                           @ 08018BD6
    ldr r0, =lcd_shadow                      @ 08018BD8 &LCD shadow
    ldr r0, [r0, #24]                        @ 08018BDC
    orrs.w r0, r0, #2                        @ 08018BDE
    ldr r1, =lcd_shadow                      @ 08018BE2 &LCD shadow
    str r0, [r1, #24]                        @ 08018BE6 w6 |= 0x2: bargraph segment 3
    b .L08018BF2                             @ 08018BE8
.L08018BEA:                                @ reached from 08018BD6 blt (signed <)
    movs r1, #3                              @ 08018BEA
    movs r0, #25                             @ 08018BEC
    bl fn_08019408                           @ 08018BEE
.L08018BF2:                                @ reached from 08018BE8 b; falls in
    @ segment 4 (w6 bit 2)
    ldr r0, =v_20008041                      @ 08018BF2 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018BF6
    cmp r0, #4                               @ 08018BF8 branch if bargraph segment count < 4
    blt .L08018C0E                           @ 08018BFA
    ldr r0, =lcd_shadow                      @ 08018BFC &LCD shadow
    ldr r0, [r0, #24]                        @ 08018C00
    orrs.w r0, r0, #4                        @ 08018C02
    ldr r1, =lcd_shadow                      @ 08018C06 &LCD shadow
    str r0, [r1, #24]                        @ 08018C0A w6 |= 0x4: bargraph segment 4
    b .L08018C16                             @ 08018C0C
.L08018C0E:                                @ reached from 08018BFA blt (signed <)
    movs r1, #4                              @ 08018C0E
    movs r0, #25                             @ 08018C10
    bl fn_08019408                           @ 08018C12
.L08018C16:                                @ reached from 08018C0C b; falls in
    @ segment 5 (w4 bit 2)
    ldr r0, =v_20008041                      @ 08018C16 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018C1A
    cmp r0, #5                               @ 08018C1C branch if bargraph segment count < 5
    blt .L08018C32                           @ 08018C1E
    ldr r0, =lcd_shadow                      @ 08018C20 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018C24
    orrs.w r0, r0, #4                        @ 08018C26
    ldr r1, =lcd_shadow                      @ 08018C2A &LCD shadow
    str r0, [r1, #16]                        @ 08018C2E w4 |= 0x4: bargraph segment 5
    b .L08018C3A                             @ 08018C30
.L08018C32:                                @ reached from 08018C1E blt (signed <)
    movs r1, #5                              @ 08018C32
    movs r0, #25                             @ 08018C34
    bl fn_08019408                           @ 08018C36
.L08018C3A:                                @ reached from 08018C30 b; falls in
    @ segment 6 (w2 bit 2)
    ldr r0, =v_20008041                      @ 08018C3A &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018C3E
    cmp r0, #6                               @ 08018C40 branch if bargraph segment count < 6
    blt .L08018C56                           @ 08018C42
    ldr r0, =lcd_shadow                      @ 08018C44 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018C48
    orrs.w r0, r0, #4                        @ 08018C4A
    ldr r1, =lcd_shadow                      @ 08018C4E &LCD shadow
    str r0, [r1, #8]                         @ 08018C52 w2 |= 0x4: bargraph segment 6
    b .L08018C5E                             @ 08018C54
.L08018C56:                                @ reached from 08018C42 blt (signed <)
    movs r1, #6                              @ 08018C56
    movs r0, #25                             @ 08018C58
    bl fn_08019408                           @ 08018C5A
.L08018C5E:                                @ reached from 08018C54 b; falls in
    @ segment 7 (w0 bit 2)
    ldr r0, =v_20008041                      @ 08018C5E &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018C62
    cmp r0, #7                               @ 08018C64 branch if bargraph segment count < 7
    blt .L08018C7A                           @ 08018C66
    ldr r0, =lcd_shadow                      @ 08018C68 &LCD shadow
    ldr r0, [r0, #0]                         @ 08018C6C
    orrs.w r0, r0, #4                        @ 08018C6E
    ldr r1, =lcd_shadow                      @ 08018C72 &LCD shadow
    str r0, [r1, #0]                         @ 08018C76 w0 |= 0x4: bargraph segment 7
    b .L08018C82                             @ 08018C78
.L08018C7A:                                @ reached from 08018C66 blt (signed <)
    movs r1, #7                              @ 08018C7A
    movs r0, #25                             @ 08018C7C
    bl fn_08019408                           @ 08018C7E
.L08018C82:                                @ reached from 08018C78 b; falls in
    @ segment 8 (w0 bit 3)
    ldr r0, =v_20008041                      @ 08018C82 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018C86
    cmp r0, #8                               @ 08018C88 branch if bargraph segment count < 8
    blt .L08018C9E                           @ 08018C8A
    ldr r0, =lcd_shadow                      @ 08018C8C &LCD shadow
    ldr r0, [r0, #0]                         @ 08018C90
    orrs.w r0, r0, #8                        @ 08018C92
    ldr r1, =lcd_shadow                      @ 08018C96 &LCD shadow
    str r0, [r1, #0]                         @ 08018C9A w0 |= 0x8: bargraph segment 8
    b .L08018CA6                             @ 08018C9C
.L08018C9E:                                @ reached from 08018C8A blt (signed <)
    movs r1, #8                              @ 08018C9E
    movs r0, #25                             @ 08018CA0
    bl fn_08019408                           @ 08018CA2
.L08018CA6:                                @ reached from 08018C9C b; falls in
    @ segment 9 (w2 bit 3)
    ldr r0, =v_20008041                      @ 08018CA6 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018CAA
    cmp r0, #9                               @ 08018CAC branch if bargraph segment count < 9
    blt .L08018CC2                           @ 08018CAE
    ldr r0, =lcd_shadow                      @ 08018CB0 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018CB4
    orrs.w r0, r0, #8                        @ 08018CB6
    ldr r1, =lcd_shadow                      @ 08018CBA &LCD shadow
    str r0, [r1, #8]                         @ 08018CBE w2 |= 0x8: bargraph segment 9
    b .L08018CCA                             @ 08018CC0
.L08018CC2:                                @ reached from 08018CAE blt (signed <)
    movs r1, #9                              @ 08018CC2
    movs r0, #25                             @ 08018CC4
    bl fn_08019408                           @ 08018CC6
.L08018CCA:                                @ reached from 08018CC0 b; falls in
    @ segment 10 (w4 bit 3)
    ldr r0, =v_20008041                      @ 08018CCA &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018CCE
    cmp r0, #10                              @ 08018CD0 branch if bargraph segment count < 10
    blt .L08018CE6                           @ 08018CD2
    ldr r0, =lcd_shadow                      @ 08018CD4 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018CD8
    orrs.w r0, r0, #8                        @ 08018CDA
    ldr r1, =lcd_shadow                      @ 08018CDE &LCD shadow
    str r0, [r1, #16]                        @ 08018CE2 w4 |= 0x8: bargraph segment 10
    b .L08018CEE                             @ 08018CE4
.L08018CE6:                                @ reached from 08018CD2 blt (signed <)
    movs r1, #10                             @ 08018CE6
    movs r0, #25                             @ 08018CE8
    bl fn_08019408                           @ 08018CEA
.L08018CEE:                                @ reached from 08018CE4 b; falls in
    @ segment 11 (w6 bit 3)
    ldr r0, =v_20008041                      @ 08018CEE &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018CF2
    cmp r0, #11                              @ 08018CF4 branch if bargraph segment count < 11
    blt .L08018D0A                           @ 08018CF6
    ldr r0, =lcd_shadow                      @ 08018CF8 &LCD shadow
    ldr r0, [r0, #24]                        @ 08018CFC
    orrs.w r0, r0, #8                        @ 08018CFE
    ldr r1, =lcd_shadow                      @ 08018D02 &LCD shadow
    str r0, [r1, #24]                        @ 08018D06 w6 |= 0x8: bargraph segment 11
    b .L08018D12                             @ 08018D08
.L08018D0A:                                @ reached from 08018CF6 blt (signed <)
    movs r1, #11                             @ 08018D0A
    movs r0, #25                             @ 08018D0C
    bl fn_08019408                           @ 08018D0E
.L08018D12:                                @ reached from 08018D08 b; falls in
    @ segment 12 (w6 bit 4)
    ldr r0, =v_20008041                      @ 08018D12 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018D16
    cmp r0, #12                              @ 08018D18 branch if bargraph segment count < 12
    blt .L08018D2E                           @ 08018D1A
    ldr r0, =lcd_shadow                      @ 08018D1C &LCD shadow
    ldr r0, [r0, #24]                        @ 08018D20
    orrs.w r0, r0, #16                       @ 08018D22
    ldr r1, =lcd_shadow                      @ 08018D26 &LCD shadow
    str r0, [r1, #24]                        @ 08018D2A w6 |= 0x10: bargraph segment 12
    b .L08018D36                             @ 08018D2C
.L08018D2E:                                @ reached from 08018D1A blt (signed <)
    movs r1, #12                             @ 08018D2E
    movs r0, #25                             @ 08018D30
    bl fn_08019408                           @ 08018D32
.L08018D36:                                @ reached from 08018D2C b; falls in
    @ segment 13 (w4 bit 4)
    ldr r0, =v_20008041                      @ 08018D36 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018D3A
    cmp r0, #13                              @ 08018D3C branch if bargraph segment count < 13
    blt .L08018D52                           @ 08018D3E
    ldr r0, =lcd_shadow                      @ 08018D40 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018D44
    orrs.w r0, r0, #16                       @ 08018D46
    ldr r1, =lcd_shadow                      @ 08018D4A &LCD shadow
    str r0, [r1, #16]                        @ 08018D4E w4 |= 0x10: bargraph segment 13
    b .L08018D5A                             @ 08018D50
.L08018D52:                                @ reached from 08018D3E blt (signed <)
    movs r1, #13                             @ 08018D52
    movs r0, #25                             @ 08018D54
    bl fn_08019408                           @ 08018D56
.L08018D5A:                                @ reached from 08018D50 b; falls in
    @ segment 14 (w2 bit 4)
    ldr r0, =v_20008041                      @ 08018D5A &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018D5E
    cmp r0, #14                              @ 08018D60 branch if bargraph segment count < 14
    blt .L08018D76                           @ 08018D62
    ldr r0, =lcd_shadow                      @ 08018D64 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018D68
    orrs.w r0, r0, #16                       @ 08018D6A
    ldr r1, =lcd_shadow                      @ 08018D6E &LCD shadow
    str r0, [r1, #8]                         @ 08018D72 w2 |= 0x10: bargraph segment 14
    b .L08018D7E                             @ 08018D74
.L08018D76:                                @ reached from 08018D62 blt (signed <)
    movs r1, #14                             @ 08018D76
    movs r0, #25                             @ 08018D78
    bl fn_08019408                           @ 08018D7A
.L08018D7E:                                @ reached from 08018D74 b; falls in
    @ segment 15 (w0 bit 4)
    ldr r0, =v_20008041                      @ 08018D7E &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018D82
    cmp r0, #15                              @ 08018D84 branch if bargraph segment count < 15
    blt .L08018D9A                           @ 08018D86
    ldr r0, =lcd_shadow                      @ 08018D88 &LCD shadow
    ldr r0, [r0, #0]                         @ 08018D8C
    orrs.w r0, r0, #16                       @ 08018D8E
    ldr r1, =lcd_shadow                      @ 08018D92 &LCD shadow
    str r0, [r1, #0]                         @ 08018D96 w0 |= 0x10: bargraph segment 15
    b .L08018DA2                             @ 08018D98
.L08018D9A:                                @ reached from 08018D86 blt (signed <)
    movs r1, #15                             @ 08018D9A
    movs r0, #25                             @ 08018D9C
    bl fn_08019408                           @ 08018D9E
.L08018DA2:                                @ reached from 08018D98 b; falls in
    @ segment 16 (w0 bit 5)
    ldr r0, =v_20008041                      @ 08018DA2 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018DA6
    cmp r0, #16                              @ 08018DA8 branch if bargraph segment count < 16
    blt .L08018DBE                           @ 08018DAA
    ldr r0, =lcd_shadow                      @ 08018DAC &LCD shadow
    ldr r0, [r0, #0]                         @ 08018DB0
    orrs.w r0, r0, #32                       @ 08018DB2
    ldr r1, =lcd_shadow                      @ 08018DB6 &LCD shadow
    str r0, [r1, #0]                         @ 08018DBA w0 |= 0x20: bargraph segment 16
    b .L08018DC6                             @ 08018DBC
.L08018DBE:                                @ reached from 08018DAA blt (signed <)
    movs r1, #16                             @ 08018DBE
    movs r0, #25                             @ 08018DC0
    bl fn_08019408                           @ 08018DC2
.L08018DC6:                                @ reached from 08018DBC b; falls in
    @ segment 17 (w2 bit 5)
    ldr r0, =v_20008041                      @ 08018DC6 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018DCA
    cmp r0, #17                              @ 08018DCC branch if bargraph segment count < 17
    blt .L08018DE2                           @ 08018DCE
    ldr r0, =lcd_shadow                      @ 08018DD0 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018DD4
    orrs.w r0, r0, #32                       @ 08018DD6
    ldr r1, =lcd_shadow                      @ 08018DDA &LCD shadow
    str r0, [r1, #8]                         @ 08018DDE w2 |= 0x20: bargraph segment 17
    b .L08018DEA                             @ 08018DE0
.L08018DE2:                                @ reached from 08018DCE blt (signed <)
    movs r1, #17                             @ 08018DE2
    movs r0, #25                             @ 08018DE4
    bl fn_08019408                           @ 08018DE6
.L08018DEA:                                @ reached from 08018DE0 b; falls in
    @ segment 18 (w4 bit 5)
    ldr r0, =v_20008041                      @ 08018DEA &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018DEE
    cmp r0, #18                              @ 08018DF0 branch if bargraph segment count < 18
    blt .L08018E06                           @ 08018DF2
    ldr r0, =lcd_shadow                      @ 08018DF4 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018DF8
    orrs.w r0, r0, #32                       @ 08018DFA
    ldr r1, =lcd_shadow                      @ 08018DFE &LCD shadow
    str r0, [r1, #16]                        @ 08018E02 w4 |= 0x20: bargraph segment 18
    b .L08018E0E                             @ 08018E04
.L08018E06:                                @ reached from 08018DF2 blt (signed <)
    movs r1, #18                             @ 08018E06
    movs r0, #25                             @ 08018E08
    bl fn_08019408                           @ 08018E0A
.L08018E0E:                                @ reached from 08018E04 b; falls in
    @ segment 19 (w6 bit 5)
    ldr r0, =v_20008041                      @ 08018E0E &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018E12
    cmp r0, #19                              @ 08018E14 branch if bargraph segment count < 19
    blt .L08018E2A                           @ 08018E16
    ldr r0, =lcd_shadow                      @ 08018E18 &LCD shadow
    ldr r0, [r0, #24]                        @ 08018E1C
    orrs.w r0, r0, #32                       @ 08018E1E
    ldr r1, =lcd_shadow                      @ 08018E22 &LCD shadow
    str r0, [r1, #24]                        @ 08018E26 w6 |= 0x20: bargraph segment 19
    b .L08018E32                             @ 08018E28
.L08018E2A:                                @ reached from 08018E16 blt (signed <)
    movs r1, #19                             @ 08018E2A
    movs r0, #25                             @ 08018E2C
    bl fn_08019408                           @ 08018E2E
.L08018E32:                                @ reached from 08018E28 b; falls in
    @ segment 20 (w6 bit 6)
    ldr r0, =v_20008041                      @ 08018E32 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018E36
    cmp r0, #20                              @ 08018E38 branch if bargraph segment count < 20
    blt .L08018E4E                           @ 08018E3A
    ldr r0, =lcd_shadow                      @ 08018E3C &LCD shadow
    ldr r0, [r0, #24]                        @ 08018E40
    orrs.w r0, r0, #64                       @ 08018E42
    ldr r1, =lcd_shadow                      @ 08018E46 &LCD shadow
    str r0, [r1, #24]                        @ 08018E4A w6 |= 0x40: bargraph segment 20
    b .L08018E56                             @ 08018E4C
.L08018E4E:                                @ reached from 08018E3A blt (signed <)
    movs r1, #20                             @ 08018E4E
    movs r0, #25                             @ 08018E50
    bl fn_08019408                           @ 08018E52
.L08018E56:                                @ reached from 08018E4C b; falls in
    @ segment 21 (w4 bit 6)
    ldr r0, =v_20008041                      @ 08018E56 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018E5A
    cmp r0, #21                              @ 08018E5C branch if bargraph segment count < 21
    blt .L08018E72                           @ 08018E5E
    ldr r0, =lcd_shadow                      @ 08018E60 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018E64
    orrs.w r0, r0, #64                       @ 08018E66
    ldr r1, =lcd_shadow                      @ 08018E6A &LCD shadow
    str r0, [r1, #16]                        @ 08018E6E w4 |= 0x40: bargraph segment 21
    b .L08018E7A                             @ 08018E70
.L08018E72:                                @ reached from 08018E5E blt (signed <)
    movs r1, #21                             @ 08018E72
    movs r0, #25                             @ 08018E74
    bl fn_08019408                           @ 08018E76
.L08018E7A:                                @ reached from 08018E70 b; falls in
    @ segment 22 (w2 bit 6)
    ldr r0, =v_20008041                      @ 08018E7A &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018E7E
    cmp r0, #22                              @ 08018E80 branch if bargraph segment count < 22
    blt .L08018E96                           @ 08018E82
    ldr r0, =lcd_shadow                      @ 08018E84 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018E88
    orrs.w r0, r0, #64                       @ 08018E8A
    ldr r1, =lcd_shadow                      @ 08018E8E &LCD shadow
    str r0, [r1, #8]                         @ 08018E92 w2 |= 0x40: bargraph segment 22
    b .L08018E9E                             @ 08018E94
.L08018E96:                                @ reached from 08018E82 blt (signed <)
    movs r1, #22                             @ 08018E96
    movs r0, #25                             @ 08018E98
    bl fn_08019408                           @ 08018E9A
.L08018E9E:                                @ reached from 08018E94 b; falls in
    @ segment 23 (w0 bit 6)
    ldr r0, =v_20008041                      @ 08018E9E &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018EA2
    cmp r0, #23                              @ 08018EA4 branch if bargraph segment count < 23
    blt .L08018EBA                           @ 08018EA6
    ldr r0, =lcd_shadow                      @ 08018EA8 &LCD shadow
    ldr r0, [r0, #0]                         @ 08018EAC
    orrs.w r0, r0, #64                       @ 08018EAE
    ldr r1, =lcd_shadow                      @ 08018EB2 &LCD shadow
    str r0, [r1, #0]                         @ 08018EB6 w0 |= 0x40: bargraph segment 23
    b .L08018EC2                             @ 08018EB8
.L08018EBA:                                @ reached from 08018EA6 blt (signed <)
    movs r1, #23                             @ 08018EBA
    movs r0, #25                             @ 08018EBC
    bl fn_08019408                           @ 08018EBE
.L08018EC2:                                @ reached from 08018EB8 b; falls in
    @ segment 24 (w0 bit 7)
    ldr r0, =v_20008041                      @ 08018EC2 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018EC6
    cmp r0, #24                              @ 08018EC8 branch if bargraph segment count < 24
    blt .L08018EDE                           @ 08018ECA
    ldr r0, =lcd_shadow                      @ 08018ECC &LCD shadow
    ldr r0, [r0, #0]                         @ 08018ED0
    orrs.w r0, r0, #128                      @ 08018ED2
    ldr r1, =lcd_shadow                      @ 08018ED6 &LCD shadow
    str r0, [r1, #0]                         @ 08018EDA w0 |= 0x80: bargraph segment 24
    b .L08018EE6                             @ 08018EDC
.L08018EDE:                                @ reached from 08018ECA blt (signed <)
    movs r1, #24                             @ 08018EDE
    movs r0, #25                             @ 08018EE0
    bl fn_08019408                           @ 08018EE2
.L08018EE6:                                @ reached from 08018EDC b; falls in
    @ segment 25 (w2 bit 7)
    ldr r0, =v_20008041                      @ 08018EE6 &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08018EEA
    cmp r0, #25                              @ 08018EEC branch if bargraph segment count < 25
    blt .L08018F02                           @ 08018EEE
    ldr r0, =lcd_shadow                      @ 08018EF0 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018EF4
    orrs.w r0, r0, #128                      @ 08018EF6
    ldr r1, =lcd_shadow                      @ 08018EFA &LCD shadow
    str r0, [r1, #8]                         @ 08018EFE w2 |= 0x80: bargraph segment 25
    b .L08018F0A                             @ 08018F00
.L08018F02:                                @ reached from 08018EEE blt (signed <)
    movs r1, #25                             @ 08018F02
    movs r0, #25                             @ 08018F04
    bl fn_08019408                           @ 08018F06
.L08018F0A:                                @ reached from 08018F00 b; falls in
    @ bar drawn: ask for a commit

    movs r0, #1                              @ 08018F0A
    ldr r1, =v_2000805B                      @ 08018F0C &LCD commit request
    strb r0, [r1, #0]                        @ 08018F10
    pop {r0, pc}                             @ 08018F12
ENDFUNC lcd_update_bargraph

    .ltorg                                   @ production: the literals of the IMP-17 block
    .section .rodata.lcd.bar, "a", %progbits
@ lcd_bar_seg_table: bargraph segments 1..25 (analysis/lcd_map.md 3, the blocks of lcd_update_bargraph above): byte offset
@ of the lcd_shadow word, bit mask
lcd_bar_seg_table:
    .byte 8, 0x02,  16, 0x02,  24, 0x02,  24, 0x04,  16, 0x04    @ 1 w2b1, 2 w4b1, 3 w6b1, 4 w6b2, 5 w4b2
    .byte 8, 0x04,   0, 0x04,   0, 0x08,   8, 0x08,  16, 0x08    @ 6 w2b2, 7 w0b2, 8 w0b3, 9 w2b3, 10 w4b3
    .byte 24, 0x08, 24, 0x10,  16, 0x10,   8, 0x10,   0, 0x10    @ 11 w6b3, 12 w6b4, 13 w4b4, 14 w2b4, 15 w0b4
    .byte 0, 0x20,   8, 0x20,  16, 0x20,  24, 0x20,  24, 0x40    @ 16 w0b5, 17 w2b5, 18 w4b5, 19 w6b5, 20 w6b6
    .byte 16, 0x40,  8, 0x40,   0, 0x40,   0, 0x80,   8, 0x80    @ 21 w4b6, 22 w2b6, 23 w0b6, 24 w0b7, 25 w2b7
    .size lcd_bar_seg_table, . - lcd_bar_seg_table
    .previous
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08018F14 - choose the bargraph scale for the current mode and range and compute the bar count
@ Replaces : 0x08018F14 FUN_08018F14 (v2.05, 124 bytes)
@ In       : -
@ Out      : -   (bargraph_count_from_value sets 0x20008041 and the bar elements)
@ Context  : main only
@ RAM      : reads meter_mode (0x2000803C), meter_range (0x2000803D)
@ Spec     : analysis/lcd_map.md 3 (param 1 = divisor 400 for mode 0, modes 1..4 range 3, modes 20/21 range 2; param 0 =
@            divisor 2000 for the others).  No call for modes 5..8, 12 and above 24.
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08018F14
    push {r7, lr}                            @ 08018F14
    ldr r0, =meter_mode                      @ 08018F16 &meter_mode
    ldrb r0, [r0, #0]                        @ 08018F1A
    @ mode 0 (LowZ): scale param 1
    cmp r0, #0                               @ 08018F1C branch if mode == 0 (0 = LowZ)
    beq .L08018F4C                           @ 08018F1E
    @ modes 1..4 (DCV, ACV, DCmV, ACmV): param 1 for range 3, else 0
    subs r0, r0, #1                          @ 08018F20
    cmp r0, #3                               @ 08018F22
    bls .L08018F54                           @ 08018F24
    @ modes 9..11 (OHM, BEEP, DIODE): param 0
    subs r0, #8                              @ 08018F26
    cmp r0, #2                               @ 08018F28
    bls .L08018F6E                           @ 08018F2A
    @ modes 13..15 (uVA, mVA, VA): param 0
    subs r0, r0, #4                          @ 08018F2C
    cmp r0, #2                               @ 08018F2E
    bls .L08018F44                           @ 08018F30
    @ modes 16..19 (AC/DC uA, mA): param 0
    subs r0, r0, #3                          @ 08018F32
    cmp r0, #3                               @ 08018F34
    bls .L08018F6E                           @ 08018F36
    @ modes 20, 21 (ACA, DCA): param 1 for range 2, else 0
    subs r0, r0, #4                          @ 08018F38
    cmp r0, #1                               @ 08018F3A
    bls .L08018F76                           @ 08018F3C
    @ modes 22..24 (DC VA): param 0; modes above 24 and the unlisted modes 5..8, 12 end here without a call

    subs r0, r0, #2                          @ 08018F3E
    cmp r0, #2                               @ 08018F40
    bhi .L08018F8E                           @ 08018F42
.L08018F44:                                @ reached from 08018F30 bls (unsigned <=); falls in
    movs r0, #0                              @ 08018F44
    bl bargraph_count_from_value             @ 08018F46
    b .L08018F8E                             @ 08018F4A
.L08018F4C:                                @ reached from 08018F1E beq (equal / zero)
    movs r0, #1                              @ 08018F4C
    bl bargraph_count_from_value             @ 08018F4E
    b .L08018F8E                             @ 08018F52
.L08018F54:                                @ reached from 08018F24 bls (unsigned <=)
    ldr r0, =meter_range                     @ 08018F54 &meter_range
    ldrb r0, [r0, #0]                        @ 08018F58
    cmp r0, #3                               @ 08018F5A branch if meter_range != 3
    bne .L08018F66                           @ 08018F5C
    movs r0, #1                              @ 08018F5E
    bl bargraph_count_from_value             @ 08018F60
    b .L08018F6C                             @ 08018F64
.L08018F66:                                @ reached from 08018F5C bne (not equal / non-zero)
    movs r0, #0                              @ 08018F66
    bl bargraph_count_from_value             @ 08018F68
.L08018F6C:                                @ reached from 08018F64 b; falls in
    b .L08018F8E                             @ 08018F6C
.L08018F6E:                                @ reached from 08018F2A bls (unsigned <=); 08018F36 bls (unsigned <=)
    movs r0, #0                              @ 08018F6E
    bl bargraph_count_from_value             @ 08018F70
    b .L08018F8E                             @ 08018F74
.L08018F76:                                @ reached from 08018F3C bls (unsigned <=)
    ldr r0, =meter_range                     @ 08018F76 &meter_range
    ldrb r0, [r0, #0]                        @ 08018F7A
    cmp r0, #2                               @ 08018F7C branch if meter_range != 2
    bne .L08018F88                           @ 08018F7E
    movs r0, #1                              @ 08018F80
    bl bargraph_count_from_value             @ 08018F82
    b .L08018F8E                             @ 08018F86
.L08018F88:                                @ reached from 08018F7E bne (not equal / non-zero)
    movs r0, #0                              @ 08018F88
    bl bargraph_count_from_value             @ 08018F8A
.L08018F8E:                                @ reached from 08018F42 bhi (unsigned >); 08018F4A b; 08018F52 b; 08018F6C b; 08018F74 b; 08018F86 b; falls in
    pop {r0, pc}                             @ 08018F8E
ENDFUNC fn_08018F14
    .ltorg
    .global lcd_bargraph_scale
    .set lcd_bargraph_scale, fn_08018F14

@ -----------------------------------------------------------------------------
@ bargraph_count_from_value - bar count, polarity, tick group and range label from the per-sample value
@ Replaces : 0x08018FA8 bargraph_count_from_value (v2.05, 376 bytes)
@ In       : r0 = scale parameter (1 = divisor 400, tick group B, "1000" label; 0 = divisor 2000, tick group A)
@ Out      : 0x20008041 = bar count 0..25 (15 maximum in mode 11 DIODE); bargraph elements set in the shadow
@ Context  : main only
@ RAM      : reads meter_mode, 0x20007D68 (per-sample value), 0x20007D60 (full scale), 0x20008046 (OL), minmax_state;
@            writes 0x20008041, lcd_shadow words 0, 2, 4
@ Spec     : analysis/lcd_map.md 3
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC bargraph_count_from_value
    push {r4, r5, r6, lr}                    @ 08018FA8
    movs r4, r0                              @ 08018FAA
    ldr r0, =meter_mode                      @ 08018FAC &meter_mode
    ldrb r0, [r0, #0]                        @ 08018FB0
    @ no bargraph in modes 5, 6, 7, 8 and 12: return without drawing
    cmp r0, #6                               @ 08018FB2 branch if mode < 6 (6 = FREQ)
    blt .L08018FC0                           @ 08018FB4
    ldr r0, =meter_mode                      @ 08018FB6 &meter_mode
    ldrb r0, [r0, #0]                        @ 08018FBA
    cmp r0, #9                               @ 08018FBC branch if mode < 9 (9 = OHM)
    blt .L08018FD4                           @ 08018FBE
.L08018FC0:                                @ reached from 08018FB4 blt (signed <); falls in
    ldr r0, =meter_mode                      @ 08018FC0 &meter_mode
    ldrb r0, [r0, #0]                        @ 08018FC4
    cmp r0, #12                              @ 08018FC6 branch if mode == 12 (12 = CAP)
    beq .L08018FD4                           @ 08018FC8
    ldr r0, =meter_mode                      @ 08018FCA &meter_mode
    ldrb r0, [r0, #0]                        @ 08018FCE
    cmp r0, #5                               @ 08018FD0 branch if mode != 5 (5 = TEMP)
    bne .L08018FD6                           @ 08018FD2
.L08018FD4:                                @ reached from 08018FBE blt (signed <); 08018FC8 beq (equal / zero); falls in
    b .L0801911E                             @ 08018FD4
.L08018FD6:                                @ reached from 08018FD2 bne (not equal / non-zero)
    @ polarity: value negative -> "-" on, "+" off; otherwise "+" on, "-" off
    ldr r0, =v_20007D68                      @ 08018FD6 &per-sample value
    ldr r0, [r0, #0]                         @ 08018FDA
    cmp r0, #0                               @ 08018FDC branch if per-sample value is not negative
    bpl .L08019002                           @ 08018FDE
    ldr r0, =lcd_shadow                      @ 08018FE0 &LCD shadow
    ldr r0, [r0, #16]                        @ 08018FE4
    orrs.w r0, r0, #1                        @ 08018FE6
    ldr r1, =lcd_shadow                      @ 08018FEA &LCD shadow
    str r0, [r1, #16]                        @ 08018FEE w4 |= 0x1: bargraph polarity -
    ldr r0, =lcd_shadow                      @ 08018FF0 &LCD shadow
    ldr r0, [r0, #8]                         @ 08018FF4
    lsrs r0, r0, #1                          @ 08018FF6
    lsls r0, r0, #1                          @ 08018FF8
    ldr r1, =lcd_shadow                      @ 08018FFA &LCD shadow
    str r0, [r1, #8]                         @ 08018FFE w2 &= ~0x1: clears bargraph polarity +
    b .L08019022                             @ 08019000
.L08019002:                                @ reached from 08018FDE bpl (positive or zero)
    ldr r0, =lcd_shadow                      @ 08019002 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019006
    lsrs r0, r0, #1                          @ 08019008
    lsls r0, r0, #1                          @ 0801900A
    ldr r1, =lcd_shadow                      @ 0801900C &LCD shadow
    str r0, [r1, #16]                        @ 08019010 w4 &= ~0x1: clears bargraph polarity -
    ldr r0, =lcd_shadow                      @ 08019012 &LCD shadow
    ldr r0, [r0, #8]                         @ 08019016
    orrs.w r0, r0, #1                        @ 08019018
    ldr r1, =lcd_shadow                      @ 0801901C &LCD shadow
    str r0, [r1, #8]                         @ 08019020 w2 |= 0x1: bargraph polarity +
.L08019022:                                @ reached from 08019000 b; falls in
    @ r4 = scale parameter: 1 -> tick group A off, B on, labels via fn_0801912C(1), divisor 400; 0 -> A on, B off, fn_0801912C(0), divisor 2000
    uxtb r4, r4                              @ 08019022
    cmp r4, #1                               @ 08019024
    bne .L08019056                           @ 08019026
    ldr r0, =lcd_shadow                      @ 08019028 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801902C
    bics.w r0, r0, #4096                     @ 0801902E
    ldr r1, =lcd_shadow                      @ 08019032 &LCD shadow
    str r0, [r1, #0]                         @ 08019036 w0 &= ~0x1000: clears bar tick group A (digit-9 x slot)
    ldr r0, =lcd_shadow                      @ 08019038 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801903C
    orrs.w r0, r0, #1024                     @ 0801903E
    ldr r1, =lcd_shadow                      @ 08019042 &LCD shadow
    str r0, [r1, #0]                         @ 08019046 w0 |= 0x400: bar tick group B
    movs r0, #1                              @ 08019048
    bl fn_0801912C                           @ 0801904A
    mov.w r0, #400                           @ 0801904E
    movs r5, r0                              @ 08019052
    b .L08019082                             @ 08019054
.L08019056:                                @ reached from 08019026 bne (not equal / non-zero)
    ldr r0, =lcd_shadow                      @ 08019056 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801905A
    orrs.w r0, r0, #4096                     @ 0801905C
    ldr r1, =lcd_shadow                      @ 08019060 &LCD shadow
    str r0, [r1, #0]                         @ 08019064 w0 |= 0x1000: bar tick group A (digit-9 x slot)
    ldr r0, =lcd_shadow                      @ 08019066 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801906A
    bics.w r0, r0, #1024                     @ 0801906C
    ldr r1, =lcd_shadow                      @ 08019070 &LCD shadow
    str r0, [r1, #0]                         @ 08019074 w0 &= ~0x400: clears bar tick group B
    movs r0, #0                              @ 08019076
    bl fn_0801912C                           @ 08019078
    mov.w r0, #2000                          @ 0801907C
    movs r5, r0                              @ 08019080
.L08019082:                                @ reached from 08019054 b; falls in
    @ segment 0 is always lit (w0 bit 1)
    ldr r0, =lcd_shadow                      @ 08019082 &LCD shadow
    ldr r0, [r0, #0]                         @ 08019086
    orrs.w r0, r0, #2                        @ 08019088
    ldr r1, =lcd_shadow                      @ 0801908C &LCD shadow
    str r0, [r1, #0]                         @ 08019090 w0 |= 0x2: bargraph segment 0
    @ r6 = |value|; count = |value| / divisor (r5)
    ldr r0, =v_20007D68                      @ 08019092 &per-sample value
    ldr r0, [r0, #0]                         @ 08019096
    cmp r0, #0                               @ 08019098 branch if per-sample value is not negative
    bpl .L080190A8                           @ 0801909A
    ldr r0, =v_20007D68                      @ 0801909C &per-sample value
    ldr r0, [r0, #0]                         @ 080190A0
    negs r0, r0                              @ 080190A2
    movs r6, r0                              @ 080190A4
    b .L080190B0                             @ 080190A6
.L080190A8:                                @ reached from 0801909A bpl (positive or zero)
    ldr r0, =v_20007D68                      @ 080190A8 &per-sample value
    ldr r0, [r0, #0]                         @ 080190AC
    movs r6, r0                              @ 080190AE
.L080190B0:                                @ reached from 080190A6 b; falls in
    uxth r5, r5                              @ 080190B0
    sdiv r0, r6, r5                          @ 080190B2
    ldr r1, =v_20008041                      @ 080190B6 &bargraph segment count
    strb r0, [r1, #0]                        @ 080190BA
    @ overload: with MIN/MAX off the bar is full (25); with MIN/MAX active the bar is full only if the value reached the full scale or its negative
    ldr r0, =v_20008046                      @ 080190BC &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 080190BE
    cmp r0, #0                               @ 080190C0 branch if overload (OL) flag == 0
    beq .L08019102                           @ 080190C2
    ldr r0, =minmax_state                    @ 080190C4 &minmax_state
    ldrb r0, [r0, #0]                        @ 080190C8
    cmp r0, #0                               @ 080190CA branch if minmax_state == 0
    beq .L080190FA                           @ 080190CC
    ldr r0, =v_20007D68                      @ 080190CE &per-sample value
    ldr r0, [r0, #0]                         @ 080190D2
    ldr r1, =v_20007D60                      @ 080190D4 &full scale of the active range
    ldr r1, [r1, #0]                         @ 080190D8
    cmp r0, r1                               @ 080190DA
    bcs .L080190F0                           @ 080190DC
    ldr r0, =v_20007D68                      @ 080190DE &per-sample value
    ldr r0, [r0, #0]                         @ 080190E2
    negs r0, r0                              @ 080190E4
    ldr r1, =v_20007D68                      @ 080190E6 &per-sample value
    ldr r1, [r1, #0]                         @ 080190EA
    cmp r0, r1                               @ 080190EC
    blt .L08019102                           @ 080190EE
.L080190F0:                                @ reached from 080190DC bcs (unsigned >=); falls in
    movs r0, #25                             @ 080190F0
    ldr r1, =v_20008041                      @ 080190F2 &bargraph segment count
    strb r0, [r1, #0]                        @ 080190F6
    b .L08019102                             @ 080190F8
.L080190FA:                                @ reached from 080190CC beq (equal / zero)
    movs r0, #25                             @ 080190FA
    ldr r1, =v_20008041                      @ 080190FC &bargraph segment count
    strb r0, [r1, #0]                        @ 08019100
.L08019102:                                @ reached from 080190C2 beq (equal / zero); 080190EE blt (signed <); 080190F8 b; falls in
    bl lcd_bar_zero_sign                     @ IMP-15: with no bar lit the sign follows the digits (no flicker at zero)
    @ mode 11 (DIODE): a count of 16 or more is limited to 15

    ldr r0, =meter_mode                      @ 08019102 &meter_mode
    ldrb r0, [r0, #0]                        @ 08019106
    cmp r0, #11                              @ 08019108 branch if mode != 11 (11 = DIODE)
    bne .L0801911E                           @ 0801910A
    ldr r0, =v_20008041                      @ 0801910C &bargraph segment count
    ldrb r0, [r0, #0]                        @ 08019110
    cmp r0, #16                              @ 08019112 branch if bargraph segment count < 16
    blt .L0801911E                           @ 08019114
    movs r0, #15                             @ 08019116
    ldr r1, =v_20008041                      @ 08019118 &bargraph segment count
    strb r0, [r1, #0]                        @ 0801911C
.L0801911E:                                @ reached from 08018FD4 b; 0801910A bne (not equal / non-zero); 08019114 blt (signed <); falls in
    pop {r4, r5, r6, pc}                     @ 0801911E
ENDFUNC bargraph_count_from_value

@ -----------------------------------------------------------------------------
@ lcd_bar_negative - is the bargraph polarity negative?  (one rule for the LCD and the BLE frame byte 13)
@ Replaces : nothing in v2.05 (new, IMP-15)
@ In       : -
@ Out      : r0 = 1 negative, 0 positive
@ Clobbers : r1, flags
@ Context  : main only (lcd_bar_zero_sign; the BLE frame builder fn_0800C5DA, byte 13)
@ RAM      : reads 0x20008041 (bar count), 0x20007D64 (displayed value D), 0x20007D68 (per-sample value)
@ Note     : v2.05 takes the polarity from the sign of the per-sample value (0x08018FD6, BLE 0x0800C798), which is right
@            while bars are lit (one bar is FS / 25 counts, far above the per-sample noise).  With no bar lit the
@            per-sample value of a zero input is noise around 0.  v2.05 turned every per-sample value above -1.5 counts
@            into 0 or more (its rounding of negative values, OF-15), so its polarity stayed "+" almost always (one
@            14 ms "-" frame in setup_date at 14.69 s); the production image rounds correctly and services every
@            conversion (IMP-01), so the polarity changed every 14..40 ms (setup_navigate_dcv, open input, 2.64..3.39 s)
@            and the BLE bar sign with it.  With a count of 0 the polarity is therefore the sign of the displayed value
@            D, the same sign the main minus shows.
@ -----------------------------------------------------------------------------
FUNC lcd_bar_negative
    ldr r0, =v_20008041
    ldrb r0, [r0]
    cbz r0, 1f
    ldr r0, =v_20007D68                      @ bars lit: the per-sample value, as v2.05
    b 2f
1:  ldr r0, =v_20007D64                      @ no bar lit: the displayed value
2:  ldr r0, [r0]
    lsrs r0, r0, #31                         @ 1 when negative
    bx lr
ENDFUNC lcd_bar_negative

@ -----------------------------------------------------------------------------
@ lcd_bar_zero_sign - bargraph polarity when no bar is lit (lcd_bar_negative)
@ Replaces : nothing in v2.05 (new, IMP-15; called by bargraph_count_from_value after the count is final)
@ In/Out   : - / -
@ Clobbers : r0, r1, flags
@ Context  : main only
@ RAM      : reads 0x20008041; read-modify-writes lcd_shadow words 2, 4 (w2 b0 "+", w4 b0 "-")
@ -----------------------------------------------------------------------------
FUNC lcd_bar_zero_sign
    push {r4, lr}
    ldr r0, =v_20008041
    ldrb r0, [r0]
    cbnz r0, 2f                              @ bars lit: the v2.05 polarity stays
    bl lcd_bar_negative
    ldr r1, =lcd_shadow
    cbz r0, 1f
    ldr r0, [r1, #16]
    orr r0, r0, #1                           @ w4 b0: polarity -
    str r0, [r1, #16]
    ldr r0, [r1, #8]
    bic r0, r0, #1                           @ w2 b0: polarity + off
    str r0, [r1, #8]
    pop {r4, pc}
1:  ldr r0, [r1, #16]
    bic r0, r0, #1                           @ w4 b0: polarity - off
    str r0, [r1, #16]
    ldr r0, [r1, #8]
    orr r0, r0, #1                           @ w2 b0: polarity +
    str r0, [r1, #8]
2:  pop {r4, pc}
ENDFUNC lcd_bar_zero_sign
    .ltorg
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801912C - bargraph range labels
@ Replaces : 0x0801912C FUN_0801912C (v2.05, 302 bytes)
@ In       : r0 = 1 the "1000" label scale (0x2000804D = 3), 0 the "5/50/500" label scale chosen by mode and range
@ Out      : -
@ Context  : main only
@ RAM      : reads meter_mode, meter_range; writes 0x2000804D (scale 0..3 as sent in BLE byte 13), lcd_shadow words 2, 4, 6
@ Spec     : analysis/lcd_map.md 3 (labels), ble_packet.md (bscale)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801912C
    push {r4, lr}                            @ 0801912C
    movs r4, r0                              @ 0801912E
    uxtb r4, r4                              @ 08019130
    cmp r4, #1                               @ 08019132
    bne .L08019180                           @ 08019134
    @ param 1: "1000" label on, scale 3; "5", "50", "500" labels off
    ldr r0, =lcd_shadow                      @ 08019136 &LCD shadow
    ldr r0, [r0, #24]                        @ 0801913A
    orrs.w r0, r0, #256                      @ 0801913C
    ldr r1, =lcd_shadow                      @ 08019140 &LCD shadow
    str r0, [r1, #24]                        @ 08019144 w6 |= 0x100: bar label 1000
    movs r0, #3                              @ 08019146
    ldr r1, =v_2000804D                      @ 08019148 &bargraph scale / label state
    strb r0, [r1, #0]                        @ 0801914C
    ldr r0, =lcd_shadow                      @ 0801914E &LCD shadow
    ldr r0, [r0, #16]                        @ 08019152
    bics.w r0, r0, #128                      @ 08019154
    ldr r1, =lcd_shadow                      @ 08019158 &LCD shadow
    str r0, [r1, #16]                        @ 0801915C w4 &= ~0x80: clears bar range label 5
    ldr r0, =lcd_shadow                      @ 0801915E &LCD shadow
    ldr r0, [r0, #24]                        @ 08019162
    bics.w r0, r0, #128                      @ 08019164
    ldr r1, =lcd_shadow                      @ 08019168 &LCD shadow
    str r0, [r1, #24]                        @ 0801916C w6 &= ~0x80: clears bar label 0 (50)
    ldr r0, =lcd_shadow                      @ 0801916E &LCD shadow
    ldr r0, [r0, #8]                         @ 08019172
    bics.w r0, r0, #2048                     @ 08019174
    ldr r1, =lcd_shadow                      @ 08019178 &LCD shadow
    str r0, [r1, #8]                         @ 0801917C w2 &= ~0x800: clears bar label 0 (500)
    b .L08019258                             @ 0801917E
.L08019180:                                @ reached from 08019134 bne (not equal / non-zero)
    @ param 0: "1000" off, "5" on, scale 0; then the label index for the mode / range (fn_08019268)
    ldr r0, =lcd_shadow                      @ 08019180 &LCD shadow
    ldr r0, [r0, #24]                        @ 08019184
    bics.w r0, r0, #256                      @ 08019186
    ldr r1, =lcd_shadow                      @ 0801918A &LCD shadow
    str r0, [r1, #24]                        @ 0801918E w6 &= ~0x100: clears bar label 1000
    ldr r0, =lcd_shadow                      @ 08019190 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019194
    orrs.w r0, r0, #128                      @ 08019196
    ldr r1, =lcd_shadow                      @ 0801919A &LCD shadow
    str r0, [r1, #16]                        @ 0801919E w4 |= 0x80: bar range label 5
    movs r0, #0                              @ 080191A0
    ldr r1, =v_2000804D                      @ 080191A2 &bargraph scale / label state
    strb r0, [r1, #0]                        @ 080191A6
    @ modes 1, 2: index = range
    ldr r0, =meter_mode                      @ 080191A8 &meter_mode
    ldrb r0, [r0, #0]                        @ 080191AC
    subs r0, r0, #1                          @ 080191AE
    cmp r0, #1                               @ 080191B0
    bls .L080191F2                           @ 080191B2
    @ modes 3, 4: index = range + 1
    subs r0, r0, #2                          @ 080191B4
    cmp r0, #1                               @ 080191B6
    bls .L080191FE                           @ 080191B8
    @ mode 9 (OHM): range 0, 1 -> range + 1; 2..4 -> range - 2; 5, 6 -> range - 5
    subs r0, r0, #6                          @ 080191BA
    beq .L08019216                           @ 080191BC
    @ mode 10 (BEEP): index 2
    subs r0, r0, #1                          @ 080191BE
    beq .L0801920E                           @ 080191C0
    @ mode 11 (DIODE): index = range
    subs r0, r0, #1                          @ 080191C2
    beq .L080191F2                           @ 080191C4
    @ modes 16, 17: index = range + 1
    subs r0, r0, #5                          @ 080191C6
    cmp r0, #1                               @ 080191C8
    bls .L080191FE                           @ 080191CA
    @ modes 18, 19: index = range
    subs r0, r0, #2                          @ 080191CC
    cmp r0, #1                               @ 080191CE
    bls .L080191F2                           @ 080191D0
    @ modes 20, 21: index 2 at range 0, otherwise 0; all other modes: no label change

    subs r0, r0, #2                          @ 080191D2
    cmp r0, #1                               @ 080191D4
    bhi .L08019258                           @ 080191D6
    ldr r0, =meter_range                     @ 080191D8 &meter_range
    ldrb r0, [r0, #0]                        @ 080191DC
    cmp r0, #0                               @ 080191DE branch if meter_range != 0
    bne .L080191EA                           @ 080191E0
    movs r0, #2                              @ 080191E2
    bl fn_08019268                           @ 080191E4
    b .L080191F0                             @ 080191E8
.L080191EA:                                @ reached from 080191E0 bne (not equal / non-zero)
    movs r0, #0                              @ 080191EA
    bl fn_08019268                           @ 080191EC
.L080191F0:                                @ reached from 080191E8 b; falls in
    b .L08019258                             @ 080191F0
.L080191F2:                                @ reached from 080191B2 bls (unsigned <=); 080191C4 beq (equal / zero); 080191D0 bls (unsigned <=)
    ldr r0, =meter_range                     @ 080191F2 &meter_range
    ldrb r0, [r0, #0]                        @ 080191F6
    bl fn_08019268                           @ 080191F8
    b .L08019258                             @ 080191FC
.L080191FE:                                @ reached from 080191B8 bls (unsigned <=); 080191CA bls (unsigned <=)
    ldr r0, =meter_range                     @ 080191FE &meter_range
    ldrb r0, [r0, #0]                        @ 08019202
    adds r0, r0, #1                          @ 08019204
    uxtb r0, r0                              @ 08019206
    bl fn_08019268                           @ 08019208
    b .L08019258                             @ 0801920C
.L0801920E:                                @ reached from 080191C0 beq (equal / zero)
    movs r0, #2                              @ 0801920E
    bl fn_08019268                           @ 08019210
    b .L08019258                             @ 08019214
.L08019216:                                @ reached from 080191BC beq (equal / zero)
    ldr r0, =meter_range                     @ 08019216 &meter_range
    ldrb r0, [r0, #0]                        @ 0801921A
    cmp r0, #2                               @ 0801921C branch if meter_range >= 2
    bge .L08019230                           @ 0801921E
    ldr r0, =meter_range                     @ 08019220 &meter_range
    ldrb r0, [r0, #0]                        @ 08019224
    adds r0, r0, #1                          @ 08019226
    uxtb r0, r0                              @ 08019228
    bl fn_08019268                           @ 0801922A
    b .L08019258                             @ 0801922E
.L08019230:                                @ reached from 0801921E bge (signed >=)
    ldr r0, =meter_range                     @ 08019230 &meter_range
    ldrb r0, [r0, #0]                        @ 08019234
    cmp r0, #5                               @ 08019236 branch if meter_range >= 5
    bge .L0801924A                           @ 08019238
    ldr r0, =meter_range                     @ 0801923A &meter_range
    ldrb r0, [r0, #0]                        @ 0801923E
    subs r0, r0, #2                          @ 08019240
    uxtb r0, r0                              @ 08019242
    bl fn_08019268                           @ 08019244
    b .L08019258                             @ 08019248
.L0801924A:                                @ reached from 08019238 bge (signed >=)
    ldr r0, =meter_range                     @ 0801924A &meter_range
    ldrb r0, [r0, #0]                        @ 0801924E
    subs r0, r0, #5                          @ 08019250
    uxtb r0, r0                              @ 08019252
    bl fn_08019268                           @ 08019254
.L08019258:                                @ reached from 0801917E b; 080191D6 bhi (unsigned >); 080191F0 b; 080191FC b; 0801920C b; 08019214 b; 0801922E b; 08019248 b; falls in
    pop {r4, pc}                             @ 08019258
ENDFUNC fn_0801912C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019268 - set the bargraph range label by index
@ Replaces : 0x08019268 FUN_08019268 (v2.05, 140 bytes)
@ In       : r0 = index 0..2 (other values change nothing)
@ Out      : 0x2000804D = index
@ Context  : main only
@ RAM      : lcd_shadow words 2, 6 (bits 11 and 7), 0x2000804D
@ Spec     : analysis/lcd_map.md 3 (labels "5" is set by the caller; index 1 adds "0" of 50, index 2 adds "0" of 500)
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019268
    uxtb r0, r0                              @ 08019268
    cmp r0, #0                               @ 0801926A
    beq .L08019276                           @ 0801926C
    cmp r0, #2                               @ 0801926E
    beq .L080192CA                           @ 08019270
    bcc .L080192A0                           @ 08019272
    b .L080192F2                             @ 08019274
.L08019276:                                @ reached from 0801926C beq (equal / zero)
    @ index 0: both zeros off
    ldr r1, =lcd_shadow                      @ 08019276 &LCD shadow
    ldr r1, [r1, #24]                        @ 0801927A
    bics.w r1, r1, #128                      @ 0801927C
    ldr r2, =lcd_shadow                      @ 08019280 &LCD shadow
    str r1, [r2, #24]                        @ 08019284 w6 &= ~0x80: clears bar label 0 (50)
    ldr r1, =lcd_shadow                      @ 08019286 &LCD shadow
    ldr r1, [r1, #8]                         @ 0801928A
    bics.w r1, r1, #2048                     @ 0801928C
    ldr r2, =lcd_shadow                      @ 08019290 &LCD shadow
    str r1, [r2, #8]                         @ 08019294 w2 &= ~0x800: clears bar label 0 (500)
    movs r1, #0                              @ 08019296
    ldr r2, =v_2000804D                      @ 08019298 &bargraph scale / label state
    strb r1, [r2, #0]                        @ 0801929C
    b .L080192F2                             @ 0801929E
.L080192A0:                                @ reached from 08019272 bcc (unsigned <)
    @ index 1: "0" of 50 on, "0" of 500 off
    ldr r1, =lcd_shadow                      @ 080192A0 &LCD shadow
    ldr r1, [r1, #24]                        @ 080192A4
    orrs.w r1, r1, #128                      @ 080192A6
    ldr r2, =lcd_shadow                      @ 080192AA &LCD shadow
    str r1, [r2, #24]                        @ 080192AE w6 |= 0x80: bar label 0 (50)
    ldr r1, =lcd_shadow                      @ 080192B0 &LCD shadow
    ldr r1, [r1, #8]                         @ 080192B4
    bics.w r1, r1, #2048                     @ 080192B6
    ldr r2, =lcd_shadow                      @ 080192BA &LCD shadow
    str r1, [r2, #8]                         @ 080192BE w2 &= ~0x800: clears bar label 0 (500)
    movs r1, #1                              @ 080192C0
    ldr r2, =v_2000804D                      @ 080192C2 &bargraph scale / label state
    strb r1, [r2, #0]                        @ 080192C6
    b .L080192F2                             @ 080192C8
.L080192CA:                                @ reached from 08019270 beq (equal / zero)
    @ index 2: both zeros on

    ldr r1, =lcd_shadow                      @ 080192CA &LCD shadow
    ldr r1, [r1, #24]                        @ 080192CE
    orrs.w r1, r1, #128                      @ 080192D0
    ldr r2, =lcd_shadow                      @ 080192D4 &LCD shadow
    str r1, [r2, #24]                        @ 080192D8 w6 |= 0x80: bar label 0 (50)
    ldr r1, =lcd_shadow                      @ 080192DA &LCD shadow
    ldr r1, [r1, #8]                         @ 080192DE
    orrs.w r1, r1, #2048                     @ 080192E0
    ldr r2, =lcd_shadow                      @ 080192E4 &LCD shadow
    str r1, [r2, #8]                         @ 080192E8 w2 |= 0x800: bar label 0 (500)
    movs r1, #2                              @ 080192EA
    ldr r2, =v_2000804D                      @ 080192EC &bargraph scale / label state
    strb r1, [r2, #0]                        @ 080192F0
.L080192F2:                                @ reached from 08019274 b; 0801929E b; 080192C8 b; falls in
    bx lr                                    @ 080192F2
ENDFUNC fn_08019268
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080192FC - reset the bargraph for a new mode or range
@ Replaces : 0x080192FC FUN_080192FC (v2.05, 90 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by fn_08017222 (live annunciator redraw)
@ RAM      : reads meter_mode; writes 0x20007D68 = 0, 0x20008041 = 0, lcd_shadow bargraph bits, 0x2000805B
@ Spec     : analysis/lcd_map.md 3
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080192FC
    push {r7, lr}                            @ 080192FC
    ldr r0, =meter_mode                      @ 080192FE &meter_mode
    ldrb r0, [r0, #0]                        @ 08019302
    @ modes 6..8, 12 and 5: all bargraph elements off (fn_08019364)
    cmp r0, #6                               @ 08019304 branch if mode < 6 (6 = FREQ)
    blt .L08019312                           @ 08019306
    ldr r0, =meter_mode                      @ 08019308 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801930C
    cmp r0, #9                               @ 0801930E branch if mode < 9 (9 = OHM)
    blt .L08019326                           @ 08019310
.L08019312:                                @ reached from 08019306 blt (signed <); falls in
    ldr r0, =meter_mode                      @ 08019312 &meter_mode
    ldrb r0, [r0, #0]                        @ 08019316
    cmp r0, #12                              @ 08019318 branch if mode == 12 (12 = CAP)
    beq .L08019326                           @ 0801931A
    ldr r0, =meter_mode                      @ 0801931C &meter_mode
    ldrb r0, [r0, #0]                        @ 08019320
    cmp r0, #5                               @ 08019322 branch if mode != 5 (5 = TEMP)
    bne .L0801932C                           @ 08019324
.L08019326:                                @ reached from 08019310 blt (signed <); 0801931A beq (equal / zero); falls in
    bl fn_08019364                           @ 08019326
    b .L08019354                             @ 0801932A
.L0801932C:                                @ reached from 08019324 bne (not equal / non-zero)
    @ other modes: per-sample value := 0, count := 0, scale / labels (fn_08018F14), clear segments 1..25, commit request

    movs r0, #0                              @ 0801932C
    ldr r1, =v_20007D68                      @ 0801932E &per-sample value
    str r0, [r1, #0]                         @ 08019332
    ldr r0, =v_20007D68                      @ 08019334 &per-sample value
    ldr r0, [r0, #0]                         @ 08019338
    ldr r1, =v_20008041                      @ 0801933A &bargraph segment count
    strb r0, [r1, #0]                        @ 0801933E
    bl fn_08018F14                           @ 08019340
    movs r1, #1                              @ 08019344
    movs r0, #25                             @ 08019346
    bl fn_08019408                           @ 08019348
    movs r0, #1                              @ 0801934C
    ldr r1, =v_2000805B                      @ 0801934E &LCD commit request
    strb r0, [r1, #0]                        @ 08019352
.L08019354:                                @ reached from 0801932A b; falls in
    pop {r0, pc}                             @ 08019354
ENDFUNC fn_080192FC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019364 - switch all bargraph elements off
@ Replaces : 0x08019364 FUN_08019364 (v2.05, 140 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0, 2, 4, 6
@ Spec     : analysis/lcd_map.md 3 (polarity, tick groups A and B, labels 5 / 0 / 0 / 1000, segments 0..25)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019364
    push {r7, lr}                            @ 08019364
    ldr r0, =lcd_shadow                      @ 08019366 &LCD shadow
    ldr r0, [r0, #16]                        @ 0801936A
    lsrs r0, r0, #1                          @ 0801936C
    lsls r0, r0, #1                          @ 0801936E
    ldr r1, =lcd_shadow                      @ 08019370 &LCD shadow
    str r0, [r1, #16]                        @ 08019374 w4 &= ~0x1: clears bargraph polarity -
    ldr r0, =lcd_shadow                      @ 08019376 &LCD shadow
    ldr r0, [r0, #8]                         @ 0801937A
    lsrs r0, r0, #1                          @ 0801937C
    lsls r0, r0, #1                          @ 0801937E
    ldr r1, =lcd_shadow                      @ 08019380 &LCD shadow
    str r0, [r1, #8]                         @ 08019384 w2 &= ~0x1: clears bargraph polarity +
    ldr r0, =lcd_shadow                      @ 08019386 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801938A
    bics.w r0, r0, #4096                     @ 0801938C
    ldr r1, =lcd_shadow                      @ 08019390 &LCD shadow
    str r0, [r1, #0]                         @ 08019394 w0 &= ~0x1000: clears bar tick group A (digit-9 x slot)
    ldr r0, =lcd_shadow                      @ 08019396 &LCD shadow
    ldr r0, [r0, #0]                         @ 0801939A
    bics.w r0, r0, #1024                     @ 0801939C
    ldr r1, =lcd_shadow                      @ 080193A0 &LCD shadow
    str r0, [r1, #0]                         @ 080193A4 w0 &= ~0x400: clears bar tick group B
    ldr r0, =lcd_shadow                      @ 080193A6 &LCD shadow
    ldr r0, [r0, #24]                        @ 080193AA
    bics.w r0, r0, #256                      @ 080193AC
    ldr r1, =lcd_shadow                      @ 080193B0 &LCD shadow
    str r0, [r1, #24]                        @ 080193B4 w6 &= ~0x100: clears bar label 1000
    ldr r0, =lcd_shadow                      @ 080193B6 &LCD shadow
    ldr r0, [r0, #16]                        @ 080193BA
    bics.w r0, r0, #128                      @ 080193BC
    ldr r1, =lcd_shadow                      @ 080193C0 &LCD shadow
    str r0, [r1, #16]                        @ 080193C4 w4 &= ~0x80: clears bar range label 5
    ldr r0, =lcd_shadow                      @ 080193C6 &LCD shadow
    ldr r0, [r0, #24]                        @ 080193CA
    bics.w r0, r0, #128                      @ 080193CC
    ldr r1, =lcd_shadow                      @ 080193D0 &LCD shadow
    str r0, [r1, #24]                        @ 080193D4 w6 &= ~0x80: clears bar label 0 (50)
    ldr r0, =lcd_shadow                      @ 080193D6 &LCD shadow
    ldr r0, [r0, #8]                         @ 080193DA
    bics.w r0, r0, #2048                     @ 080193DC
    ldr r1, =lcd_shadow                      @ 080193E0 &LCD shadow
    str r0, [r1, #8]                         @ 080193E4 w2 &= ~0x800: clears bar label 0 (500)
    @ segments 25 down to 0 cleared (fn_08019408)

    movs r1, #0                              @ 080193E6
    movs r0, #25                             @ 080193E8
    bl fn_08019408                           @ 080193EA
    pop {r0, pc}                             @ 080193EE
ENDFUNC fn_08019364
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019408 - clear bargraph segments from r0 down to r1
@ Replaces : 0x08019408 FUN_08019408 (v2.05, 632 bytes)
@ In       : r0 = highest segment to clear (0..25), r1 = lowest segment to clear (0..25)
@ Out      : -
@ Context  : main only
@ RAM      : lcd_shadow words 0, 2, 4, 6 (one bit per segment, see lcd_map.md 3)
@ Spec     : analysis/lcd_map.md 3: the routine clears segment r0, then r0 - 1, and so on, and stops after it has cleared r1;
@            it is a cascade (r0 = 25 enters at the top block, other values enter further down) of 26 clear blocks
@
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019408
    uxtb r0, r0                              @ 08019408
    cmp r0, #0                               @ 0801940A
    beq .L08019672                           @ 0801940C
    cmp r0, #2                               @ 08019410
    beq .L0801964E                           @ 08019412
    bcc .L08019660                           @ 08019416
    cmp r0, #4                               @ 0801941A
    beq .L0801962A                           @ 0801941C
    bcc .L0801963C                           @ 08019420
    cmp r0, #6                               @ 08019424
    beq .L08019606                           @ 08019426
    bcc .L08019618                           @ 0801942A
    cmp r0, #8                               @ 0801942E
    beq .L080195E2                           @ 08019430
    bcc .L080195F4                           @ 08019434
    cmp r0, #10                              @ 08019438
    beq .L080195BE                           @ 0801943A
    bcc .L080195D0                           @ 0801943E
    cmp r0, #12                              @ 08019442
    beq .L0801959A                           @ 08019444
    bcc .L080195AC                           @ 08019448
    cmp r0, #14                              @ 0801944C
    beq .L08019576                           @ 0801944E
    bcc .L08019588                           @ 08019452
    cmp r0, #16                              @ 08019456
    beq .L0801954E                           @ 08019458
    bcc .L08019562                           @ 0801945A
    cmp r0, #18                              @ 0801945E
    beq .L08019524                           @ 08019460
    bcc .L0801953A                           @ 08019462
    cmp r0, #20                              @ 08019464
    beq .L080194F4                           @ 08019466
    bcc .L0801950C                           @ 08019468
    cmp r0, #22                              @ 0801946A
    beq .L080194C4                           @ 0801946C
    bcc .L080194DC                           @ 0801946E
    cmp r0, #24                              @ 08019470
    beq .L08019494                           @ 08019472
    bcc .L080194AC                           @ 08019474
    cmp r0, #25                              @ 08019476
    bne .L0801967E                           @ 08019478
    ldr r2, =lcd_shadow                      @ 0801947C &LCD shadow
    ldr r2, [r2, #8]                         @ 08019480
    bics.w r2, r2, #128                      @ 08019482
    ldr r3, =lcd_shadow                      @ 08019486 &LCD shadow
    str r2, [r3, #8]                         @ 0801948A w2 &= ~0x80: clears bargraph segment 25
    uxtb r1, r1                              @ 0801948C
    cmp r1, #25                              @ 0801948E
    beq .L0801967E                           @ 08019490
.L08019494:                                @ reached from 08019472 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 08019494 &LCD shadow
    ldr r2, [r2, #0]                         @ 08019498
    bics.w r2, r2, #128                      @ 0801949A
    ldr r3, =lcd_shadow                      @ 0801949E &LCD shadow
    str r2, [r3, #0]                         @ 080194A2 w0 &= ~0x80: clears bargraph segment 24
    uxtb r1, r1                              @ 080194A4
    cmp r1, #24                              @ 080194A6
    beq .L0801967E                           @ 080194A8
.L080194AC:                                @ reached from 08019474 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 080194AC &LCD shadow
    ldr r2, [r2, #0]                         @ 080194B0
    bics.w r2, r2, #64                       @ 080194B2
    ldr r3, =lcd_shadow                      @ 080194B6 &LCD shadow
    str r2, [r3, #0]                         @ 080194BA w0 &= ~0x40: clears bargraph segment 23
    uxtb r1, r1                              @ 080194BC
    cmp r1, #23                              @ 080194BE
    beq .L0801967E                           @ 080194C0
.L080194C4:                                @ reached from 0801946C beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 080194C4 &LCD shadow
    ldr r2, [r2, #8]                         @ 080194C8
    bics.w r2, r2, #64                       @ 080194CA
    ldr r3, =lcd_shadow                      @ 080194CE &LCD shadow
    str r2, [r3, #8]                         @ 080194D2 w2 &= ~0x40: clears bargraph segment 22
    uxtb r1, r1                              @ 080194D4
    cmp r1, #22                              @ 080194D6
    beq .L0801967E                           @ 080194D8
.L080194DC:                                @ reached from 0801946E bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 080194DC &LCD shadow
    ldr r2, [r2, #16]                        @ 080194E0
    bics.w r2, r2, #64                       @ 080194E2
    ldr r3, =lcd_shadow                      @ 080194E6 &LCD shadow
    str r2, [r3, #16]                        @ 080194EA w4 &= ~0x40: clears bargraph segment 21
    uxtb r1, r1                              @ 080194EC
    cmp r1, #21                              @ 080194EE
    beq .L0801967E                           @ 080194F0
.L080194F4:                                @ reached from 08019466 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 080194F4 &LCD shadow
    ldr r2, [r2, #24]                        @ 080194F8
    bics.w r2, r2, #64                       @ 080194FA
    ldr r3, =lcd_shadow                      @ 080194FE &LCD shadow
    str r2, [r3, #24]                        @ 08019502 w6 &= ~0x40: clears bargraph segment 20
    uxtb r1, r1                              @ 08019504
    cmp r1, #20                              @ 08019506
    beq .L0801967E                           @ 08019508
.L0801950C:                                @ reached from 08019468 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 0801950C &LCD shadow
    ldr r2, [r2, #24]                        @ 08019510
    bics.w r2, r2, #32                       @ 08019512
    ldr r3, =lcd_shadow                      @ 08019516 &LCD shadow
    str r2, [r3, #24]                        @ 0801951A w6 &= ~0x20: clears bargraph segment 19
    uxtb r1, r1                              @ 0801951C
    cmp r1, #19                              @ 0801951E
    beq .L0801967E                           @ 08019520
.L08019524:                                @ reached from 08019460 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 08019524 &LCD shadow
    ldr r2, [r2, #16]                        @ 08019528
    bics.w r2, r2, #32                       @ 0801952A
    ldr r3, =lcd_shadow                      @ 0801952E &LCD shadow
    str r2, [r3, #16]                        @ 08019530 w4 &= ~0x20: clears bargraph segment 18
    uxtb r1, r1                              @ 08019532
    cmp r1, #18                              @ 08019534
    beq .L0801967E                           @ 08019536
.L0801953A:                                @ reached from 08019462 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 0801953A &LCD shadow
    ldr r2, [r2, #8]                         @ 0801953C
    bics.w r2, r2, #32                       @ 0801953E
    ldr r3, =lcd_shadow                      @ 08019542 &LCD shadow
    str r2, [r3, #8]                         @ 08019544 w2 &= ~0x20: clears bargraph segment 17
    uxtb r1, r1                              @ 08019546
    cmp r1, #17                              @ 08019548
    beq .L0801967E                           @ 0801954A
.L0801954E:                                @ reached from 08019458 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 0801954E &LCD shadow
    ldr r2, [r2, #0]                         @ 08019550
    bics.w r2, r2, #32                       @ 08019552
    ldr r3, =lcd_shadow                      @ 08019556 &LCD shadow
    str r2, [r3, #0]                         @ 08019558 w0 &= ~0x20: clears bargraph segment 16
    uxtb r1, r1                              @ 0801955A
    cmp r1, #16                              @ 0801955C
    beq .L0801967E                           @ 0801955E
.L08019562:                                @ reached from 0801945A bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 08019562 &LCD shadow
    ldr r2, [r2, #0]                         @ 08019564
    bics.w r2, r2, #16                       @ 08019566
    ldr r3, =lcd_shadow                      @ 0801956A &LCD shadow
    str r2, [r3, #0]                         @ 0801956C w0 &= ~0x10: clears bargraph segment 15
    uxtb r1, r1                              @ 0801956E
    cmp r1, #15                              @ 08019570
    beq .L0801967E                           @ 08019572
.L08019576:                                @ reached from 0801944E beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 08019576 &LCD shadow
    ldr r2, [r2, #8]                         @ 08019578
    bics.w r2, r2, #16                       @ 0801957A
    ldr r3, =lcd_shadow                      @ 0801957E &LCD shadow
    str r2, [r3, #8]                         @ 08019580 w2 &= ~0x10: clears bargraph segment 14
    uxtb r1, r1                              @ 08019582
    cmp r1, #14                              @ 08019584
    beq .L0801967E                           @ 08019586
.L08019588:                                @ reached from 08019452 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 08019588 &LCD shadow
    ldr r2, [r2, #16]                        @ 0801958A
    bics.w r2, r2, #16                       @ 0801958C
    ldr r3, =lcd_shadow                      @ 08019590 &LCD shadow
    str r2, [r3, #16]                        @ 08019592 w4 &= ~0x10: clears bargraph segment 13
    uxtb r1, r1                              @ 08019594
    cmp r1, #13                              @ 08019596
    beq .L0801967E                           @ 08019598
.L0801959A:                                @ reached from 08019444 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 0801959A &LCD shadow
    ldr r2, [r2, #24]                        @ 0801959C
    bics.w r2, r2, #16                       @ 0801959E
    ldr r3, =lcd_shadow                      @ 080195A2 &LCD shadow
    str r2, [r3, #24]                        @ 080195A4 w6 &= ~0x10: clears bargraph segment 12
    uxtb r1, r1                              @ 080195A6
    cmp r1, #12                              @ 080195A8
    beq .L0801967E                           @ 080195AA
.L080195AC:                                @ reached from 08019448 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 080195AC &LCD shadow
    ldr r2, [r2, #24]                        @ 080195AE
    bics.w r2, r2, #8                        @ 080195B0
    ldr r3, =lcd_shadow                      @ 080195B4 &LCD shadow
    str r2, [r3, #24]                        @ 080195B6 w6 &= ~0x8: clears bargraph segment 11
    uxtb r1, r1                              @ 080195B8
    cmp r1, #11                              @ 080195BA
    beq .L0801967E                           @ 080195BC
.L080195BE:                                @ reached from 0801943A beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 080195BE &LCD shadow
    ldr r2, [r2, #16]                        @ 080195C0
    bics.w r2, r2, #8                        @ 080195C2
    ldr r3, =lcd_shadow                      @ 080195C6 &LCD shadow
    str r2, [r3, #16]                        @ 080195C8 w4 &= ~0x8: clears bargraph segment 10
    uxtb r1, r1                              @ 080195CA
    cmp r1, #10                              @ 080195CC
    beq .L0801967E                           @ 080195CE
.L080195D0:                                @ reached from 0801943E bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 080195D0 &LCD shadow
    ldr r2, [r2, #8]                         @ 080195D2
    bics.w r2, r2, #8                        @ 080195D4
    ldr r3, =lcd_shadow                      @ 080195D8 &LCD shadow
    str r2, [r3, #8]                         @ 080195DA w2 &= ~0x8: clears bargraph segment 9
    uxtb r1, r1                              @ 080195DC
    cmp r1, #9                               @ 080195DE
    beq .L0801967E                           @ 080195E0
.L080195E2:                                @ reached from 08019430 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 080195E2 &LCD shadow
    ldr r2, [r2, #0]                         @ 080195E4
    bics.w r2, r2, #8                        @ 080195E6
    ldr r3, =lcd_shadow                      @ 080195EA &LCD shadow
    str r2, [r3, #0]                         @ 080195EC w0 &= ~0x8: clears bargraph segment 8
    uxtb r1, r1                              @ 080195EE
    cmp r1, #8                               @ 080195F0
    beq .L0801967E                           @ 080195F2
.L080195F4:                                @ reached from 08019434 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 080195F4 &LCD shadow
    ldr r2, [r2, #0]                         @ 080195F6
    bics.w r2, r2, #4                        @ 080195F8
    ldr r3, =lcd_shadow                      @ 080195FC &LCD shadow
    str r2, [r3, #0]                         @ 080195FE w0 &= ~0x4: clears bargraph segment 7
    uxtb r1, r1                              @ 08019600
    cmp r1, #7                               @ 08019602
    beq .L0801967E                           @ 08019604
.L08019606:                                @ reached from 08019426 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 08019606 &LCD shadow
    ldr r2, [r2, #8]                         @ 08019608
    bics.w r2, r2, #4                        @ 0801960A
    ldr r3, =lcd_shadow                      @ 0801960E &LCD shadow
    str r2, [r3, #8]                         @ 08019610 w2 &= ~0x4: clears bargraph segment 6
    uxtb r1, r1                              @ 08019612
    cmp r1, #6                               @ 08019614
    beq .L0801967E                           @ 08019616
.L08019618:                                @ reached from 0801942A bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 08019618 &LCD shadow
    ldr r2, [r2, #16]                        @ 0801961A
    bics.w r2, r2, #4                        @ 0801961C
    ldr r3, =lcd_shadow                      @ 08019620 &LCD shadow
    str r2, [r3, #16]                        @ 08019622 w4 &= ~0x4: clears bargraph segment 5
    uxtb r1, r1                              @ 08019624
    cmp r1, #5                               @ 08019626
    beq .L0801967E                           @ 08019628
.L0801962A:                                @ reached from 0801941C beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 0801962A &LCD shadow
    ldr r2, [r2, #24]                        @ 0801962C
    bics.w r2, r2, #4                        @ 0801962E
    ldr r3, =lcd_shadow                      @ 08019632 &LCD shadow
    str r2, [r3, #24]                        @ 08019634 w6 &= ~0x4: clears bargraph segment 4
    uxtb r1, r1                              @ 08019636
    cmp r1, #4                               @ 08019638
    beq .L0801967E                           @ 0801963A
.L0801963C:                                @ reached from 08019420 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 0801963C &LCD shadow
    ldr r2, [r2, #24]                        @ 0801963E
    bics.w r2, r2, #2                        @ 08019640
    ldr r3, =lcd_shadow                      @ 08019644 &LCD shadow
    str r2, [r3, #24]                        @ 08019646 w6 &= ~0x2: clears bargraph segment 3
    uxtb r1, r1                              @ 08019648
    cmp r1, #3                               @ 0801964A
    beq .L0801967E                           @ 0801964C
.L0801964E:                                @ reached from 08019412 beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 0801964E &LCD shadow
    ldr r2, [r2, #16]                        @ 08019650
    bics.w r2, r2, #2                        @ 08019652
    ldr r3, =lcd_shadow                      @ 08019656 &LCD shadow
    str r2, [r3, #16]                        @ 08019658 w4 &= ~0x2: clears bargraph segment 2
    uxtb r1, r1                              @ 0801965A
    cmp r1, #2                               @ 0801965C
    beq .L0801967E                           @ 0801965E
.L08019660:                                @ reached from 08019416 bcc (unsigned <); falls in
    ldr r2, =lcd_shadow                      @ 08019660 &LCD shadow
    ldr r2, [r2, #8]                         @ 08019662
    bics.w r2, r2, #2                        @ 08019664
    ldr r3, =lcd_shadow                      @ 08019668 &LCD shadow
    str r2, [r3, #8]                         @ 0801966A w2 &= ~0x2: clears bargraph segment 1
    uxtb r1, r1                              @ 0801966C
    cmp r1, #1                               @ 0801966E
    beq .L0801967E                           @ 08019670
.L08019672:                                @ reached from 0801940C beq (equal / zero); falls in
    ldr r2, =lcd_shadow                      @ 08019672 &LCD shadow
    ldr r2, [r2, #0]                         @ 08019674
    bics.w r2, r2, #2                        @ 08019676
    ldr r3, =lcd_shadow                      @ 0801967A &LCD shadow
    str r2, [r3, #0]                         @ 0801967C w0 &= ~0x2: clears bargraph segment 0
.L0801967E:                                @ reached from 08019478 bne (not equal / non-zero); 08019490 beq (equal / zero); 080194A8 beq (equal / zero); 080194C0 beq (equal / zero); 080194D8 beq (equal / zero); 080194F0 beq (equal / zero); 08019508 beq (equal / zero); 08019520 beq (equal / zero); 08019536 beq (equal / zero); 0801954A beq (equal / zero); 0801955E beq (equal / zero); 08019572 beq (equal / zero); 08019586 beq (equal / zero); 08019598 beq (equal / zero); 080195AA beq (equal / zero); 080195BC beq (equal / zero); 080195CE beq (equal / zero); 080195E0 beq (equal / zero); 080195F2 beq (equal / zero); 08019604 beq (equal / zero); 08019616 beq (equal / zero); 08019628 beq (equal / zero); 0801963A beq (equal / zero); 0801964C beq (equal / zero); 0801965E beq (equal / zero); 08019670 beq (equal / zero); falls in
    bx lr                                    @ 0801967E
ENDFUNC fn_08019408
    .ltorg
