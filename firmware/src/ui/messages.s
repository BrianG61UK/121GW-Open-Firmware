@ =============================================================================
@ messages.s - UI: message screens, calibration step texts, overload and lead texts, V-2.05 splash (DESIGN.md 6.8)
@
@ Replaces the message routines of v2.05: the power-off text fn_08017092, calibration step texts fn_08019698 /
@ fn_08019738, SdCAL / SdSAv / SdSEt / SAvEd / -Err- / CAL1 / CAL, LoBAt, SdEnd, SdExx, OFL, OPEN, LEAD, -----,
@ blank, and the V-2.05 splash fn_0801A854.  Every string is the v2.05 table in ui/tables_v205.s (TABLE_V205 copies of
@ 0x080291A8..0x08029288); the 5-character texts are drawn through lcd_draw_5char.
@ Port-only: ui_blank_draw (both builds), which draws the spaces or dashes requested through ui_blank_req.
@ Context: main only.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.ui.messages, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08017092 - power-off screen "-oFF-"
@ Replaces : 0x08017092 FUN_08017092 (v2.05, 26 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by pe7_on_blocking_100_ticks (BZB) before the power-off beep
@ RAM      : lcd_shadow (cleared, then main/sub text); string v205_tab_080291A8 "-oFF-"
@ Spec     : DESIGN.md 3.6 (enter_stop_and_reinit); analysis/lcd_map.md
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08017092
    push {r7, lr}                            @ 08017092
    @ clear the shadow and commit the blank screen (fn_0801A81C, lcd_commit_shadow)
    bl fn_0801A81C                           @ 08017094
    bl lcd_commit_shadow                     @ 08017098
    @ draw "-oFF-" on the main display (flag 0) and commit

    ldr r1, =v205_tab_080291A8               @ 0801709C
    movs r0, #0                              @ 080170A0
    bl lcd_draw_5char                        @ 080170A2
    bl lcd_commit_shadow                     @ 080170A6
    pop {r0, pc}                             @ 080170AA
ENDFUNC fn_08017092
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019698 - calibration step text "-X-nn" on the main display
@ Replaces : 0x08019698 FUN_08019698 (v2.05, 152 bytes)
@ In       : r0 = text index 0..4 (second character: 0 'O', 1 'G', 2 '4', 3 '5', 4 '3')
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ Note     : the units digit is (n - 10) + 0x30 for n >= 10, so the text is correct for n = 0..19 only; for n >= 20 the units
@            character is wrong (v2.05 behaviour, kept; whether n >= 20 can occur is not established)
@ RAM      : reads 0x20008095 (two-digit number 0..99); writes the text buffer 0x20007C30; clears the main minus sign (w3 bit 7)
@ Spec     : analysis/lcd_map.md 2; the text is built as '-', index character, '-', tens digit (0 if below 10), units digit
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019698
    push {r3, r4, r5, lr}                    @ 08019698
    movs r4, r0                              @ 0801969A
    ldr r0, =v_20008095                      @ 0801969C &two-digit number shown by fn_08019698
    ldrb r5, [r0, #0]                        @ 080196A0
    ldr r0, =lcd_shadow                      @ 080196A2 &LCD shadow
    ldr r0, [r0, #12]                        @ 080196A4
    bics.w r0, r0, #128                      @ 080196A6
    ldr r1, =lcd_shadow                      @ 080196AA &LCD shadow
    str r0, [r1, #12]                        @ 080196AC w3 &= ~0x80: clears main minus
    @ buffer[0] = '-'
    movs r0, #45                             @ 080196AE
    ldr r1, =v_20007C30                      @ 080196B0 &5-char text buffer
    strb r0, [r1, #0]                        @ 080196B2
    @ buffer[1] = character for the index: 0 'O', 1 'G', 2 '4', 3 '5', 4 '3' (other indices leave the old byte)
    uxtb r4, r4                              @ 080196B4
    cmp r4, #0                               @ 080196B6
    beq .L080196C8                           @ 080196B8
    cmp r4, #2                               @ 080196BA
    beq .L080196D8                           @ 080196BC
    bcc .L080196D0                           @ 080196BE
    cmp r4, #4                               @ 080196C0
    beq .L080196E8                           @ 080196C2
    bcc .L080196E0                           @ 080196C4
    b .L080196EE                             @ 080196C6
.L080196C8:                                @ reached from 080196B8 beq (equal / zero)
    movs r0, #79                             @ 080196C8
    ldr r1, =v_20007C30                      @ 080196CA &5-char text buffer
    strb r0, [r1, #1]                        @ 080196CC
    b .L080196EE                             @ 080196CE
.L080196D0:                                @ reached from 080196BE bcc (unsigned <)
    movs r0, #71                             @ 080196D0
    ldr r1, =v_20007C30                      @ 080196D2 &5-char text buffer
    strb r0, [r1, #1]                        @ 080196D4
    b .L080196EE                             @ 080196D6
.L080196D8:                                @ reached from 080196BC beq (equal / zero)
    movs r0, #52                             @ 080196D8
    ldr r1, =v_20007C30                      @ 080196DA &5-char text buffer
    strb r0, [r1, #1]                        @ 080196DC
    b .L080196EE                             @ 080196DE
.L080196E0:                                @ reached from 080196C4 bcc (unsigned <)
    movs r0, #53                             @ 080196E0
    ldr r1, =v_20007C30                      @ 080196E2 &5-char text buffer
    strb r0, [r1, #1]                        @ 080196E4
    b .L080196EE                             @ 080196E6
.L080196E8:                                @ reached from 080196C2 beq (equal / zero)
    movs r0, #51                             @ 080196E8
    ldr r1, =v_20007C30                      @ 080196EA &5-char text buffer
    strb r0, [r1, #1]                        @ 080196EC
.L080196EE:                                @ reached from 080196C6 b; 080196CE b; 080196D6 b; 080196DE b; 080196E6 b; falls in
    @ buffer[2] = '-'; buffer[3], buffer[4] = the two digits of 0x20008095 (buffer[3] = '0' below 10)
    movs r0, #45                             @ 080196EE
    ldr r1, =v_20007C30                      @ 080196F0 &5-char text buffer
    strb r0, [r1, #2]                        @ 080196F2
    ldr r0, =v_20008095                      @ 080196F4 &two-digit number shown by fn_08019698
    ldrb r0, [r0, #0]                        @ 080196F8
    cmp r0, #10                              @ 080196FA branch if two-digit number shown by fn_08019698 < 10
    blt .L08019710                           @ 080196FC
    uxtb r5, r5                              @ 080196FE
    movs r0, #10                             @ 08019700
    sdiv r0, r5, r0                          @ 08019702
    adds r0, #48                             @ 08019706
    ldr r1, =v_20007C30                      @ 08019708 &5-char text buffer
    strb r0, [r1, #3]                        @ 0801970A
    subs r5, #10                             @ 0801970C
    b .L08019716                             @ 0801970E
.L08019710:                                @ reached from 080196FC blt (signed <)
    movs r0, #48                             @ 08019710
    ldr r1, =v_20007C30                      @ 08019712 &5-char text buffer
    strb r0, [r1, #3]                        @ 08019714
.L08019716:                                @ reached from 0801970E b; falls in
    adds.w r0, r5, #48                       @ 08019716
    ldr r1, =v_20007C30                      @ 0801971A &5-char text buffer
    strb r0, [r1, #4]                        @ 0801971C
    @ draw on the main display, request a commit

    ldr r1, =v_20007C30                      @ 0801971E &5-char text buffer
    movs r0, #0                              @ 08019720
    bl lcd_draw_5char                        @ 08019722
    movs r0, #1                              @ 08019726
    ldr r1, =v_2000805B                      @ 08019728 &LCD commit request
    strb r0, [r1, #0]                        @ 0801972C
    pop {r0, r4, r5, pc}                     @ 0801972E
ENDFUNC fn_08019698
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019738 - calibration end text on the main display
@ Replaces : 0x08019738 FUN_08019738 (v2.05, 90 bytes)
@ In       : r0 = text index 0..3 (strings "OFF-E", "G-END", "400-E", "5KEND")
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ RAM      : clears the main minus sign; strings v205_tab_08029218 / 08029220 / 08029228 / 08029230
@ Spec     : analysis/lcd_map.md 2
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019738
    push {r4, lr}                            @ 08019738
    movs r4, r0                              @ 0801973A
    ldr r0, =lcd_shadow                      @ 0801973C &LCD shadow
    ldr r0, [r0, #12]                        @ 0801973E
    bics.w r0, r0, #128                      @ 08019740
    ldr r1, =lcd_shadow                      @ 08019744 &LCD shadow
    str r0, [r1, #12]                        @ 08019746 w3 &= ~0x80: clears main minus
    @ index 0 -> "OFF-E", 1 -> "G-END", 2 -> "400-E", 3 -> "5KEND"; any other index draws nothing

    uxtb r4, r4                              @ 08019748
    cmp r4, #0                               @ 0801974A
    beq .L0801975A                           @ 0801974C
    cmp r4, #2                               @ 0801974E
    beq .L08019772                           @ 08019750
    bcc .L08019766                           @ 08019752
    cmp r4, #3                               @ 08019754
    beq .L0801977E                           @ 08019756
    b .L08019788                             @ 08019758
.L0801975A:                                @ reached from 0801974C beq (equal / zero)
    ldr r1, =v205_tab_08029218               @ 0801975A
    movs r0, #0                              @ 0801975E
    bl lcd_draw_5char                        @ 08019760
    b .L08019788                             @ 08019764
.L08019766:                                @ reached from 08019752 bcc (unsigned <)
    ldr r1, =v205_tab_08029220               @ 08019766
    movs r0, #0                              @ 0801976A
    bl lcd_draw_5char                        @ 0801976C
    b .L08019788                             @ 08019770
.L08019772:                                @ reached from 08019750 beq (equal / zero)
    ldr r1, =v205_tab_08029228               @ 08019772
    movs r0, #0                              @ 08019776
    bl lcd_draw_5char                        @ 08019778
    b .L08019788                             @ 0801977C
.L0801977E:                                @ reached from 08019756 beq (equal / zero)
    ldr r1, =v205_tab_08029230               @ 0801977E
    movs r0, #0                              @ 08019782
    bl lcd_draw_5char                        @ 08019784
.L08019788:                                @ reached from 08019758 b; 08019764 b; 08019770 b; 0801977C b; falls in
    movs r0, #1                              @ 08019788
    ldr r1, =v_2000805B                      @ 0801978A &LCD commit request
    strb r0, [r1, #0]                        @ 0801978E
    pop {r4, pc}                             @ 08019790
ENDFUNC fn_08019738
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019792 - "SdCAL" on the main display (decimal point 3), committed
@ Replaces : 0x08019792 FUN_08019792 (v2.05, 36 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029238 "SdCAL"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019792
    push {r7, lr}                            @ 08019792
    ldr r0, =lcd_shadow                      @ 08019794 &LCD shadow
    ldr r0, [r0, #12]                        @ 08019796
    bics.w r0, r0, #128                      @ 08019798
    ldr r1, =lcd_shadow                      @ 0801979C &LCD shadow
    str r0, [r1, #12]                        @ 0801979E w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029238               @ 080197A0
    movs r0, #0                              @ 080197A4
    bl lcd_draw_5char                        @ 080197A6
    movs r0, #3                              @ 080197AA
    bl fn_0801717E                           @ 080197AC
    bl lcd_commit_shadow                     @ 080197B0
    pop {r0, pc}                             @ 080197B4
ENDFUNC fn_08019792
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080197B6 - "SdSAv" on the main display (decimal point 3), committed
@ Replaces : 0x080197B6 FUN_080197B6 (v2.05, 36 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029240 "SdSAv"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080197B6
    push {r7, lr}                            @ 080197B6
    ldr r0, =lcd_shadow                      @ 080197B8 &LCD shadow
    ldr r0, [r0, #12]                        @ 080197BA
    bics.w r0, r0, #128                      @ 080197BC
    ldr r1, =lcd_shadow                      @ 080197C0 &LCD shadow
    str r0, [r1, #12]                        @ 080197C2 w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029240               @ 080197C4
    movs r0, #0                              @ 080197C8
    bl lcd_draw_5char                        @ 080197CA
    movs r0, #3                              @ 080197CE
    bl fn_0801717E                           @ 080197D0
    bl lcd_commit_shadow                     @ 080197D4
    pop {r0, pc}                             @ 080197D8
ENDFUNC fn_080197B6
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080197E0 - "SdSEt" on the main display (decimal point 3), committed
@ Replaces : 0x080197E0 FUN_080197E0 (v2.05, 36 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029248 "SdSEt"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080197E0
    push {r7, lr}                            @ 080197E0
    ldr r0, =lcd_shadow                      @ 080197E2 &LCD shadow
    ldr r0, [r0, #12]                        @ 080197E4
    bics.w r0, r0, #128                      @ 080197E6
    ldr r1, =lcd_shadow                      @ 080197EA &LCD shadow
    str r0, [r1, #12]                        @ 080197EC w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029248               @ 080197EE
    movs r0, #0                              @ 080197F2
    bl lcd_draw_5char                        @ 080197F4
    movs r0, #3                              @ 080197F8
    bl fn_0801717E                           @ 080197FA
    bl lcd_commit_shadow                     @ 080197FE
    pop {r0, pc}                             @ 08019802
ENDFUNC fn_080197E0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019808 - "SAvEd" on the main display (no decimal point), committed
@ Replaces : 0x08019808 FUN_08019808 (v2.05, 36 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029250 "SAvEd"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019808
    push {r7, lr}                            @ 08019808
    ldr r0, =lcd_shadow                      @ 0801980A &LCD shadow
    ldr r0, [r0, #12]                        @ 0801980C
    bics.w r0, r0, #128                      @ 0801980E
    ldr r1, =lcd_shadow                      @ 08019812 &LCD shadow
    str r0, [r1, #12]                        @ 08019814 w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029250               @ 08019816
    movs r0, #0                              @ 0801981A
    bl lcd_draw_5char                        @ 0801981C
    movs r0, #0                              @ 08019820
    bl fn_0801717E                           @ 08019822
    bl lcd_commit_shadow                     @ 08019826
    pop {r0, pc}                             @ 0801982A
ENDFUNC fn_08019808
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801982C - "-Err-" on the main display (no decimal point), committed
@ Replaces : 0x0801982C FUN_0801982C (v2.05, 36 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029258 "-Err-"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801982C
    push {r7, lr}                            @ 0801982C
    ldr r0, =lcd_shadow                      @ 0801982E &LCD shadow
    ldr r0, [r0, #12]                        @ 08019830
    bics.w r0, r0, #128                      @ 08019832
    ldr r1, =lcd_shadow                      @ 08019836 &LCD shadow
    str r0, [r1, #12]                        @ 08019838 w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029258               @ 0801983A
    movs r0, #0                              @ 0801983E
    bl lcd_draw_5char                        @ 08019840
    movs r0, #0                              @ 08019844
    bl fn_0801717E                           @ 08019846
    bl lcd_commit_shadow                     @ 0801984A
    pop {r0, pc}                             @ 0801984E
ENDFUNC fn_0801982C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019854 - " CAL1" on the main display
@ Replaces : 0x08019854 FUN_08019854 (v2.05, 38 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ RAM      : clears the main minus sign; string v205_tab_08029260 " CAL1"
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019854
    push {r7, lr}                            @ 08019854
    ldr r0, =lcd_shadow                      @ 08019856 &LCD shadow
    ldr r0, [r0, #12]                        @ 0801985A
    bics.w r0, r0, #128                      @ 0801985C
    ldr r1, =lcd_shadow                      @ 08019860 &LCD shadow
    str r0, [r1, #12]                        @ 08019864 w3 &= ~0x80: clears main minus
    ldr r1, =v205_tab_08029260               @ 08019866
    movs r0, #0                              @ 0801986A
    bl lcd_draw_5char                        @ 0801986C
    movs r0, #1                              @ 08019870
    ldr r1, =v_2000805B                      @ 08019872 &LCD commit request
    strb r0, [r1, #0]                        @ 08019876
    pop {r0, pc}                             @ 08019878
ENDFUNC fn_08019854
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019880 - " CAL " on the sub display
@ Replaces : 0x08019880 FUN_08019880 (v2.05, 44 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ RAM      : clears the sub minus sign (w4 bit 29) and the sub decimal point; string v205_tab_08029268 " CAL "
@ Spec     : DESIGN.md 6.8 (message list); string table in ui/tables_v205.s
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019880
    push {r7, lr}                            @ 08019880
    ldr r0, =lcd_shadow                      @ 08019882 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019886
    bics.w r0, r0, #536870912                @ 08019888
    ldr r1, =lcd_shadow                      @ 0801988C &LCD shadow
    str r0, [r1, #16]                        @ 08019890 w4 &= ~0x20000000: clears sub minus
    movs r0, #0                              @ 08019892
    bl fn_08017FB4                           @ 08019894
    ldr r1, =v205_tab_08029268               @ 08019898
    movs r0, #1                              @ 0801989C
    bl lcd_draw_5char                        @ 0801989E
    movs r0, #1                              @ 080198A2
    ldr r1, =v_2000805B                      @ 080198A4 &LCD commit request
    strb r0, [r1, #0]                        @ 080198A8
    pop {r0, pc}                             @ 080198AA
ENDFUNC fn_08019880
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080198B0 - "LoBAt" on the sub display
@ Replaces : 0x080198B0 FUN_080198B0 (v2.05, 76 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ RAM      : clears the sub "k" unit (w4 bit 17); writes the text buffer 0x20007C30 = 'L' 'o' 'B' 'A' 't'
@ Spec     : DESIGN.md 6.8 (message list)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080198B0
    push {r7, lr}                            @ 080198B0
    ldr r0, =lcd_shadow                      @ 080198B2 &LCD shadow
    ldr r0, [r0, #16]                        @ 080198B6
    bics.w r0, r0, #131072                   @ 080198B8
    ldr r1, =lcd_shadow                      @ 080198BC &LCD shadow
    str r0, [r1, #16]                        @ 080198C0 w4 &= ~0x20000: clears k (sub)
    movs r0, #76                             @ 080198C2
    ldr r1, =v_20007C30                      @ 080198C4 &5-char text buffer
    strb r0, [r1, #0]                        @ 080198C8
    movs r0, #111                            @ 080198CA
    ldr r1, =v_20007C30                      @ 080198CC &5-char text buffer
    strb r0, [r1, #1]                        @ 080198D0
    movs r0, #66                             @ 080198D2
    ldr r1, =v_20007C30                      @ 080198D4 &5-char text buffer
    strb r0, [r1, #2]                        @ 080198D8
    movs r0, #65                             @ 080198DA
    ldr r1, =v_20007C30                      @ 080198DC &5-char text buffer
    strb r0, [r1, #3]                        @ 080198E0
    movs r0, #116                            @ 080198E2
    ldr r1, =v_20007C30                      @ 080198E4 &5-char text buffer
    strb r0, [r1, #4]                        @ 080198E8
    ldr r1, =v_20007C30                      @ 080198EA &5-char text buffer
    movs r0, #1                              @ 080198EE
    bl lcd_draw_5char                        @ 080198F0
    movs r0, #1                              @ 080198F4
    ldr r1, =v_2000805B                      @ 080198F6 &LCD commit request
    strb r0, [r1, #0]                        @ 080198F8
    pop {r0, pc}                             @ 080198FA
ENDFUNC fn_080198B0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080198FC - "SdEnd" on the sub display
@ Replaces : 0x080198FC FUN_080198FC (v2.05, 76 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ RAM      : clears the sub "k" unit (w4 bit 17); writes the text buffer = 'S' 'd' 'E' 'n' 'd'
@ Spec     : DESIGN.md 6.8
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080198FC
    push {r7, lr}                            @ 080198FC
    ldr r0, =lcd_shadow                      @ 080198FE &LCD shadow
    ldr r0, [r0, #16]                        @ 08019902
    bics.w r0, r0, #131072                   @ 08019904
    ldr r1, =lcd_shadow                      @ 08019908 &LCD shadow
    str r0, [r1, #16]                        @ 0801990C w4 &= ~0x20000: clears k (sub)
    movs r0, #83                             @ 0801990E
    ldr r1, =v_20007C30                      @ 08019910 &5-char text buffer
    strb r0, [r1, #0]                        @ 08019914
    movs r0, #100                            @ 08019916
    ldr r1, =v_20007C30                      @ 08019918 &5-char text buffer
    strb r0, [r1, #1]                        @ 0801991C
    movs r0, #69                             @ 0801991E
    ldr r1, =v_20007C30                      @ 08019920 &5-char text buffer
    strb r0, [r1, #2]                        @ 08019924
    movs r0, #110                            @ 08019926
    ldr r1, =v_20007C30                      @ 08019928 &5-char text buffer
    strb r0, [r1, #3]                        @ 0801992C
    movs r0, #100                            @ 0801992E
    ldr r1, =v_20007C30                      @ 08019930 &5-char text buffer
    strb r0, [r1, #4]                        @ 08019934
    ldr r1, =v_20007C30                      @ 08019936 &5-char text buffer
    movs r0, #1                              @ 0801993A
    bl lcd_draw_5char                        @ 0801993C
    movs r0, #1                              @ 08019940
    ldr r1, =v_2000805B                      @ 08019942 &LCD commit request
    strb r0, [r1, #0]                        @ 08019944
    pop {r0, pc}                             @ 08019946
ENDFUNC fn_080198FC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019948 - "SdEnn" on the sub display (SD error number)
@ Replaces : 0x08019948 FUN_08019948 (v2.05, 108 bytes)
@ In       : r0 = number 0..99 (low byte; a larger number is shown modulo 100)
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only
@ Deviation: OF-47 (v2.05: units digit (n - 10) + 0x30 and tens digit n / 10 + 0x30, right for n = 0..19 only; both digits are now
@            taken modulo 10, so every n up to 99 reads correctly)
@ RAM      : clears the sub "k" unit (w4 bit 17); writes the text buffer = 'S' 'd' 'E' tens ('0' below 10) units
@ Spec     : DESIGN.md 6.8
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019948
    push {r3, r4, r5, lr}                    @ 08019948
    movs r4, r0                              @ 0801994A
    movs r5, r4                              @ 0801994C
    ldr r0, =lcd_shadow                      @ 0801994E &LCD shadow
    ldr r0, [r0, #16]                        @ 08019952
    bics.w r0, r0, #131072                   @ 08019954
    ldr r1, =lcd_shadow                      @ 08019958 &LCD shadow
    str r0, [r1, #16]                        @ 0801995C w4 &= ~0x20000: clears k (sub)
    movs r0, #83                             @ 0801995E
    ldr r1, =v_20007C30                      @ 08019960 &5-char text buffer
    strb r0, [r1, #0]                        @ 08019964
    movs r0, #100                            @ 08019966
    ldr r1, =v_20007C30                      @ 08019968 &5-char text buffer
    strb r0, [r1, #1]                        @ 0801996C
    movs r0, #69                             @ 0801996E
    ldr r1, =v_20007C30                      @ 08019970 &5-char text buffer
    strb r0, [r1, #2]                        @ 08019974
    @ OF-47: tens = (n / 10) mod 10, units = n mod 10.  v2.05 computed tens = n / 10 and units = n - 10 for n >= 10, which is
    @ right for n = 0..19 only (n = 20 gave "2:", n = 23 "2=").  The code 100 (logging stopped by a low battery) is
    @ routed to the "LoBAt" text by fn_0801797C before it reaches this routine.
    uxtb r5, r5                              @ 08019976 r5 = n
    movs r0, #10                             @ 0801997E
    udiv r1, r5, r0                          @ r1 = n / 10
    udiv r2, r1, r0                          @ r2 = n / 100
    mls r3, r2, r0, r1                       @ r3 = tens digit = n / 10 - 10 * (n / 100)
    mls r5, r1, r0, r5                       @ r5 = units digit = n - 10 * (n / 10)
    adds r3, #48                             @ 08019984 tens character
    ldr r1, =v_20007C30                      @ 08019986 &5-char text buffer
    strb r3, [r1, #3]                        @ 0801998A
    adds.w r0, r5, #48                       @ 08019998 units character
    ldr r1, =v_20007C30                      @ 0801999C &5-char text buffer
    strb r0, [r1, #4]                        @ 080199A0
    ldr r1, =v_20007C30                      @ 080199A2 &5-char text buffer
    movs r0, #1                              @ 080199A6
    bl lcd_draw_5char                        @ 080199A8
    movs r0, #1                              @ 080199AC
    ldr r1, =v_2000805B                      @ 080199AE &LCD commit request
    strb r0, [r1, #0]                        @ 080199B0
    pop {r0, r4, r5, pc}                     @ 080199B2
ENDFUNC fn_08019948
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080199B4 - overload text " OFL " on the main or sub display
@ Replaces : 0x080199B4 FUN_080199B4 (v2.05, 110 bytes)
@ In       : r0 = 0 main display, 1 sub display
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20008076 (jack warning), 0x20008045 (negative reading); clears or sets the minus sign of the chosen display;
@            string v205_tab_08029270 " OFL "
@ Spec     : analysis/autorange_and_scheduler.md 2.4 (OL), analysis/lcd_map.md 2
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080199B4
    @ main display with the jack warning active: draw " LEAD" instead (fn_08019A74)
    push {r4, lr}                            @ 080199B4
    movs r4, r0                              @ 080199B6
    uxtb r4, r4                              @ 080199B8
    cmp r4, #0                               @ 080199BA
    bne .L080199D0                           @ 080199BC
    ldr r0, =v_20008076                      @ 080199BE &jack warning flag
    ldrb r0, [r0, #0]                        @ 080199C2
    cmp r0, #0                               @ 080199C4 branch if jack warning flag == 0
    beq .L080199D0                           @ 080199C6
    movs r0, #0                              @ 080199C8
    bl fn_08019A74                           @ 080199CA
    b .L08019A20                             @ 080199CE
.L080199D0:                                @ reached from 080199BC bne (not equal / non-zero); 080199C6 beq (equal / zero)
    @ sub display: sub minus off; main display: main minus on when 0x20008045 (negative OL) is set, otherwise off

    uxtb r4, r4                              @ 080199D0
    cmp r4, #1                               @ 080199D2
    bne .L080199E8                           @ 080199D4
    ldr r0, =lcd_shadow                      @ 080199D6 &LCD shadow
    ldr r0, [r0, #16]                        @ 080199DA
    bics.w r0, r0, #536870912                @ 080199DC
    ldr r1, =lcd_shadow                      @ 080199E0 &LCD shadow
    str r0, [r1, #16]                        @ 080199E4 w4 &= ~0x20000000: clears sub minus
    b .L08019A14                             @ 080199E6
.L080199E8:                                @ reached from 080199D4 bne (not equal / non-zero)
    ldr r0, =v_20008045                      @ 080199E8 &negative-reading flag
    ldrb r0, [r0, #0]                        @ 080199EC
    cmp r0, #0                               @ 080199EE branch if negative-reading flag == 0
    beq .L08019A04                           @ 080199F0
    ldr r0, =lcd_shadow                      @ 080199F2 &LCD shadow
    ldr r0, [r0, #12]                        @ 080199F6
    orrs.w r0, r0, #128                      @ 080199F8
    ldr r1, =lcd_shadow                      @ 080199FC &LCD shadow
    str r0, [r1, #12]                        @ 08019A00 w3 |= 0x80: main minus
    b .L08019A14                             @ 08019A02
.L08019A04:                                @ reached from 080199F0 beq (equal / zero)
    ldr r0, =lcd_shadow                      @ 08019A04 &LCD shadow
    ldr r0, [r0, #12]                        @ 08019A08
    bics.w r0, r0, #128                      @ 08019A0A
    ldr r1, =lcd_shadow                      @ 08019A0E &LCD shadow
    str r0, [r1, #12]                        @ 08019A12 w3 &= ~0x80: clears main minus
.L08019A14:                                @ reached from 080199E6 b; 08019A02 b; falls in
    ldr r1, =v205_tab_08029270               @ 08019A14
    movs r0, r4                              @ 08019A18
    uxtb r0, r0                              @ 08019A1A
    bl lcd_draw_5char                        @ 08019A1C
.L08019A20:                                @ reached from 080199CE b; falls in
    pop {r4, pc}                             @ 08019A20
ENDFUNC fn_080199B4
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019A22 - " OPEN" on the main or sub display
@ Replaces : 0x08019A22 FUN_08019A22 (v2.05, 82 bytes)
@ In       : r0 = 0 main display, 1 sub display
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x20008076 (jack warning); clears the minus sign of the chosen display; string v205_tab_08029278 " OPEN"
@ Spec     : DESIGN.md 6.8
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019A22
    @ main display with the jack warning active: draw " LEAD" instead (fn_08019A74)

    push {r4, lr}                            @ 08019A22
    movs r4, r0                              @ 08019A24
    uxtb r4, r4                              @ 08019A26
    cmp r4, #0                               @ 08019A28
    bne .L08019A3E                           @ 08019A2A
    ldr r0, =v_20008076                      @ 08019A2C &jack warning flag
    ldrb r0, [r0, #0]                        @ 08019A30
    cmp r0, #0                               @ 08019A32 branch if jack warning flag == 0
    beq .L08019A3E                           @ 08019A34
    movs r0, #0                              @ 08019A36
    bl fn_08019A74                           @ 08019A38
    b .L08019A72                             @ 08019A3C
.L08019A3E:                                @ reached from 08019A2A bne (not equal / non-zero); 08019A34 beq (equal / zero)
    uxtb r4, r4                              @ 08019A3E
    cmp r4, #1                               @ 08019A40
    bne .L08019A56                           @ 08019A42
    ldr r0, =lcd_shadow                      @ 08019A44 &LCD shadow
    ldr r0, [r0, #16]                        @ 08019A48
    bics.w r0, r0, #536870912                @ 08019A4A
    ldr r1, =lcd_shadow                      @ 08019A4E &LCD shadow
    str r0, [r1, #16]                        @ 08019A52 w4 &= ~0x20000000: clears sub minus
    b .L08019A66                             @ 08019A54
.L08019A56:                                @ reached from 08019A42 bne (not equal / non-zero)
    ldr r0, =lcd_shadow                      @ 08019A56 &LCD shadow
    ldr r0, [r0, #12]                        @ 08019A5A
    bics.w r0, r0, #128                      @ 08019A5C
    ldr r1, =lcd_shadow                      @ 08019A60 &LCD shadow
    str r0, [r1, #12]                        @ 08019A64 w3 &= ~0x80: clears main minus
.L08019A66:                                @ reached from 08019A54 b; falls in
    ldr r1, =v205_tab_08029278               @ 08019A66
    movs r0, r4                              @ 08019A6A
    uxtb r0, r0                              @ 08019A6C
    bl lcd_draw_5char                        @ 08019A6E
.L08019A72:                                @ reached from 08019A3C b; falls in
    pop {r4, pc}                             @ 08019A72
ENDFUNC fn_08019A22
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019A74 - " LEAD" on the main or sub display
@ Replaces : 0x08019A74 FUN_08019A74 (v2.05, 18 bytes)
@ In       : r0 = 0 main display, 1 sub display
@ Out      : -
@ Context  : main only
@ RAM      : string v205_tab_08029280 " LEAD"
@ Spec     : analysis/lcd_map.md; jack warning 0x20008076
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019A74
    push {r4, lr}                            @ 08019A74
    movs r4, r0                              @ 08019A76
    ldr r1, =v205_tab_08029280               @ 08019A78
    movs r0, r4                              @ 08019A7C
    uxtb r0, r0                              @ 08019A7E
    bl lcd_draw_5char                        @ 08019A80
    pop {r4, pc}                             @ 08019A84
ENDFUNC fn_08019A74
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019A86 - "-----" on the main or sub display
@ Replaces : 0x08019A86 FUN_08019A86 (v2.05, 18 bytes)
@ In       : r0 = 0 main display, 1 sub display
@ Out      : -
@ Context  : main only
@ RAM      : string v205_tab_08029288 "-----"
@ Spec     : DESIGN.md 6.8
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019A86
    push {r4, lr}                            @ 08019A86
    movs r4, r0                              @ 08019A88
    ldr r1, =v205_tab_08029288               @ 08019A8A
    movs r0, r4                              @ 08019A8E
    uxtb r0, r0                              @ 08019A90
    bl lcd_draw_5char                        @ 08019A92
    pop {r4, pc}                             @ 08019A96
ENDFUNC fn_08019A86
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08019A98 - five spaces on the main or sub display (blank)
@ Replaces : 0x08019A98 FUN_08019A98 (v2.05, 66 bytes)
@ In       : r0 = 0 main display, 1 sub display
@ Out      : -
@ Context  : main only
@ RAM      : clears 0x20008045 and the minus sign of the chosen display; string v205_tab_080291B0 "     "
@ Spec     : analysis/autorange_and_scheduler.md 2.4 (blank during a range change)
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08019A98
    push {r4, lr}                            @ 08019A98
    movs r4, r0                              @ 08019A9A
    movs r0, #0                              @ 08019A9C
    ldr r1, =v_20008045                      @ 08019A9E &negative-reading flag
    strb r0, [r1, #0]                        @ 08019AA2
    uxtb r4, r4                              @ 08019AA4
    cmp r4, #1                               @ 08019AA6
    bne .L08019ABC                           @ 08019AA8
    ldr r0, =lcd_shadow                      @ 08019AAA &LCD shadow
    ldr r0, [r0, #16]                        @ 08019AAE
    bics.w r0, r0, #536870912                @ 08019AB0
    ldr r1, =lcd_shadow                      @ 08019AB4 &LCD shadow
    str r0, [r1, #16]                        @ 08019AB8 w4 &= ~0x20000000: clears sub minus
    b .L08019ACC                             @ 08019ABA
.L08019ABC:                                @ reached from 08019AA8 bne (not equal / non-zero)
    ldr r0, =lcd_shadow                      @ 08019ABC &LCD shadow
    ldr r0, [r0, #12]                        @ 08019AC0
    bics.w r0, r0, #128                      @ 08019AC2
    ldr r1, =lcd_shadow                      @ 08019AC6 &LCD shadow
    str r0, [r1, #12]                        @ 08019ACA w3 &= ~0x80: clears main minus
.L08019ACC:                                @ reached from 08019ABA b; falls in
    ldr r1, =v205_tab_080291B0               @ 08019ACC
    movs r0, r4                              @ 08019AD0
    uxtb r0, r0                              @ 08019AD2
    bl lcd_draw_5char                        @ 08019AD4
    pop {r4, pc}                             @ 08019AD8
ENDFUNC fn_08019A98
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801A854 - version splash on the main display ("V-2.05" strict, "F-0.91" production, config.inc)
@ Replaces : 0x0801A854 FUN_0801A854 (v2.05, 62 bytes)
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Context  : main only; called by the power-on window (CAL)
@ RAM      : clears the shadow (fn_0801A81C); writes digit words and the text buffer 0x20007C30
@ Spec     : DESIGN.md 7.1; the digits of 205 are split (fn_0801B090), leading zeros blanked (fn_0801B130, point position 0),
@            then characters 0 and 1 are overwritten with 'V' and '-', giving "V-205", and the decimal point 2 is set (fn_0801717E) = "V-2.05"
@
@ Clobbers : r0, r1, r2 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0801A854
    push {r4, lr}                            @ 0801A854
    @ production: the version text of config.inc ("F-0.91"), all five characters written, point 2 as v2.05
    bl fn_0801A81C                           @ clear the shadow, as v2.05
    ldr r1, =v_20007C30                      @ 5-char text buffer
    movs r0, #FW_VER_C0
    strb r0, [r1, #0]
    movs r0, #FW_VER_C1
    strb r0, [r1, #1]
    movs r0, #FW_VER_C2
    strb r0, [r1, #2]
    movs r0, #FW_VER_C3
    strb r0, [r1, #3]
    movs r0, #FW_VER_C4
    strb r0, [r1, #4]
    movs r0, #0
    bl lcd_draw_5char                        @ main display
    movs r0, #2                              @ 0801A882
    bl fn_0801717E                           @ 0801A884
    movs r0, #1                              @ 0801A888
    ldr r1, =v_2000805B                      @ 0801A88A &LCD commit request
    strb r0, [r1, #0]                        @ 0801A88E
    pop {r4, pc}                             @ 0801A890
ENDFUNC fn_0801A854
    .ltorg

@ -----------------------------------------------------------------------------
@ ui_blank_draw - draw five spaces or five dashes on the main digits for a ui_blank_req request
@ Replaces : nothing (new); the v2.05 blank branch 0x08016FE2..0x08017004 is the spaces case
@ In       : r0 = request value (1 = spaces, 2 = dashes, 3 = keep the digits on the glass, OF-30 port correction)
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only; called from fn_08016E08
@ RAM      : writes lcd_shadow words 3, 4..7 (through lcd_draw_5char), 0x20008045, 0x20008046, 0x2000805B;
@            reads hold_stage2 (0x20008050)
@ Spec     : analysis/autorange_and_scheduler.md 2.4 (blank rule), 5.2 P5; OF-30, OF-32
@ Deviation: OF-30, OF-32, IMP-01
@ -----------------------------------------------------------------------------
FUNC ui_blank_draw
    push {r4, lr}
    movs r4, r0                             @ r4 = request (1 spaces, 2 dashes)
    ldr r0, =hold_stage2                    @ v2.05 0x08016FEC: with auto-hold stage 2 nothing is drawn
    ldrb r0, [r0]
    cbnz r0, .Lbd_clear_ol                  @ stage 2 set: keep the old digits, only clear OL below
    cmp r4, #3
    beq .Lbd_clear_ol                       @ request 3 (OF-30 correction): keep the digits, as auto-hold stage 2 does
    cmp r4, #2
    beq .Lbd_dashes                         @ request 2: dashes
    movs r0, #0                             @ request 1: the v2.05 blank (spaces, main digits, sign cleared)
    bl fn_08019A98
    b .Lbd_commit
.Lbd_dashes:
    movs r0, #0
    ldr r1, =v_20008045
    strb r0, [r1]                           @ negative-reading flag cleared, as fn_08019A98 does
    ldr r0, =lcd_shadow
    ldr r1, [r0, #12]                       @ shadow word 3
    bics r1, r1, #0x80                      @ main minus (w3 bit 7) off
    str r1, [r0, #12]
    movs r0, #0
    bl fn_0801717E                          @ main decimal point off (the value drawn before left it: "----.-" otherwise)
    movs r0, #0                             @ position flag 0 = main digits 5..9
    bl fn_08019A86                          @ "-----" (string 0x08029288)
.Lbd_commit:
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ ask for a commit: the drawers above do not set it
.Lbd_clear_ol:
    movs r0, #0
    ldr r1, =v_20008046
    strb r0, [r1]                           @ v2.05 0x08016FFC..0x08017002: the blank path clears the overload flag
    pop {r4, pc}
    .ltorg
ENDFUNC ui_blank_draw
