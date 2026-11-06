@ =============================================================================
@ refresh.s - UI: display refresh dispatcher, main value drawer, VA alternation, high-voltage flags (DESIGN.md 6.8)
@
@ Replaces fn_08016D34 (0x08016D34, called once per main-loop pass), fn_08016E08 (main value), fn_0800D664 / fn_0800D6E0
@ (VA sub-display alternation), fn_0800E848 / fn_0800EA24 (high-voltage warning flags), fn_080153AC (end of MEM view) and
@ fn_08015934 (held value).  The instruction streams are v2.05's; both builds add the blank / dash request ui_blank_req
@ in fn_08016E08 (OF-30; request 1 of OF-32 / IMP-01 rule P5 is written in production only); the port also adds
@   - the call of ui_bootwin_gate (IMP-02) at the start of fn_08016D34 and of lcd_commit_retry (IMP-06) at its end;
@   - the power-on window rules of IMP-02 (ui_bootwin_gate, ui_version_sub, ui_request_redraw): while CAL's window is open the
@     version "V-2.05" is shown on the sub display and the reading on the main digits, and nothing is drawn while a key
@     combination screen owns the display (request W7_to_W3.md item 1).
@ Context: main only, except fn_080153AC which is ISR-safe (called from IRQ28, DESIGN.md 3.4).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .bss_port.ui, "aw", %nobits

@ ui_blank_req: request from the measurement modules that the main digits show no value (request 2, OF-30: both builds;
@ request 1, OF-32 / IMP-01: production only).
@   0 = draw the value (v2.05 behaviour)
@   1 = draw five spaces (OF-32 BEEP / FREQ / PULSE / DUTY until the first valid result; IMP-01 rule P5 after a range change)
@   2 = draw five dashes (OF-30 LowZ while a voltage is present and the AC/DC decision is still pending)
@   3 = draw nothing, the digits on the glass stay (OF-30 correction: LowZ, the first mean of a pending voltage)
@ Written by AR / MODE (set at an apply, cleared on a mode change) and MRES / MFRQ (cleared when a valid result exists);
@ read by fn_08016E08.  Cleared by sys_reset with the rest of .bss_port.
    .global ui_blank_req
ui_blank_req:
    .space 1
@ ui_bw_state: power-on window display state (production, IMP-02): 0 window closed (or never seen), 1 window open with the
@ version shown on the sub display, 2 window open with a key combination screen on the display
ui_bw_state:
    .space 1
@ ui_skip_sub: 1 for the current refresh pass while the sub display shows the version (the sub-display blocks are skipped)
ui_skip_sub:
    .space 1
@ ui_lamp_test: 1 from the moment fn_0801A89C lights every segment (RANGE key inside the power-on window, DESIGN.md 7.1) until the
@ window closes; the refresh draws nothing meanwhile, so the lamp test stays on the glass as in v2.05 (production only, IMP-02)
    .global ui_lamp_test
ui_lamp_test:
    .space 1
    .balign 4

    .section .text.ui.refresh, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800D664 - VA modes: alternate the sub display between voltage and current every 3 s
@ Replaces : 0x0800D664 FUN_0800D664 (v2.05, 124 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called from loop step 4 on every 10 ms flag
@ RAM      : reads meter_mode; read-modify-writes 0x20007FD8 (counter, 10 ms ticks) and 0x200080C2 (0 = voltage, 1 = current)
@ Spec     : DESIGN.md 3.5 step 4; analysis/lcd_map.md 4.3
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0800D664
    push {r7, lr}                            @ 0800D664
    @ only in the VA modes 13, 14, 15, 22, 23, 24
    ldr r0, =meter_mode                      @ 0800D666 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D66A
    cmp r0, #13                              @ 0800D66C branch if mode == 13 (13 = uVA)
    beq .L0800D6A2                           @ 0800D66E
    ldr r0, =meter_mode                      @ 0800D670 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D674
    cmp r0, #14                              @ 0800D676 branch if mode == 14 (14 = mVA)
    beq .L0800D6A2                           @ 0800D678
    ldr r0, =meter_mode                      @ 0800D67A &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D67E
    cmp r0, #15                              @ 0800D680 branch if mode == 15 (15 = VA)
    beq .L0800D6A2                           @ 0800D682
    ldr r0, =meter_mode                      @ 0800D684 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D688
    cmp r0, #22                              @ 0800D68A branch if mode == 22 (22 = DCuVA)
    beq .L0800D6A2                           @ 0800D68C
    ldr r0, =meter_mode                      @ 0800D68E &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D692
    cmp r0, #23                              @ 0800D694 branch if mode == 23 (23 = DCmVA)
    beq .L0800D6A2                           @ 0800D696
    ldr r0, =meter_mode                      @ 0800D698 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800D69C
    cmp r0, #24                              @ 0800D69E branch if mode != 24 (24 = DCVA)
    bne .L0800D6DE                           @ 0800D6A0
.L0800D6A2:                                @ reached from 0800D66E beq (equal / zero); 0800D678 beq (equal / zero); 0800D682 beq (equal / zero); 0800D68C beq (equal / zero); 0800D696 beq (equal / zero); falls in
    @ count ticks (10 ms each when called from loop step 4); at 300 (3 s) toggle 0x200080C2 and redraw the sub display (fn_0800D6E0)

    ldr r0, =v_20007FD8                      @ 0800D6A2 &VA display alternation counter (10 ms ticks)
    ldrh r0, [r0, #0]                        @ 0800D6A6
    adds r0, r0, #1                          @ 0800D6A8
    ldr r1, =v_20007FD8                      @ 0800D6AA &VA display alternation counter (10 ms ticks)
    strh r0, [r1, #0]                        @ 0800D6AE
    ldr r0, =v_20007FD8                      @ 0800D6B0 &VA display alternation counter (10 ms ticks)
    ldrh r0, [r0, #0]                        @ 0800D6B4
    cmp.w r0, #300                           @ 0800D6B6 branch if VA display alternation counter (10 ms ticks) < 300
    blt .L0800D6DE                           @ 0800D6BA
    ldr r0, =v_200080C2                      @ 0800D6BC &VA sub-display selector (0 = V, 1 = A)
    ldrb r0, [r0, #0]                        @ 0800D6C0
    teq r0, #1                               @ 0800D6C2 branch if VA sub-display selector (0 = V, 1 = A) == 1
    beq .L0800D6D2                           @ 0800D6C6
    movs r0, #1                              @ 0800D6C8
    ldr r1, =v_200080C2                      @ 0800D6CA &VA sub-display selector (0 = V, 1 = A)
    strb r0, [r1, #0]                        @ 0800D6CE
    b .L0800D6DA                             @ 0800D6D0
.L0800D6D2:                                @ reached from 0800D6C6 beq (equal / zero)
    movs r0, #0                              @ 0800D6D2
    ldr r1, =v_200080C2                      @ 0800D6D4 &VA sub-display selector (0 = V, 1 = A)
    strb r0, [r1, #0]                        @ 0800D6D8
.L0800D6DA:                                @ reached from 0800D6D0 b; falls in
    bl fn_0800D6E0                           @ 0800D6DA
.L0800D6DE:                                @ reached from 0800D6A0 bne (not equal / non-zero); 0800D6BA blt (signed <); falls in
    pop {r0, pc}                             @ 0800D6DE
ENDFUNC fn_0800D664
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D6E0 - redraw the VA sub display after a voltage / current switch
@ Replaces : 0x0800D6E0 FUN_0800D6E0 (v2.05, 52 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads 0x200080C2; writes 0x20007FD8 = 0, 0x20008063 = 1, 0x20008062 = 1
@ Spec     : analysis/lcd_map.md 4.3 (SubV / SubA by 0x200080C2)
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0800D6E0
    push {r7, lr}                            @ 0800D6E0
    @ 0x200080C2 = 0 calls fn_0801801E, otherwise fn_0801803C (SET page drawers)
    ldr r0, =v_200080C2                      @ 0800D6E2 &VA sub-display selector (0 = V, 1 = A)
    ldrb r0, [r0, #0]                        @ 0800D6E6
    cmp r0, #0                               @ 0800D6E8 branch if VA sub-display selector (0 = V, 1 = A) != 0
    bne .L0800D6F2                           @ 0800D6EA
    bl fn_0801801E                           @ 0800D6EC
    b .L0800D6F6                             @ 0800D6F0
.L0800D6F2:                                @ reached from 0800D6EA bne (not equal / non-zero)
    bl fn_0801803C                           @ 0800D6F2
.L0800D6F6:                                @ reached from 0800D6F0 b; falls in
    @ restart the 3 s counter and request the sub-display unit refresh and the setup-page redraw

    movs r0, #0                              @ 0800D6F6
    ldr r1, =v_20007FD8                      @ 0800D6F8 &VA display alternation counter (10 ms ticks)
    strh r0, [r1, #0]                        @ 0800D6FC
    movs r0, #1                              @ 0800D6FE
    ldr r1, =v_20008063                      @ 0800D700 &sub-display refresh request
    strb r0, [r1, #0]                        @ 0800D704
    ldr r0, =v_20008063                      @ 0800D706 &sub-display refresh request
    ldrb r0, [r0, #0]                        @ 0800D70A
    ldr r1, =v_20008062                      @ 0800D70C &setup-page redraw request
    strb r0, [r1, #0]                        @ 0800D710
    pop {r0, pc}                             @ 0800D712
ENDFUNC fn_0800D6E0
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800E848 - high-voltage warning flags from the displayed reading
@ Replaces : 0x0800E848 FUN_0800E848 (v2.05, 428 bytes)
@ In       : -
@ Out      : 0x200080B1 and 0x200080B2 (high-voltage flags), the warning icon is redrawn (fn_0801A370)
@ Context  : main only; called from the post-processing of a new reading (FUNC, fn_0800DCFC) when the settle count is 0
@ RAM      : clears then sets 0x200080B1 / 0x200080B2; reads meter_mode, meter_range, 0x20008046 (OL), 0x20007D64 (D),
@            0x20007D7C, 0x200080CA
@ Spec     : analysis/lcd_map.md 4.2; thresholds via fn_0800EA24 (|value| >= threshold)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_0800E848
    push {r7, lr}                            @ 0800E848
    movs r0, #0                              @ 0800E84A
    ldr r1, =v_200080B2                      @ 0800E84C &high-voltage condition flag (second)
    strb r0, [r1, #0]                        @ 0800E850
    movs r0, #0                              @ 0800E852
    ldr r1, =v_200080B1                      @ 0800E854 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E858
    @ DCV / ACV range 3 (mode 1 or 2): 0x200080B2 set when |D| >= 6000 or OL
    ldr r0, =meter_mode                      @ 0800E85A &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E85E
    cmp r0, #1                               @ 0800E860 branch if mode == 1 (1 = DCV)
    beq .L0800E86E                           @ 0800E862
    ldr r0, =meter_mode                      @ 0800E864 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E868
    cmp r0, #2                               @ 0800E86A branch if mode != 2 (2 = ACV)
    bne .L0800E89C                           @ 0800E86C
.L0800E86E:                                @ reached from 0800E862 beq (equal / zero); falls in
    ldr r0, =meter_range                     @ 0800E86E &meter_range
    ldrb r0, [r0, #0]                        @ 0800E870
    cmp r0, #3                               @ 0800E872 branch if meter_range != 3
    bne .L0800E89C                           @ 0800E874
    movw r1, #6000                           @ 0800E876
    ldr r0, =v_20007D64                      @ 0800E87A &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E87C
    bl fn_0800EA24                           @ 0800E87E
    ldr r1, =v_200080B2                      @ 0800E882 &high-voltage condition flag (second)
    strb r0, [r1, #0]                        @ 0800E886
    ldr r0, =v_20008046                      @ 0800E888 &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 0800E88C
    cmp r0, #0                               @ 0800E88E branch if overload (OL) flag == 0
    beq .L0800E8CA                           @ 0800E890
    movs r0, #1                              @ 0800E892
    ldr r1, =v_200080B2                      @ 0800E894 &high-voltage condition flag (second)
    strb r0, [r1, #0]                        @ 0800E898
    b .L0800E8CA                             @ 0800E89A
.L0800E89C:                                @ reached from 0800E86C bne (not equal / non-zero); 0800E874 bne (not equal / non-zero)
    @ LowZ (mode 0): 0x200080B2 set when |D| >= 6000 or OL
    ldr r0, =meter_mode                      @ 0800E89C &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E8A0
    cmp r0, #0                               @ 0800E8A2 branch if mode != 0 (0 = LowZ)
    bne .L0800E8CA                           @ 0800E8A4
    movw r1, #6000                           @ 0800E8A6
    ldr r0, =v_20007D64                      @ 0800E8AA &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E8AC
    bl fn_0800EA24                           @ 0800E8AE
    ldr r1, =v_200080B2                      @ 0800E8B2 &high-voltage condition flag (second)
    strb r0, [r1, #0]                        @ 0800E8B6
    ldr r0, =v_20008046                      @ 0800E8B8 &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 0800E8BC
    cmp r0, #0                               @ 0800E8BE branch if overload (OL) flag == 0
    beq .L0800E8CA                           @ 0800E8C0
    movs r0, #1                              @ 0800E8C2
    ldr r1, =v_200080B2                      @ 0800E8C4 &high-voltage condition flag (second)
    strb r0, [r1, #0]                        @ 0800E8C8
.L0800E8CA:                                @ reached from 0800E890 beq (equal / zero); 0800E89A b; 0800E8A4 bne (not equal / non-zero); 0800E8C0 beq (equal / zero); falls in
    @ DCV / ACV: 0x200080B1 set when |D| >= 30000 (range 1), 3000 (range 2) or 300 (range 3), or when OL outside range 0
    ldr r0, =meter_mode                      @ 0800E8CA &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E8CE
    cmp r0, #1                               @ 0800E8D0 branch if mode == 1 (1 = DCV)
    beq .L0800E8DE                           @ 0800E8D2
    ldr r0, =meter_mode                      @ 0800E8D4 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E8D8
    cmp r0, #2                               @ 0800E8DA branch if mode != 2 (2 = ACV)
    bne .L0800E94A                           @ 0800E8DC
.L0800E8DE:                                @ reached from 0800E8D2 beq (equal / zero); falls in
    ldr r0, =meter_range                     @ 0800E8DE &meter_range
    ldrb r0, [r0, #0]                        @ 0800E8E0
    cmp r0, #0                               @ 0800E8E2 branch if meter_range == 0
    beq .L0800E8F2                           @ 0800E8E4
    cmp r0, #2                               @ 0800E8E6 branch if meter_range == 2
    beq .L0800E908                           @ 0800E8E8
    bcc .L0800E8F4                           @ 0800E8EA
    cmp r0, #3                               @ 0800E8EC branch if meter_range == 3
    beq .L0800E91C                           @ 0800E8EE
    b .L0800E92E                             @ 0800E8F0
.L0800E8F2:                                @ reached from 0800E8E4 beq (equal / zero)
    b .L0800E92E                             @ 0800E8F2
.L0800E8F4:                                @ reached from 0800E8EA bcc (unsigned <)
    movw r1, #30000                          @ 0800E8F4
    ldr r0, =v_20007D64                      @ 0800E8F8 &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E8FA
    bl fn_0800EA24                           @ 0800E8FC
    ldr r1, =v_200080B1                      @ 0800E900 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E904
    b .L0800E92E                             @ 0800E906
.L0800E908:                                @ reached from 0800E8E8 beq (equal / zero)
    movw r1, #3000                           @ 0800E908
    ldr r0, =v_20007D64                      @ 0800E90C &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E90E
    bl fn_0800EA24                           @ 0800E910
    ldr r1, =v_200080B1                      @ 0800E914 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E918
    b .L0800E92E                             @ 0800E91A
.L0800E91C:                                @ reached from 0800E8EE beq (equal / zero)
    mov.w r1, #300                           @ 0800E91C
    ldr r0, =v_20007D64                      @ 0800E920 &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E922
    bl fn_0800EA24                           @ 0800E924
    ldr r1, =v_200080B1                      @ 0800E928 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E92C
.L0800E92E:                                @ reached from 0800E8F0 b; 0800E8F2 b; 0800E906 b; 0800E91A b; falls in
    ldr r0, =meter_range                     @ 0800E92E &meter_range
    ldrb r0, [r0, #0]                        @ 0800E930
    cmp r0, #0                               @ 0800E932 branch if meter_range == 0
    beq .L0800E9EE                           @ 0800E934
    ldr r0, =v_20008046                      @ 0800E936 &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 0800E93A
    cmp r0, #0                               @ 0800E93C branch if overload (OL) flag == 0
    beq .L0800E9EE                           @ 0800E93E
    movs r0, #1                              @ 0800E940
    ldr r1, =v_200080B1                      @ 0800E942 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E946
    b .L0800E9EE                             @ 0800E948
.L0800E94A:                                @ reached from 0800E8DC bne (not equal / non-zero)
    @ VA modes 13, 14, 15, 22, 23, 24 at range 1 or 3: 0x200080B1 set when |0x20007D7C| >= 30000 or 0x200080CA is non-zero
    ldr r0, =meter_mode                      @ 0800E94A &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E94E
    cmp r0, #13                              @ 0800E950 branch if mode == 13 (13 = uVA)
    beq .L0800E986                           @ 0800E952
    ldr r0, =meter_mode                      @ 0800E954 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E958
    cmp r0, #14                              @ 0800E95A branch if mode == 14 (14 = mVA)
    beq .L0800E986                           @ 0800E95C
    ldr r0, =meter_mode                      @ 0800E95E &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E962
    cmp r0, #15                              @ 0800E964 branch if mode == 15 (15 = VA)
    beq .L0800E986                           @ 0800E966
    ldr r0, =meter_mode                      @ 0800E968 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E96C
    cmp r0, #22                              @ 0800E96E branch if mode == 22 (22 = DCuVA)
    beq .L0800E986                           @ 0800E970
    ldr r0, =meter_mode                      @ 0800E972 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E976
    cmp r0, #23                              @ 0800E978 branch if mode == 23 (23 = DCmVA)
    beq .L0800E986                           @ 0800E97A
    ldr r0, =meter_mode                      @ 0800E97C &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E980
    cmp r0, #24                              @ 0800E982 branch if mode != 24 (24 = DCVA)
    bne .L0800E9C0                           @ 0800E984
.L0800E986:                                @ reached from 0800E952 beq (equal / zero); 0800E95C beq (equal / zero); 0800E966 beq (equal / zero); 0800E970 beq (equal / zero); 0800E97A beq (equal / zero); falls in
    ldr r0, =meter_range                     @ 0800E986 &meter_range
    ldrb r0, [r0, #0]                        @ 0800E988
    cmp r0, #1                               @ 0800E98A branch if meter_range == 1
    beq .L0800E996                           @ 0800E98C
    ldr r0, =meter_range                     @ 0800E98E &meter_range
    ldrb r0, [r0, #0]                        @ 0800E990
    cmp r0, #3                               @ 0800E992 branch if meter_range != 3
    bne .L0800E9EE                           @ 0800E994
.L0800E996:                                @ reached from 0800E98C beq (equal / zero); falls in
    movw r1, #30000                          @ 0800E996
    ldr r0, =v_20007D7C                      @ 0800E99A &VA voltage count
    ldr r0, [r0, #0]                         @ 0800E99E
    bl fn_0800EA24                           @ 0800E9A0
    ldr r1, =v_200080B1                      @ 0800E9A4 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E9A8
    ldr r0, =v_200080CA                      @ 0800E9AA &VA signed flag tested by fn_0800E848
    ldrsb.w r0, [r0]                         @ 0800E9AE
    cmp r0, #0                               @ 0800E9B2 branch if VA signed flag tested by fn_0800E848 == 0
    beq .L0800E9EE                           @ 0800E9B4
    movs r0, #1                              @ 0800E9B6
    ldr r1, =v_200080B1                      @ 0800E9B8 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E9BC
    b .L0800E9EE                             @ 0800E9BE
.L0800E9C0:                                @ reached from 0800E984 bne (not equal / non-zero)
    @ LowZ: 0x200080B1 set when |D| >= 300 or OL
    ldr r0, =meter_mode                      @ 0800E9C0 &meter_mode
    ldrb r0, [r0, #0]                        @ 0800E9C4
    cmp r0, #0                               @ 0800E9C6 branch if mode != 0 (0 = LowZ)
    bne .L0800E9EE                           @ 0800E9C8
    mov.w r1, #300                           @ 0800E9CA
    ldr r0, =v_20007D64                      @ 0800E9CE &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 0800E9D0
    bl fn_0800EA24                           @ 0800E9D2
    ldr r1, =v_200080B1                      @ 0800E9D6 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E9DA
    ldr r0, =v_20008046                      @ 0800E9DC &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 0800E9E0
    cmp r0, #0                               @ 0800E9E2 branch if overload (OL) flag == 0
    beq .L0800E9EE                           @ 0800E9E4
    movs r0, #1                              @ 0800E9E6
    ldr r1, =v_200080B1                      @ 0800E9E8 &high-voltage warning flag
    strb r0, [r1, #0]                        @ 0800E9EC
.L0800E9EE:                                @ reached from 0800E934 beq (equal / zero); 0800E93E beq (equal / zero); 0800E948 b; 0800E994 bne (not equal / non-zero); 0800E9B4 beq (equal / zero); 0800E9BE b; 0800E9C8 bne (not equal / non-zero); 0800E9E4 beq (equal / zero); falls in
    @ redraw the icon from 0x200080B1

    bl fn_0801A370                           @ 0800E9EE
    pop {r0, pc}                             @ 0800E9F2
ENDFUNC fn_0800E848
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800EA24 - test |value| >= threshold
@ Replaces : 0x0800EA24 FUN_0800EA24 (v2.05, 22 bytes)
@ In       : r0 = signed value, r1 = threshold (positive)
@ Out      : r0 = 1 if value >= threshold or value <= -threshold, else 0
@ Clobbers : r0, r2, r3
@ Context  : ISR-safe (pure)
@ RAM      : -
@ Spec     : used by fn_0800E848
@
@ -----------------------------------------------------------------------------
FUNC fn_0800EA24
    movs r2, r0                              @ 0800EA24
    movs r0, #0                              @ 0800EA26
    cmp r2, r1                               @ 0800EA28
    bge .L0800EA32                           @ 0800EA2A
    negs r3, r1                              @ 0800EA2C
    cmp r3, r2                               @ 0800EA2E
    blt .L0800EA36                           @ 0800EA30
.L0800EA32:                                @ reached from 0800EA2A bge (signed >=); falls in
    movs r3, #1                              @ 0800EA32
    movs r0, r3                              @ 0800EA34
.L0800EA36:                                @ reached from 0800EA30 blt (signed <); falls in
    uxtb r0, r0                              @ 0800EA36
    bx lr                                    @ 0800EA38
ENDFUNC fn_0800EA24
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_080153AC - end of the MEM view: restore the live display
@ Replaces : 0x080153AC FUN_080153AC (v2.05, 56 bytes)
@ In       : -
@ Out      : -
@ Context  : ISR-safe (stores bytes and calls fn_0800D718, which SET keeps ISR-safe; DESIGN.md 3.4); called from IRQ28 (sys_tim2_isr)
@ RAM      : writes 0x20007FE4 = 0, 0x2000805E = 1, 0x2000805D = 1, 0x20008060 = 1, 0x20008061 = 1, 0x20008062 = 1
@ Spec     : DESIGN.md 3.4, 3.5; analysis/lcd_map.md 4
@ Clobbers : r0, r1 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_080153AC
    push {r7, lr}                            @ 080153AC
    movs r0, #0                              @ 080153AE
    ldr r1, =v_20007FE4                      @ 080153B0 &MEM view active (recalled-record view)
    strb r0, [r1, #0]                        @ 080153B4
    @ fn_0800D718 selects the default setup item
    bl fn_0800D718                           @ 080153B6
    @ request a full redraw: bargraph, main value, annunciators, unit prefix, setup page

    movs r0, #1                              @ 080153BA
    ldr r1, =v_2000805E                      @ 080153BC &bargraph update request
    strb r0, [r1, #0]                        @ 080153C0
    movs r0, #1                              @ 080153C2
    ldr r1, =v_2000805D                      @ 080153C4 &new-result flag
    strb r0, [r1, #0]                        @ 080153C8
    movs r0, #1                              @ 080153CA
    ldr r1, =v_20008060                      @ 080153CC &annunciator redraw request
    strb r0, [r1, #0]                        @ 080153D0
    movs r0, #1                              @ 080153D2
    ldr r1, =v_20008061                      @ 080153D4 &unit-prefix redraw request
    strb r0, [r1, #0]                        @ 080153D8
    movs r0, #1                              @ 080153DA
    ldr r1, =v_20008062                      @ 080153DC &setup-page redraw request
    strb r0, [r1, #0]                        @ 080153E0
    pop {r0, pc}                             @ 080153E2
ENDFUNC fn_080153AC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08015934 - draw the held value while HOLD is active
@ Replaces : 0x08015934 FUN_08015934 (v2.05, 58 bytes)
@ In       : -
@ Out      : -
@ Context  : main only
@ RAM      : reads hold_active (0x2000804F), 0x20008046 (OL), 0x2000803F, meter_mode; the value comes from fn_0800E758(1) (FUNC)
@ Spec     : analysis/lcd_map.md 4.2 (HOLD)
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08015934
    push {r4, lr}                            @ 08015934
    @ only with HOLD active; r4 = fn_0800E758(1)
    ldr r0, =hold_active                     @ 08015936 &hold_active
    ldrb r0, [r0, #0]                        @ 08015938
    cmp r0, #0                               @ 0801593A branch if hold_active == 0
    beq .L0801596C                           @ 0801593C
    movs r0, #1                              @ 0801593E
    bl fn_0800E758                           @ 08015940
    movs r4, r0                              @ 08015944
    @ OL: draw " OFL " (fn_080199B4(0)); otherwise draw r4 with lcd_show_value_pos5_9 (r3 = 0, so the hold skip does not apply)

    ldr r0, =v_20008046                      @ 08015946 &overload (OL) flag
    ldrb r0, [r0, #0]                        @ 0801594A
    cmp r0, #0                               @ 0801594C branch if overload (OL) flag == 0
    beq .L08015958                           @ 0801594E
    movs r0, #0                              @ 08015950
    bl fn_080199B4                           @ 08015952
    b .L0801596C                             @ 08015956
.L08015958:                                @ reached from 0801594E beq (equal / zero)
    movs r3, #0                              @ 08015958
    movs r2, r4                              @ 0801595A
    ldr r0, =v_2000803F                      @ 0801595C &main decimal-point position
    ldrb r1, [r0, #0]                        @ 08015960
    ldr r0, =meter_mode                      @ 08015962 &meter_mode
    ldrb r0, [r0, #0]                        @ 08015966
    bl lcd_show_value_pos5_9                 @ 08015968
.L0801596C:                                @ reached from 0801593C beq (equal / zero); 08015956 b; falls in
    pop {r4, pc}                             @ 0801596C
ENDFUNC fn_08015934
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016D34 - display refresh, called once per main-loop pass
@ Replaces : 0x08016D34 FUN_08016D34 (v2.05, 212 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; skipped completely while the MEM view (0x20007FE4) is active
@ RAM      : reads/clears the request flags 0x2000805E (bargraph), 0x2000805D / 0x2000805F (main value), 0x20008060
@            (annunciators), 0x20008061 (unit prefix), 0x2000804C (mode annunciators), 0x20008063 (sub-display units),
@            0x20008062 (setup page), 0x2000805B (commit); page code 0x20008037 / 0x20000236
@ Spec     : analysis/autorange_and_scheduler.md 1 (loop step 3); analysis/lcd_map.md 4
@ Deviation: IMP-02 (production): ui_bootwin_gate applies the power-on window rules first (nothing is drawn while a key
@            combination screen is shown, the lamp test of the RANGE key is lit again and kept until the window closes, the
@            version "V-2.05" stays on the sub display while the window is open, a full redraw is requested when the window
@            or a combination ends);
@            IMP-06 (production): lcd_commit_retry at the end of the pass repeats a commit that was deferred because UDR
@            was set
@ Clobbers : r0, r1, r2, r3, r12 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08016D34
    push {r7, lr}                            @ 08016D34
    bl ui_bootwin_gate                      @ IMP-02: power-on window rules (r0 = 1: a key combination screen or the lamp test owns the
                                            @ display); first, so that the lamp test is lit again before any commit of this pass
    cmp r0, #0
    bne .L08016E06                          @ draw nothing in this pass (the deferred commit is still repeated at the end)
    @ MEM view active (0x20007FE4 != 0): nothing is refreshed
    ldr r0, =v_20007FE4                      @ 08016D36 &MEM view active (recalled-record view)
    ldrb r0, [r0, #0]                        @ 08016D3A
    cmp r0, #0                               @ 08016D3C branch if MEM view active (recalled-record view) != 0
    bne .L08016E06                           @ 08016D3E
    @ bargraph update requested: fn_08018B14
    ldr r0, =v_2000805E                      @ 08016D40 &bargraph update request
    ldrb r0, [r0, #0]                        @ 08016D44
    cmp r0, #0                               @ 08016D46 branch if bargraph update request == 0
    beq .L08016D4E                           @ 08016D48
    bl fn_08018B14                           @ 08016D4A
.L08016D4E:                                @ reached from 08016D48 beq (equal / zero); falls in
    @ new result (0x2000805D) or second request (0x2000805F): redraw the main value (fn_08016E08)
    ldr r0, =v_2000805D                      @ 08016D4E &new-result flag
    ldrb r0, [r0, #0]                        @ 08016D52
    ldr r1, =v_2000805F                      @ 08016D54 &display request (second)
    ldrb r1, [r1, #0]                        @ 08016D58
    orrs r0, r1                              @ 08016D5A
    uxtb r0, r0                              @ 08016D5C
    cmp r0, #0                               @ 08016D5E
    beq .L08016D66                           @ 08016D60
    bl fn_08016E08                           @ 08016D62
.L08016D66:                                @ reached from 08016D60 beq (equal / zero); falls in
    @ annunciator redraw requested (0x20008060): fn_08017222
    ldr r0, =v_20008060                      @ 08016D66 &annunciator redraw request
    ldrb r0, [r0, #0]                        @ 08016D6A
    cmp r0, #0                               @ 08016D6C branch if annunciator redraw request == 0
    beq .L08016D74                           @ 08016D6E
    bl fn_08017222                           @ 08016D70
.L08016D74:                                @ reached from 08016D6E beq (equal / zero); falls in
    @ unit-prefix redraw requested (0x20008061): fn_0801776E
    ldr r0, =v_20008061                      @ 08016D74 &unit-prefix redraw request
    ldrb r0, [r0, #0]                        @ 08016D78
    cmp r0, #0                               @ 08016D7A branch if unit-prefix redraw request == 0
    beq .L08016D82                           @ 08016D7C
    bl fn_0801776E                           @ 08016D7E
.L08016D82:                                @ reached from 08016D7C beq (equal / zero); falls in
    @ mode-annunciator refresh requested (0x2000804C): lcd_set_mode_annunciators(mode, range, 0x20008098, 0x20008099), commit request
    ldr r0, =v_2000804C                      @ 08016D82 &annunciator refresh request (VA modes)
    ldrb r0, [r0, #0]                        @ 08016D86
    cmp r0, #0                               @ 08016D88 branch if annunciator refresh request (VA modes) == 0
    beq .L08016DB0                           @ 08016D8A
    ldr r0, =v_20008099                      @ 08016D8C &LowZ AC/DC decided flag
    ldrb r3, [r0, #0]                        @ 08016D90
    ldr r0, =v_20008098                      @ 08016D92 &LowZ AC/DC state (0 = DC)
    ldrb r2, [r0, #0]                        @ 08016D96
    ldr r0, =meter_range                     @ 08016D98 &meter_range
    ldrb r1, [r0, #0]                        @ 08016D9C
    ldr r0, =meter_mode                      @ 08016D9E &meter_mode
    ldrb r0, [r0, #0]                        @ 08016DA2
    bl lcd_set_mode_annunciators             @ 08016DA4
    movs r0, #1                              @ 08016DA8
    ldr r1, =v_2000805B                      @ 08016DAA &LCD commit request
    strb r0, [r1, #0]                        @ 08016DAE
.L08016DB0:                                @ reached from 08016D8A beq (equal / zero); falls in
    ldr r0, =ui_skip_sub
    ldrb r0, [r0]
    cmp r0, #0
    bne .L08016DF0                          @ IMP-02: the window shows the version on the sub display; keep it, skip the sub-display blocks
    @ sub-display: redraw the units when the page code (0x20008037) differs from the last drawn one (0x20000236) or 0x20008063 is set (fn_0801A440)
    ldr r0, =v_20000236                      @ 08016DB0 &last drawn sub-display page code
    ldrb r0, [r0, #0]                        @ 08016DB4
    ldr r1, =v_20008037                      @ 08016DB6 &setup / sub-display page code
    ldrb r1, [r1, #0]                        @ 08016DBA
    cmp r0, r1                               @ 08016DBC
    bne .L08016DCA                           @ 08016DBE
    ldr r0, =v_20008063                      @ 08016DC0 &sub-display refresh request
    ldrb r0, [r0, #0]                        @ 08016DC4
    cmp r0, #0                               @ 08016DC6 branch if sub-display refresh request == 0
    beq .L08016DE2                           @ 08016DC8
.L08016DCA:                                @ reached from 08016DBE bne (not equal / non-zero); falls in
    ldr r0, =v_20008037                      @ 08016DCA &setup / sub-display page code
    ldrb r0, [r0, #0]                        @ 08016DCE
    ldr r1, =v_20000236                      @ 08016DD0 &last drawn sub-display page code
    strb r0, [r1, #0]                        @ 08016DD4
    movs r0, #0                              @ 08016DD6
    ldr r1, =v_20008063                      @ 08016DD8 &sub-display refresh request
    strb r0, [r1, #0]                        @ 08016DDC
    bl fn_0801A440                           @ 08016DDE
.L08016DE2:                                @ reached from 08016DC8 beq (equal / zero); falls in
    @ setup page redraw requested (0x20008062): fn_0801797C (SET)
    ldr r0, =v_20008062                      @ 08016DE2 &setup-page redraw request
    ldrb r0, [r0, #0]                        @ 08016DE6
    cmp r0, #0                               @ 08016DE8 branch if setup-page redraw request == 0
    beq .L08016DF0                           @ 08016DEA
    bl fn_0801797C                           @ 08016DEC
.L08016DF0:                                @ reached from 08016DEA beq (equal / zero); falls in
    @ commit once if any drawer asked for it (0x2000805B)

    ldr r0, =v_2000805B                      @ 08016DF0 &LCD commit request
    ldrb r0, [r0, #0]                        @ 08016DF4
    cmp r0, #0                               @ 08016DF6 branch if LCD commit request == 0
    beq .L08016E06                           @ 08016DF8
    movs r0, #0                              @ 08016DFA
    ldr r1, =v_2000805B                      @ 08016DFC &LCD commit request
    strb r0, [r1, #0]                        @ 08016E00
    bl lcd_commit_shadow                     @ 08016E02
.L08016E06:                                @ reached from 08016D3E bne (not equal / non-zero); 08016DF8 beq (equal / zero); falls in
    @ IMP-06: repeat a commit that an earlier routine had to defer (UDR still set), after this pass has drawn: the shadow
    @ then holds the finished screen.  Repeated at the start of the pass, it committed the shadow half way through an apply
    @ (the old digits with the new decimal point and the sub decimal point cleared by fn_0800A560: "2300.0" / " 5000" for
    @ one frame at a range change).  Also while the MEM view is shown or a window screen owns the display.
    bl lcd_commit_retry
    pop {r0, pc}                             @ 08016E06
ENDFUNC fn_08016D34
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_08016E08 - draw the main value, or the message that replaces it
@ Replaces : 0x08016E08 FUN_08016E08 (v2.05, 650 bytes)
@ In       : -
@ Out      : -
@ Context  : main only; called by fn_08016D34 when 0x2000805D or 0x2000805F is set
@ RAM      : clears 0x2000805D and 0x2000805F; reads meter_mode, range_manual, minmax_state, 0x2000808A, 0x2000805A,
@            0x20008076, 0x200080BF, the calibration screen flags 0x2000808C..0x20008094, settle count 0x20000238,
@            0x2000805C, hold_active, hold_stage2, 0x20008046 (OL), rel_active, 0x2000803F, 0x20007D64; writes 0x20008046,
@            0x2000805A, the calibration flags 0x2000808D, 0x2000808F, 0x20008092, 0x20008094; ui_blank_req is read in both builds
@ Spec     : analysis/autorange_and_scheduler.md 2.4 (blank rule), analysis/lcd_map.md 2
@ Deviation: OF-30 (both builds), OF-32, IMP-01 rule P5 (production only; only OF-30 writes the byte in the baseline):
@            when ui_blank_req is non-zero the main digits show spaces (1) or dashes (2) instead of the value; the request is placed after the calibration screens, the jack warning and
@            the VA no-value screen, and before the v2.05 blank rule, so those keep their priority
@            IMP-45: while the SETUP page HUnt (item 41) is selected, ui_hunt_draw draws its value on the main digits and nothing else
@            is drawn; the test sits right after the calibration screens, before the ui_blank_req rule
@ Clobbers : r0, r1, r2, r3 (v2.05 regeffects.txt)
@ -----------------------------------------------------------------------------
FUNC fn_08016E08
    push {r3, r4, r5, lr}                    @ 08016E08
    @ this call serves the pending request: clear 0x2000805D and 0x2000805F
    movs r0, #0                              @ 08016E0A
    ldr r1, =v_2000805D                      @ 08016E0C &new-result flag
    strb r0, [r1, #0]                        @ 08016E10
    movs r0, #0                              @ 08016E12
    ldr r1, =v_2000805F                      @ 08016E14 &display request (second)
    strb r0, [r1, #0]                        @ 08016E18
    bl ui_stats_tick                         @ IMP-14: keep the statistics page current (new count, MIN/MAX ended)
    bl lt_tick                               @ IMP-20: limit test verdict, end on a mode change, pages Lo / HI / verdict
    @ OHM (mode 9) in auto range, outside calibration, MIN/MAX off: the first updates after a range change are skipped (counter 0x2000805A set by the apply)
    ldr r0, =meter_mode                      @ 08016E1A &meter_mode
    ldrb r0, [r0, #0]                        @ 08016E1E
    cmp r0, #9                               @ 08016E20 branch if mode != 9 (9 = OHM)
    bne .L08016E5C                           @ 08016E22
    ldr r0, =range_manual                    @ 08016E24 &range_manual
    ldrb r0, [r0, #0]                        @ 08016E28
    ldr r1, =v_2000808A                      @ 08016E2A &calibration mode flag
    ldrb r1, [r1, #0]                        @ 08016E2E
    orrs r0, r1                              @ 08016E30
    uxtb r0, r0                              @ 08016E32
    cmp r0, #0                               @ 08016E34
    bne .L08016E5C                           @ 08016E36
    ldr r0, =minmax_state                    @ 08016E38 &minmax_state
    ldrb r0, [r0, #0]                        @ 08016E3C
    cmp r0, #0                               @ 08016E3E branch if minmax_state != 0
    bne .L08016E5C                           @ 08016E40
    ldr r0, =v_2000805A                      @ 08016E42 &OHM display skip counter
    ldrb r0, [r0, #0]                        @ 08016E46
    cmp r0, #0                               @ 08016E48 branch if OHM display skip counter == 0
    beq .L08016E5C                           @ 08016E4A
    ldr r0, =v_2000805A                      @ 08016E4C &OHM display skip counter
    ldrb r0, [r0, #0]                        @ 08016E50
    subs r0, r0, #1                          @ 08016E52
    ldr r1, =v_2000805A                      @ 08016E54 &OHM display skip counter
    strb r0, [r1, #0]                        @ 08016E58
    b .L08017090                             @ 08016E5A
.L08016E5C:                                @ reached from 08016E22 bne (not equal / non-zero); 08016E36 bne (not equal / non-zero); 08016E40 bne (not equal / non-zero); 08016E4A beq (equal / zero)
    @ jack warning (0x20008076): draw " LEAD" (fn_08019A74) and clear OL
    ldr r0, =v_20008076                      @ 08016E5C &jack warning flag
    ldrb r0, [r0, #0]                        @ 08016E60
    cmp r0, #0                               @ 08016E62 branch if jack warning flag == 0
    beq .L08016E76                           @ 08016E64
    movs r0, #0                              @ 08016E66
    bl fn_08019A74                           @ 08016E68
    movs r0, #0                              @ 08016E6C
    ldr r1, =v_20008046                      @ 08016E6E &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016E72
    b .L08017090                             @ 08016E74
.L08016E76:                                @ reached from 08016E64 beq (equal / zero)
    @ VA modes 13, 14, 15, 22, 23, 24 with 0x200080BF: draw "-----" (fn_08019A86)
    ldr r0, =meter_mode                      @ 08016E76 &meter_mode
    ldrb r0, [r0, #0]                        @ 08016E7A
    cmp r0, #13                              @ 08016E7C branch if mode == 13 (13 = uVA)
    beq .L08016EB2                           @ 08016E7E
    ldr r0, =meter_mode                      @ 08016E80 &meter_mode
    ldrb r0, [r0, #0]                        @ 08016E84
    cmp r0, #14                              @ 08016E86 branch if mode == 14 (14 = mVA)
    beq .L08016EB2                           @ 08016E88
    ldr r0, =meter_mode                      @ 08016E8A &meter_mode
    ldrb r0, [r0, #0]                        @ 08016E8E
    cmp r0, #15                              @ 08016E90 branch if mode == 15 (15 = VA)
    beq .L08016EB2                           @ 08016E92
    ldr r0, =meter_mode                      @ 08016E94 &meter_mode
    ldrb r0, [r0, #0]                        @ 08016E98
    cmp r0, #22                              @ 08016E9A branch if mode == 22 (22 = DCuVA)
    beq .L08016EB2                           @ 08016E9C
    ldr r0, =meter_mode                      @ 08016E9E &meter_mode
    ldrb r0, [r0, #0]                        @ 08016EA2
    cmp r0, #23                              @ 08016EA4 branch if mode == 23 (23 = DCmVA)
    beq .L08016EB2                           @ 08016EA6
    ldr r0, =meter_mode                      @ 08016EA8 &meter_mode
    ldrb r0, [r0, #0]                        @ 08016EAC
    cmp r0, #24                              @ 08016EAE branch if mode != 24 (24 = DCVA)
    bne .L08016EC4                           @ 08016EB0
.L08016EB2:                                @ reached from 08016E7E beq (equal / zero); 08016E88 beq (equal / zero); 08016E92 beq (equal / zero); 08016E9C beq (equal / zero); 08016EA6 beq (equal / zero); falls in
    ldr r0, =v_200080BF                      @ 08016EB2 &VA no-value flag (shows dashes)
    ldrb r0, [r0, #0]                        @ 08016EB6
    cmp r0, #0                               @ 08016EB8 branch if VA no-value flag (shows dashes) == 0
    beq .L08016EC4                           @ 08016EBA
    movs r0, #0                              @ 08016EBC
    bl fn_08019A86                           @ 08016EBE
    b .L08017090                             @ 08016EC2
.L08016EC4:                                @ reached from 08016EB0 bne (not equal / non-zero); 08016EBA beq (equal / zero)
    @ calibration screens in priority order: flag 0x2000808C -> step text 0 (fn_08019698), 0x2000808D (cleared) -> text 0 (fn_08019738),
    @ 0x2000808E -> step text 1, 0x20008090 -> step text 4, 0x2000808F (cleared) -> text 1, 0x20008091 -> step text 2,
    @ 0x20008092 (cleared) -> text 2, 0x20008093 -> step text 3, 0x20008094 (cleared) -> text 3; each also clears OL (0x20008046)
    ldr r0, =v_2000808C                      @ 08016EC4 &calibration screen request (fn_08019698 arg 0)
    ldrb r0, [r0, #0]                        @ 08016EC8
    cmp r0, #0                               @ 08016ECA branch if calibration screen request (fn_08019698 arg 0) == 0
    beq .L08016EDE                           @ 08016ECC
    movs r0, #0                              @ 08016ECE
    ldr r1, =v_20008046                      @ 08016ED0 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016ED4
    movs r0, #0                              @ 08016ED6
    bl fn_08019698                           @ 08016ED8
    b .L08017090                             @ 08016EDC
.L08016EDE:                                @ reached from 08016ECC beq (equal / zero)
    ldr r0, =v_2000808D                      @ 08016EDE &calibration screen request (fn_08019738 arg 0)
    ldrb r0, [r0, #0]                        @ 08016EE2
    cmp r0, #0                               @ 08016EE4 branch if calibration screen request (fn_08019738 arg 0) == 0
    beq .L08016F00                           @ 08016EE6
    movs r0, #0                              @ 08016EE8
    ldr r1, =v_2000808D                      @ 08016EEA &calibration screen request (fn_08019738 arg 0)
    strb r0, [r1, #0]                        @ 08016EEE
    movs r0, #0                              @ 08016EF0
    ldr r1, =v_20008046                      @ 08016EF2 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016EF6
    movs r0, #0                              @ 08016EF8
    bl fn_08019738                           @ 08016EFA
    b .L08017090                             @ 08016EFE
.L08016F00:                                @ reached from 08016EE6 beq (equal / zero)
    ldr r0, =v_2000808E                      @ 08016F00 &calibration screen request (fn_08019698 arg 1)
    ldrb r0, [r0, #0]                        @ 08016F04
    cmp r0, #0                               @ 08016F06 branch if calibration screen request (fn_08019698 arg 1) == 0
    beq .L08016F1A                           @ 08016F08
    movs r0, #0                              @ 08016F0A
    ldr r1, =v_20008046                      @ 08016F0C &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016F10
    movs r0, #1                              @ 08016F12
    bl fn_08019698                           @ 08016F14
    b .L08017090                             @ 08016F18
.L08016F1A:                                @ reached from 08016F08 beq (equal / zero)
    ldr r0, =v_20008090                      @ 08016F1A &calibration screen request (fn_08019698 arg 4)
    ldrb r0, [r0, #0]                        @ 08016F1E
    cmp r0, #0                               @ 08016F20 branch if calibration screen request (fn_08019698 arg 4) == 0
    beq .L08016F34                           @ 08016F22
    movs r0, #0                              @ 08016F24
    ldr r1, =v_20008046                      @ 08016F26 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016F2A
    movs r0, #4                              @ 08016F2C
    bl fn_08019698                           @ 08016F2E
    b .L08017090                             @ 08016F32
.L08016F34:                                @ reached from 08016F22 beq (equal / zero)
    ldr r0, =v_2000808F                      @ 08016F34 &calibration screen request (fn_08019738 arg 1)
    ldrb r0, [r0, #0]                        @ 08016F38
    cmp r0, #0                               @ 08016F3A branch if calibration screen request (fn_08019738 arg 1) == 0
    beq .L08016F56                           @ 08016F3C
    movs r0, #0                              @ 08016F3E
    ldr r1, =v_2000808F                      @ 08016F40 &calibration screen request (fn_08019738 arg 1)
    strb r0, [r1, #0]                        @ 08016F44
    movs r0, #0                              @ 08016F46
    ldr r1, =v_20008046                      @ 08016F48 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016F4C
    movs r0, #1                              @ 08016F4E
    bl fn_08019738                           @ 08016F50
    b .L08017090                             @ 08016F54
.L08016F56:                                @ reached from 08016F3C beq (equal / zero)
    ldr r0, =v_20008091                      @ 08016F56 &calibration screen request (fn_08019698 arg 2)
    ldrb r0, [r0, #0]                        @ 08016F5A
    cmp r0, #0                               @ 08016F5C branch if calibration screen request (fn_08019698 arg 2) == 0
    beq .L08016F70                           @ 08016F5E
    movs r0, #0                              @ 08016F60
    ldr r1, =v_20008046                      @ 08016F62 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016F66
    movs r0, #2                              @ 08016F68
    bl fn_08019698                           @ 08016F6A
    b .L08017090                             @ 08016F6E
.L08016F70:                                @ reached from 08016F5E beq (equal / zero)
    ldr r0, =v_20008092                      @ 08016F70 &calibration screen request (fn_08019738 arg 2)
    ldrb r0, [r0, #0]                        @ 08016F74
    cmp r0, #0                               @ 08016F76 branch if calibration screen request (fn_08019738 arg 2) == 0
    beq .L08016F92                           @ 08016F78
    movs r0, #0                              @ 08016F7A
    ldr r1, =v_20008092                      @ 08016F7C &calibration screen request (fn_08019738 arg 2)
    strb r0, [r1, #0]                        @ 08016F80
    movs r0, #0                              @ 08016F82
    ldr r1, =v_20008046                      @ 08016F84 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016F88
    movs r0, #2                              @ 08016F8A
    bl fn_08019738                           @ 08016F8C
    b .L08017090                             @ 08016F90
.L08016F92:                                @ reached from 08016F78 beq (equal / zero)
    ldr r0, =v_20008093                      @ 08016F92 &calibration screen request (fn_08019698 arg 3)
    ldrb r0, [r0, #0]                        @ 08016F96
    cmp r0, #0                               @ 08016F98 branch if calibration screen request (fn_08019698 arg 3) == 0
    beq .L08016FAC                           @ 08016F9A
    movs r0, #0                              @ 08016F9C
    ldr r1, =v_20008046                      @ 08016F9E &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016FA2
    movs r0, #3                              @ 08016FA4
    bl fn_08019698                           @ 08016FA6
    b .L08017090                             @ 08016FAA
.L08016FAC:                                @ reached from 08016F9A beq (equal / zero)
    ldr r0, =v_20008094                      @ 08016FAC &calibration screen request (fn_08019738 arg 3)
    ldrb r0, [r0, #0]                        @ 08016FB0
    cmp r0, #0                               @ 08016FB2 branch if calibration screen request (fn_08019738 arg 3) == 0
    beq .L08016FCE                           @ 08016FB4
    movs r0, #0                              @ 08016FB6
    ldr r1, =v_20008094                      @ 08016FB8 &calibration screen request (fn_08019738 arg 3)
    strb r0, [r1, #0]                        @ 08016FBC
    movs r0, #0                              @ 08016FBE
    ldr r1, =v_20008046                      @ 08016FC0 &overload (OL) flag
    strb r0, [r1, #0]                        @ 08016FC4
    movs r0, #3                              @ 08016FC6
    bl fn_08019738                           @ 08016FC8
    b .L08017090                             @ 08016FCC
.L08016FCE:                                @ reached from 08016FB4 beq (equal / zero)
    bl ui_hunt_view
    cbz r0, .Lrf_no_hunt                    @ IMP-45: not the page HUnt
    bl ui_hunt_draw                         @ IMP-45: its value ("   on" / "  oFF") on the main digits, before every blank rule
    b .L08017090
.Lrf_no_hunt:
    ldr r0, =ui_blank_req                   @ request from the measurement modules (OF-30 both builds; OF-32, IMP-01 P5 production)
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lub_none                           @ 0: draw the value as v2.05 does
    bl ui_blank_draw                        @ 1: spaces, 2: dashes, 3: keep; auto-hold stage 2 keeps the old digits; clears OL
    b .L08017090                            @ done with this update (same exit as the v2.05 blank branch 0x08017004)
.Lub_none:
    @ v2.05 blank rule: settle count (0x20000238) or blank flag (0x2000805C) non-zero outside mode 0: spaces (fn_08019A98) unless auto-hold stage 2, OL cleared
    ldr r0, =v_20000238                      @ 08016FCE &settle count
    ldrb r0, [r0, #0]                        @ 08016FD2
    cmp r0, #0                               @ 08016FD4 branch if settle count != 0
    bne .L08016FE2                           @ 08016FD6
    ldr r0, =v_2000805C                      @ 08016FD8 &display blank request
    ldrb r0, [r0, #0]                        @ 08016FDC
    cmp r0, #0                               @ 08016FDE branch if display blank request == 0
    beq .L08017006                           @ 08016FE0
.L08016FE2:                                @ reached from 08016FD6 bne (not equal / non-zero); falls in
    ldr r0, =meter_mode                      @ 08016FE2 &meter_mode
    ldrb r0, [r0, #0]                        @ 08016FE6
    cmp r0, #0                               @ 08016FE8 branch if mode == 0 (0 = LowZ)
    beq .L08017006                           @ 08016FEA
    ldr r0, =hold_stage2                     @ 08016FEC &hold_stage2
    ldrb r0, [r0, #0]                        @ 08016FF0
    cmp r0, #0                               @ 08016FF2 branch if hold_stage2 != 0
    bne .L08016FFC                           @ 08016FF4
    movs r0, #0                              @ 08016FF6
    bl fn_08019A98                           @ 08016FF8
.L08016FFC:                                @ reached from 08016FF4 bne (not equal / non-zero); falls in
    movs r0, #0                              @ 08016FFC
    ldr r1, =v_20008046                      @ 08016FFE &overload (OL) flag
    strb r0, [r1, #0]                        @ 08017002
    b .L08017090                             @ 08017004
.L08017006:                                @ reached from 08016FE0 beq (equal / zero); 08016FEA beq (equal / zero)
    @ no blank: with hold active (or OL, which draws the overload text) the value / OFL path below is taken
    ldr r0, =hold_active                     @ 08017006 &hold_active
    ldrb r0, [r0, #0]                        @ 0801700A
    ldr r1, =v_20008046                      @ 0801700C &overload (OL) flag
    ldrb r1, [r1, #0]                        @ 08017010
    eors.w r1, r1, #1                        @ 08017012
    orrs r0, r1                              @ 08017016
    uxtb r0, r0                              @ 08017018
    cmp r0, #0                               @ 0801701A
    bne .L0801702E                           @ 0801701C
    bl ui_mmt_view
    cbz r0, .Lrf_ol_v205                    @ IMP-21: not the page tHI / tLo while MIN/MAX is on
    movs r0, #0
    bl ui_mmt_draw                          @ IMP-21: the time of the extreme in place of "OFL"
    b .Lrf_ol_clear
.Lrf_ol_v205:
    movs r0, #0                              @ 0801701E
    bl fn_080199B4                           @ 08017020
.Lrf_ol_clear:
    movs r0, #0                              @ 08017024
    ldr r1, =v_20008046                      @ 08017026 &overload (OL) flag
    strb r0, [r1, #0]                        @ 0801702A
    b .L08017090                             @ 0801702C
.L0801702E:                                @ reached from 0801701C bne (not equal / non-zero)
    bl ui_stats_view
    cbz r0, .Lrf_no_sd                      @ IMP-14: not the page Sd while MIN/MAX is on
    bl ui_stats_draw                        @ IMP-14: the standard deviation on the main digits
    b .L08017090
.Lrf_no_sd:
    bl ui_mmt_view
    cbz r0, .Lrf_no_mmt                     @ IMP-21: not the page tHI / tLo while MIN/MAX is on
    movs r0, #1
    bl ui_mmt_draw                          @ IMP-21: the time of the extreme on the main digits
    b .L08017090
.Lrf_no_mmt:
    bl ui_relpct_view
    cbz r0, .Lrf_no_pct                     @ IMP-11: REL in percent off or not shown: the v2.05 draw of D
    bl ui_relpct_draw                       @ IMP-11: D as percent of the REL base
    b .L08017090
.Lrf_no_pct:
    bl ui_loop_view
    cbz r0, .Lrf_no_loop                    @ IMP-24: DCmA loop percent view off or not shown
    bl ui_loop_draw                         @ IMP-24: the current as percent of the 4..20 / 0..20 mA span
    b .L08017090
.Lrf_no_loop:
    bl ui_rtd_view
    cbz r0, .Lrf_no_rtd                     @ IMP-25: OHM RTD temperature view off or not shown
    bl ui_rtd_draw                          @ IMP-25: the resistance as the temperature of a Pt100 / Pt1000
    b .L08017090
.Lrf_no_rtd:
    @ r4 = displayed reading D (0x20007D64); inside -99999..99999 it is drawn directly
    ldr r0, =v_20007D64                      @ 0801702E &displayed reading D (signed counts)
    ldr r0, [r0, #0]                         @ 08017032
    movs r4, r0                              @ 08017034
    ldr r0, =0x000186A0                      @ 08017036
    cmp r4, r0                               @ 0801703A
    bge .L08017046                           @ 0801703C
    ldr r0, =0xFFFE7961                      @ 0801703E
    cmp r4, r0                               @ 08017042
    bge .L0801707C                           @ 08017044
.L08017046:                                @ reached from 0801703C bge (signed >=); falls in
    @ outside +-99999: only with REL active, D / 10 is drawn with one decimal fewer and 0x20007D70 = D; otherwise nothing is drawn
    ldr r0, =rel_active                      @ 08017046 &rel_active
    ldrb r0, [r0, #0]                        @ 0801704A
    cmp r0, #0                               @ 0801704C branch if rel_active == 0
    beq .L0801707A                           @ 0801704E
    ldr r0, =v_2000803F                      @ 08017050 &main decimal-point position
    ldrb r5, [r0, #0]                        @ 08017054
    uxtb r5, r5                              @ 08017056
    cmp r5, #0                               @ 08017058 branch if main decimal-point position == 0
    beq .L0801705E                           @ 0801705A
    subs r5, r5, #1                          @ 0801705C
.L0801705E:                                @ reached from 0801705A beq (equal / zero); falls in
    movs r3, #1                              @ 0801705E
    movs r0, #10                             @ 08017060
    sdiv r2, r4, r0                          @ 08017062
    movs r1, r5                              @ 08017066
    uxtb r1, r1                              @ 08017068
    ldr r0, =meter_mode                      @ 0801706A &meter_mode
    ldrb r0, [r0, #0]                        @ 0801706E
    bl lcd_show_value_pos5_9                 @ 08017070
    ldr r0, =v_20007D70                      @ 08017074 &last drawn main value
    str r4, [r0, #0]                         @ 08017078
.L0801707A:                                @ reached from 0801704E beq (equal / zero); falls in
    b .L08017090                             @ 0801707A
.L0801707C:                                @ reached from 08017044 bge (signed >=)
    @ D inside the 5-digit range: lcd_show_value_pos5_9(mode, decimal point, D, 1)

    movs r3, #1                              @ 0801707C
    movs r2, r4                              @ 0801707E
    ldr r0, =v_2000803F                      @ 08017080 &main decimal-point position
    ldrb r1, [r0, #0]                        @ 08017084
    ldr r0, =meter_mode                      @ 08017086 &meter_mode
    ldrb r0, [r0, #0]                        @ 0801708A
    bl lcd_show_value_pos5_9                 @ 0801708C
.L08017090:                                @ reached from 08016E5A b; 08016E74 b; 08016EC2 b; 08016EDC b; 08016EFE b; 08016F18 b; 08016F32 b; 08016F54 b; 08016F6E b; 08016F90 b; 08016FAA b; 08016FCC b; 08017004 b; 0801702C b; 0801707A b; falls in
    pop {r0, r4, r5, pc}                     @ 08017090
ENDFUNC fn_08016E08
    .ltorg

@ -----------------------------------------------------------------------------
@ ui_value_valid - do the main digits show a reading?
@ Replaces : nothing (new; request W9_to_W3.md item 1, OF-34); the blank rule is that of fn_08016E08 0x08016FCE..0x08016FF4
@ In       : -
@ Out      : r0 = 1 while the main digits show a reading, 0 while they are blank or show dashes
@ Clobbers : r0
@ Context  : main only
@ RAM      : reads ui_blank_req, meter_mode, settle count 0x20000238, blank flag 0x2000805C
@ Spec     : analysis/autorange_and_scheduler.md 2.4 (blank rule), 5.2 P5, P7; OF-30, OF-32, OF-33, OF-34
@ Deviation: OF-34 (used by the BLE frame builder), OF-30 (both builds) / OF-32 / IMP-01 (production only) in the ui_blank_req term
@ -----------------------------------------------------------------------------
FUNC ui_value_valid
    ldr r0, =ui_blank_req
    ldrb r0, [r0]
    cbnz r0, .Luv_blank                     @ spaces or dashes requested by the measurement modules
    ldr r0, =meter_mode
    ldrb r0, [r0]
    cbz r0, .Luv_valid                      @ mode 0 (LowZ) is exempt from the v2.05 blank rule (0x08016FE2..0x08016FEA)
    ldr r0, =v_20000238
    ldrb r0, [r0]
    cbnz r0, .Luv_blank                     @ settle count running: v2.05 draws spaces
    ldr r0, =v_2000805C
    ldrb r0, [r0]
    cbnz r0, .Luv_blank                     @ blank flag set: v2.05 draws spaces
.Luv_valid:
    movs r0, #1
    bx lr
.Luv_blank:
    movs r0, #0
    bx lr
    .ltorg
ENDFUNC ui_value_valid

@ -----------------------------------------------------------------------------
@ ui_bootwin_gate - production power-on window: decide what the display refresh may draw
@ Replaces : nothing (new, IMP-02, DESIGN.md 7.1; request W7_to_W3.md item 1)
@ In       : -
@ Out      : r0 = 1 skip the whole refresh (a key combination screen or the all-segments test owns the display), 0 refresh
@            (ui_skip_sub tells whether the sub-display blocks are skipped)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only; called at the start of fn_08016D34
@ RAM      : reads bootwin_active (CAL), 0x200080CD, 0x200080CE (key sequence states), ui_lamp_test; read-modify-writes
@            ui_bw_state, ui_skip_sub, ui_lamp_test (cleared by a combination and when the window is closed); lcd_shadow and
@            0x2000805B through fn_0801A89C while the lamp test is on; through ui_version_sub and ui_request_redraw: lcd_shadow, 0x2000805B, 0x2000805D, 0x2000805E,
@            0x20008060..0x20008063; first pass: main digits blanked (fn_08019A98, 0x20008045) and the main decimal point of
@            0x2000803F drawn (fn_0801717E); while the version is shown the sub decimal points of lcd_shadow word 0 are checked
@            and the version drawn again when an apply has cleared them
@ Spec     : DESIGN.md 7.1, analysis/autorange_and_scheduler.md 6 item 3: while the window is open the reading is shown in
@            the main digits and the version on the secondary display; a window key that starts a combination stops the
@            measurement display; the all-segments test of the RANGE key (DESIGN.md 7.1, analysis/keys_setup.md 3) stays until the
@            window closes
@ Deviation: IMP-02
@ -----------------------------------------------------------------------------
LFUNC ui_bootwin_gate
    push {r4, lr}
    movs r4, #0
    ldr r0, =ui_skip_sub
    strb r4, [r0]                           @ default: refresh everything
    ldr r0, =bootwin_active
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lbg_closed                         @ window closed (or not yet started): normal refresh
    ldr r0, =v_200080CD
    ldrb r1, [r0]                           @ key sequence state A
    ldr r0, =v_200080CE
    ldrb r2, [r0]                           @ key sequence state B
    orrs r1, r1, r2
    bne .Lbg_combo                          @ a combination is in progress: its screens own the display
    ldr r0, =ui_lamp_test
    ldrb r0, [r0]                           @ 1 = all segments lit by the RANGE key (set by fn_0801A89C)
    cbnz r0, .Lbg_lamp
    ldr r0, =ui_bw_state
    ldrb r1, [r0]
    cmp r1, #1
    beq .Lbg_keepver                        @ version already on the sub display
    cmp r1, #2
    bne .Lbg_first
    bl ui_request_redraw                    @ back from a combination screen: redraw the live display
    b .Lbg_showver
.Lbg_first:
    @ first pass of the window (state 0): the splash "V-2.05" is still on the main digits, which now belong to the
    @ reading: blank them and draw the decimal point of the applied range (0x2000803F; fn_080171FA did not draw it
    @ while the splash owned the main display), as an apply shows it before the first value
    movs r0, #0
    bl fn_08019A98                          @ five spaces on the main digits, main minus sign off
    ldr r0, =v_2000803F
    ldrb r0, [r0]
    bl fn_0801717E                          @ main decimal point of the applied range (0 = none)
.Lbg_showver:
    ldr r0, =ui_bw_state
    movs r1, #1
    strb r1, [r0]                           @ window open, version shown
    bl ui_version_sub                       @ "V-2.05" on the sub display (sets the commit request)
    b .Lbg_skipsub
.Lbg_keepver:
    @ an apply in the window (fn_0800A560 through meter_apply_mode_range) clears the sub decimal points in the shadow while
    @ the sub-display blocks are skipped; the version is drawn again before anything commits that shadow
    ldr r0, =lcd_shadow
    ldr r0, [r0]                            @ shadow word 0: sub decimal points at bits 21, 23, 25, 27 (fn_08017FB4)
    and r0, r0, #0x0AA00000
    cmp r0, #0x00800000                     @ only sub point 2 ("V-2.05") set: the version is intact
    beq .Lbg_skipsub
    bl ui_version_sub                       @ draw the version again (text, point, unit group; commit request)
.Lbg_skipsub:
    movs r1, #1
    ldr r0, =ui_skip_sub
    strb r1, [r0]                           @ keep the sub display as it is during this pass
    movs r0, #0                             @ refresh the rest
    pop {r4, pc}
.Lbg_combo:
    ldr r0, =ui_lamp_test
    strb r4, [r0]                           @ a combination screen replaces the lamp test (v2.05 draws over it too; r4 = 0)
    ldr r0, =ui_bw_state
    ldrb r1, [r0]
    movs r2, #2
    strb r2, [r0]                           @ window open, combination on the display
    cmp r1, #1
    bne .Lbg_draw_nothing                   @ the version was not on the sub display: nothing to remove
    bl ui_sub_clear                         @ first pass of a combination: the v2.05 combination screen has a blank sub display
.Lbg_draw_nothing:
    movs r0, #1                             @ draw nothing
    pop {r4, pc}
.Lbg_lamp:
    bl fn_0801A89C                          @ light every segment again: the mode apply of the window (fn_080171FA through
                                            @ meter_apply_mode_range) rewrites the decimal point bits of the shadow and v2.05
                                            @ does not apply the mode before the window ends
    bl lcd_commit_shadow                    @ written only if the shadow differs from the last committed copy
    ldr r0, =ui_bw_state
    movs r1, #2
    strb r1, [r0]                           @ window open, lamp test on the display (the close requests a full redraw)
    movs r0, #1                             @ draw nothing else
    pop {r4, pc}
.Lbg_closed:
    ldr r0, =ui_lamp_test
    strb r4, [r0]                           @ the lamp test ends with the window (r4 = 0)
    ldr r0, =ui_bw_state
    ldrb r1, [r0]
    cbz r1, .Lbg_idle                       @ window was not open
    strb r4, [r0]                           @ window just closed: state 0 (r4 = 0)
    bl ui_request_redraw                    @ restore the whole live display (sub display page, units, annunciators, value)
.Lbg_idle:
    movs r0, #0
    pop {r4, pc}
    .ltorg
ENDFUNC ui_bootwin_gate

@ -----------------------------------------------------------------------------
@ ui_bootwin_main_busy - does a power-on window screen own the main display
@ Replaces : nothing (new, IMP-02)
@ In       : -
@ Out      : r0 = 1 while the window is open and the main display shows a window screen: the splash before the first
@            pass of ui_bootwin_gate (ui_bw_state 0), a key-combination screen (ui_bw_state 2, or a sequence state
@            0x200080CD / 0x200080CE non-zero) or the all-segments test (ui_lamp_test); else 0
@ Clobbers : r0, r1, flags
@ Context  : main only; called by fn_080171FA
@ RAM      : reads bootwin_active (CAL), ui_bw_state, 0x200080CD, 0x200080CE, ui_lamp_test
@ Spec     : DESIGN.md 7.1
@ Deviation: IMP-02
@ -----------------------------------------------------------------------------
FUNC ui_bootwin_main_busy
    ldr r0, =bootwin_active
    ldrb r0, [r0]
    cbz r0, 9f                              @ window closed: r0 = 0
    ldr r0, =v_200080CD
    ldrb r0, [r0]
    ldr r1, =v_200080CE
    ldrb r1, [r1]
    orrs r0, r0, r1
    bne 8f                                  @ a key combination is in progress
    ldr r0, =ui_lamp_test
    ldrb r0, [r0]
    cbnz r0, 8f                             @ all segments lit
    ldr r0, =ui_bw_state
    ldrb r0, [r0]
    cmp r0, #1
    bne 8f                                  @ splash (0) or combination screen (2)
    movs r0, #0                             @ the main digits show the reading
    bx lr
8:  movs r0, #1
9:  bx lr
    .ltorg
ENDFUNC ui_bootwin_main_busy

@ -----------------------------------------------------------------------------
@ ui_version_sub - draw the version ("F-0.91" production, config.inc) on the sub display
@ Replaces : nothing (new, IMP-02); the text and decimal point of v2.05's splash FUN_0801A854, which used the main digits
@ In       : -
@ Out      : -   (sets the commit request 0x2000805B)
@ Clobbers : r0-r3, r12, flags
@ Context  : main only; called by ui_bootwin_gate and by bootwin_start (CAL, at power-on in place of the splash, IMP-35)
@ RAM      : writes the text buffer 0x20007C30 and lcd_shadow (sub display digits, decimal point, unit group)
@ Spec     : DESIGN.md 7.1; analysis/lcd_map.md 2, 4.3
@ Deviation: IMP-02
@ -----------------------------------------------------------------------------
FUNC ui_version_sub
    push {r4, lr}
    bl fn_0801A760                          @ clear the sub-display unit group and the sub minus sign
    ldr r4, =v_20007C30                     @ text buffer
    movs r0, #FW_VER_C0                     @ version text of the build (config.inc): "V-205" / "F-091"
    strb r0, [r4, #0]
    movs r0, #FW_VER_C1
    strb r0, [r4, #1]
    movs r0, #FW_VER_C2
    strb r0, [r4, #2]
    movs r0, #FW_VER_C3
    strb r0, [r4, #3]
    movs r0, #FW_VER_C4
    strb r0, [r4, #4]
    movs r0, #1                             @ sub display (positions 0..4)
    movs r1, r4
    bl lcd_draw_5char
    movs r0, #2                             @ sub decimal point 2: right of the third character ("V-2.05" / "F-0.91")
    bl fn_08017FB4
    movs r0, #1
    ldr r1, =v_2000805B
    strb r0, [r1]                           @ commit request
    pop {r4, pc}
    .ltorg
ENDFUNC ui_version_sub

@ -----------------------------------------------------------------------------
@ ui_sub_clear - blank the sub display (digits, minus sign, decimal point, unit group) and commit
@ Replaces : nothing (new, IMP-02); removes the version of ui_version_sub when a window key starts a combination
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : lcd_shadow (sub display digits, minus, decimal point, unit group); the commit is made at once
@ Spec     : DESIGN.md 7.1 (the v2.05 combination screens leave the sub display blank)
@ Deviation: IMP-02
@ -----------------------------------------------------------------------------
LFUNC ui_sub_clear
    push {r4, lr}
    movs r0, #1                             @ sub display (positions 0..4)
    ldr r1, =v205_tab_080291B0              @ "     " (v2.05 0x080291B0)
    bl lcd_draw_5char
    movs r0, #0
    bl fn_08017FB4                          @ no sub decimal point
    bl fn_0801A760                          @ sub unit group and sub minus sign off
    bl lcd_commit_shadow                    @ made here because the refresh returns without drawing
    pop {r4, pc}
    .ltorg
ENDFUNC ui_sub_clear

@ -----------------------------------------------------------------------------
@ ui_request_redraw - request a full redraw of the live display
@ Replaces : nothing (new, IMP-02); the same requests as fn_080153AC plus the sub-display unit refresh 0x20008063
@ In       : -
@ Out      : -
@ Clobbers : r0, r1
@ Context  : main only
@ RAM      : writes 0x2000805E, 0x2000805D, 0x20008060, 0x20008061, 0x20008062, 0x20008063 = 1
@ Spec     : DESIGN.md 7.1 (the display is redrawn from the live state when the window or a combination screen ends)
@ Deviation: IMP-02
@ -----------------------------------------------------------------------------
LFUNC ui_request_redraw
    movs r0, #1
    ldr r1, =v_2000805E
    strb r0, [r1]                           @ bargraph
    ldr r1, =v_2000805D
    strb r0, [r1]                           @ main value
    ldr r1, =v_20008060
    strb r0, [r1]                           @ annunciators
    ldr r1, =v_20008061
    strb r0, [r1]                           @ unit prefix
    ldr r1, =v_20008062
    strb r0, [r1]                           @ setup page / sub display
    ldr r1, =v_20008063
    strb r0, [r1]                           @ sub-display units
    bx lr
    .ltorg
ENDFUNC ui_request_redraw
