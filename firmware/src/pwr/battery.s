@ =============================================================================
@ battery.s - PWR: battery voltage measurement and low-battery state
@
@ IMP-27 (production image only): the filtered value is scaled by the owner's battery trim (pwr_bat_trim, set/btrim.s).
@ Replaces adc_ch5_process 0x080134DA, FUN_080135B0 (20-value history with trimmed mean), FUN_0801368A (sort)
@ and FUN_08013728 (ADC code -> battery value by the table 0x08028C9C) (v2.05).
@ OF-52: the conversion follows the hardware divider (fn_08013728); the v2.05 table v205_tab_08028C9C (src/pwr/tables_v205.s,
@ generated) has no reader in the port.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .equ PWR_BAT_ADC_MIN,   0x03FC          @ clamp of the ADC code (v2.05 0x080134FA)
    .equ PWR_BAT_ADC_MAX,   0x0C30          @ (0x0801350C)
    .equ PWR_BAT_LOW_LIMIT, 41              @ value / 10 below this: low battery (0x0801353A cmp #0x29)
    .equ PWR_BAT_DEBOUNCE,  11              @ readings needed to change the low-battery symbol (0x08013586)
    .equ PWR_HIST_LEN,      20              @ history length (0x080135BE)
    .equ PWR_BAT_NUM,       1330            @ OF-52: B+ (0.01 V) = code x 1330 / 4095 = code x 3.3 / 4095 x (1M + 330k) / 330k x 100
    .equ PWR_BAT_DEN,       4095            @ 12-bit ADC full-scale code (VDDA = VREF+ = 3.300 V)

    .section .bss_port.pwr, "aw", %nobits
    .balign 2
@ pwr_bat_cv: the trimmed, filtered battery voltage in 0.01 V (owner PWR; read by set_btrim_draw)
    .global pwr_bat_cv
pwr_bat_cv:     .space 2

    .section .text.pwr.battery, "ax", %progbits

@ -----------------------------------------------------------------------------
@ adc_ch5_process - battery conversion, filtering, low-battery flag and symbol
@ Replaces : 0x080134DA adc_ch5_process (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (100 ms step, every second call of fn_0801349C)
@ RAM      : writes 0x20007FD2 (ADC code), 0x20007FBA (battery value / 10), 0x200080F9 (low battery),
@            0x20008062, 0x20007FDC (debounce), 0x2000803B (low-battery symbol state)
@ -----------------------------------------------------------------------------
FUNC adc_ch5_process
    push {r4, lr}
    movs r0, #1
    bl adc_select_channel_4_or_5            @ channel 5 (0x080134DE)
    ldr r1, =v_20007FD2
    strh r0, [r1]                           @ 0x080134E6
    bl fn_0801C97E                          @ ADC off (0x080134E8)
    ldr r0, =v_20007FD2
    ldrh r0, [r0]
    mov r4, r0                              @ r4 = code
    cmp r0, #PWR_BAT_ADC_MIN
    it lt                                   @ below the clamp (signed compare as v2.05 0x080134FE)
    movlt r4, #PWR_BAT_ADC_MIN              @ code < 0x3FC: clamp up
    cmp r0, #PWR_BAT_ADC_MAX
    it gt                                   @ above the clamp (0x08013510)
    movgt r4, #PWR_BAT_ADC_MAX              @ code > 0xC30: clamp down
    mov r0, r4
    bl fn_08013728                          @ code -> B+ in 0.01 V (0x0801351A; OF-52 hardware relation)
    bl fn_080135B0                          @ history and trimmed mean (0x08013522)
    bl pwr_bat_trim                         @ IMP-27: x (1000 + 2 t) / 1000, the owner's trim (set/btrim.s)
    movs r1, #10
    udiv r0, r0, r1                         @ 0x0801352A
    ldr r1, =v_20007FBA
    strh r0, [r1]
    uxth r0, r0
    movs r2, #0
    cmp r0, #PWR_BAT_LOW_LIMIT
    it lt                                   @ low battery (signed compare as v2.05 0x0801353C bge)
    movlt r2, #1                            @ value / 10 < 41: low battery
    ldr r1, =v_200080F9
    strb r2, [r1]                           @ 0x08013544 / 0x0801354E
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cmp r0, #1
    bne .Lac5_symbol
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                           @ setup page 1 shown: redraw request (0x08013560)
.Lac5_symbol:
    ldr r0, =v_200080F9
    ldrb r0, [r0]
    ldr r1, =v_2000803B
    ldrb r1, [r1]
    cmp r0, r1
    beq .Lac5_same
    ldr r1, =v_20007FDC
    ldrh r0, [r1]
    adds r0, r0, #1
    strh r0, [r1]                           @ 0x0801357E
    uxth r0, r0
    cmp r0, #PWR_BAT_DEBOUNCE
    blt .Lac5_done
    ldr r0, =v_200080F9
    ldrb r0, [r0]
    ldr r1, =v_2000803B
    strb r0, [r1]                           @ new symbol state (0x08013594)
    movs r0, #0
    ldr r1, =v_20007FDC
    strh r0, [r1]
    movs r0, #1
    bl fn_08019CF0                          @ low-battery symbol (LCD) (0x080135A0)
    b .Lac5_done
.Lac5_same:
    movs r0, #0
    ldr r1, =v_20007FDC
    strh r0, [r1]                           @ 0x080135AC
.Lac5_done:
    pop {r4, pc}
ENDFUNC adc_ch5_process

@ -----------------------------------------------------------------------------
@ fn_080135B0 - add a value to the 20-entry history and return the filtered value
@ Replaces : 0x080135B0 FUN_080135B0 (v2.05)
@ In       : r0 = new value
@ Out      : r0 = mean of all values while the history fills; with 20 values the mean of sorted entries
@            5..14 (the 5 largest and 5 smallest dropped)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ RAM      : 0x20007FBC (u16 fill count), history 0x200076F0 (20 words), sorted copy 0x20007740 (20 words)
@ -----------------------------------------------------------------------------
LFUNC fn_080135B0
    push {r4-r7, lr}
    sub sp, sp, #4
    mov r4, r0                              @ r4 = new value
    movs r6, #0                             @ r6 = sum
    ldr r5, =v_20007FBC                     @ r5 = address of the count
    ldr r7, =v_200076F0                     @ r7 = history
    ldrh r0, [r5]
    cmp r0, #PWR_HIST_LEN
    bne .L35b0_fill
    @ full: shift the history up by one, new value at index 0 (0x080135C2..0x080135FA)
    movs r1, #1                             @ r1 = i
.L35b0_shift:
    ldrh r0, [r5]
    cmp r1, r0
    bhs .L35b0_shifted
    subs r2, r0, #1
    subs r2, r2, r1
    ldr r3, [r7, r2, lsl #2]                @ H[n - 1 - i]
    subs r2, r0, r1
    str r3, [r7, r2, lsl #2]                @ -> H[n - i]
    adds r1, r1, #1
    b .L35b0_shift
.L35b0_shifted:
    str r4, [r7]                            @ H[0] = new value
    bl fn_0801368A                          @ sorted copy (0x080135FC)
    ldr r2, =v_20007740
    movs r1, #5                             @ r1 = i (0x08013600)
.L35b0_trim:
    ldrh r0, [r5]
    subs r0, r0, #5
    cmp r1, r0
    bhs .L35b0_trim_done
    ldr r3, [r2, r1, lsl #2]
    adds r6, r6, r3
    adds r1, r1, #1
    b .L35b0_trim
.L35b0_trim_done:
    ldrh r0, [r5]
    subs r0, r0, #10
    udiv r0, r6, r0                         @ 0x08013626
    b .L35b0_count
.L35b0_fill:
    @ filling: H[n] = value, mean of H[0..n] (0x0801362E..0x08013664)
    str r4, [r7, r0, lsl #2]
    movs r1, #0
.L35b0_sum:
    ldrh r0, [r5]
    cmp r0, r1
    blo .L35b0_sum_done                     @ loop while i <= n
    ldr r3, [r7, r1, lsl #2]
    adds r6, r6, r3
    adds r1, r1, #1
    b .L35b0_sum
.L35b0_sum_done:
    ldrh r0, [r5]
    adds r0, r0, #1
    udiv r0, r6, r0                         @ 0x08013660
.L35b0_count:
    ldrh r1, [r5]
    adds r1, r1, #1
    strh r1, [r5]                           @ count + 1 (0x08013672)
    uxth r1, r1
    cmp r1, #(PWR_HIST_LEN + 1)
    blt .L35b0_ret
    movs r1, #PWR_HIST_LEN
    strh r1, [r5]                           @ stays at 20 (0x08013684)
.L35b0_ret:
    add sp, sp, #4
    pop {r4-r7, pc}
ENDFUNC fn_080135B0

@ -----------------------------------------------------------------------------
@ fn_0801368A - sorted copy of the history, largest first
@ Replaces : 0x0801368A FUN_0801368A (v2.05): copy H to S, then 20 times take the largest S entry (the last of
@            equal ones), zero it in S and append it to a stack array; copy the array back to S
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ RAM      : reads 0x200076F0, writes 0x20007740
@ -----------------------------------------------------------------------------
LFUNC fn_0801368A
    push {r4, r5}
    sub sp, sp, #80                         @ 20-word array as v2.05 (0x0801368C)
    ldr r4, =v_200076F0
    ldr r5, =v_20007740
    movs r2, #0                             @ r2 = index of the largest (kept across rounds as v2.05)
    movs r3, #0
.L368a_copy:                                @ S = H (0x08013694..0x080136B0)
    ldr r12, [r4, r3, lsl #2]
    str r12, [r5, r3, lsl #2]
    adds r3, r3, #1
    cmp r3, #PWR_HIST_LEN
    blt .L368a_copy
    movs r1, #0                             @ r1 = round
.L368a_round:
    movs r0, #0                             @ r0 = largest so far
    movs r3, #0
.L368a_scan:
    ldr r12, [r5, r3, lsl #2]
    cmp r12, r0
    blo .L368a_next                         @ smaller: skip (equal entries replace, 0x080136D6 bcc)
    mov r0, r12
    mov r2, r3
.L368a_next:
    adds r3, r3, #1
    cmp r3, #PWR_HIST_LEN
    blt .L368a_scan
    movs r12, #0
    str r12, [r5, r2, lsl #2]               @ S[index] = 0 (0x080136F2)
    str r0, [sp, r1, lsl #2]                @ array[round] = largest (0x080136FA)
    adds r1, r1, #1
    cmp r1, #PWR_HIST_LEN
    blt .L368a_round
    movs r3, #0
.L368a_back:                                @ S = array (0x08013706..0x08013720)
    ldr r12, [sp, r3, lsl #2]
    str r12, [r5, r3, lsl #2]
    adds r3, r3, #1
    cmp r3, #PWR_HIST_LEN
    blt .L368a_back
    add sp, sp, #80
    pop {r4, r5}
    bx lr
ENDFUNC fn_0801368A

@ -----------------------------------------------------------------------------
@ fn_08013728 - battery voltage from the clamped ADC code (hardware divider relation, OF-52)
@ Replaces : 0x08013728 FUN_08013728 (v2.05)
@ In       : r0 = ADC code, 0x3FC..0xC30 (clamped by the caller)
@ Out      : r0 = B+ in 0.01 V = (code * 1330 + 2047) / 4095 (rounded to the nearest 0.01 V), 331..1013
@ Clobbers : r1, flags
@ Context  : main
@ Deviation: OF-52 (ORIGINAL_FIRMWARE_ISSUES.md; DESIGN.md 12.2): v2.05 interpolates the table 0x08028C9C (T[i] = 3120 -
@            140 i, value = 1050 - 50 i + 50 (code - T[i]) / 140), i.e. code / 280 - 0.643 V, which does not match the
@            hardware: B+ - R69 1M - PA5 - R70 330k - VSS (ratio 330/1330), ADC reference VDDA = 3.300 V (NJU7200U33)
@            (analysis/frontend_netlist.md sections 7 and 9).  B+ = code x 3.3 / 4095 / (330/1330) V
@            = code x 1330 / 4095 in 0.01 V (the 3.30 V and the 330 kOhm cancel).  The caller's low-battery limit stays
@            41 (4.1 V).  The v2.05 table stays in tables_v205.s (generated, compared with the image by the build check)
@            and has no reader in the port.
@            Range: code * 1330 <= 3120 * 1330 = 4 149 600, no overflow; udiv truncates, the +2047 rounds half up.
@ -----------------------------------------------------------------------------
LFUNC fn_08013728
    movw r1, #PWR_BAT_NUM
    muls r0, r1, r0                         @ code * 1330
    movw r1, #(PWR_BAT_DEN / 2)
    adds r0, r0, r1                         @ + 2047: round to the nearest 0.01 V
    movw r1, #PWR_BAT_DEN
    udiv r0, r0, r1                         @ / 4095
    bx lr
ENDFUNC fn_08013728

@ -----------------------------------------------------------------------------
@ pwr_bat_trim - apply the battery trim (production image only, DESIGN.md 10 IMP-27)
@ In       : r0 = filtered battery voltage in 0.01 V (fn_080135B0; 331..1013)
@ Out      : r0 = r0 x (1000 + 2 t) / 1000, rounded half up; also stored in pwr_bat_cv.  t = set_btrim (the value being
@            edited) while the battery page (item 1) is in edit mode, else set_btrim_saved (-50..+50 both), which is
@            then copied to set_btrim so that the next edit starts from the saved trim
@ Clobbers : r1, r2, flags
@ Context  : main (adc_ch5_process)
@ Note     : the history keeps the untrimmed values, so a new trim shows at the next reading; 1013 x 1100 + 500 fits
@            easily in 32 bits.
@ -----------------------------------------------------------------------------
FUNC pwr_bat_trim
    ldr r2, =v_2000806E                     @ set_edit
    ldrb r2, [r2]
    cbz r2, 1f
    ldr r2, =v_20008037                     @ set_item
    ldrb r2, [r2]
    cmp r2, #1
    bne 1f
    ldr r1, =set_btrim                      @ item 1 being edited: the edit value
    ldrsb r1, [r1]
    b 2f
1:  ldr r1, =set_btrim_saved                @ otherwise the saved trim, which is also the start value of the next edit
    ldrsb r1, [r1]
    ldr r2, =set_btrim
    strb r1, [r2]
2:
    lsls r1, r1, #1
    add r1, r1, #1000                       @ 1000 + 2 t (900..1100)
    muls r0, r1, r0
    add r0, r0, #500                        @ round half up (the product is positive)
    movw r1, #1000
    udiv r0, r0, r1
    ldr r1, =pwr_bat_cv
    strh r0, [r1]
    bx lr
ENDFUNC pwr_bat_trim

    .ltorg
