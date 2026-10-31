@ =============================================================================
@ battery.s - PWR: battery voltage measurement and low-battery state
@
@ Replaces adc_ch5_process 0x080134DA, FUN_080135B0 (20-value history with trimmed mean), FUN_0801368A (sort)
@ and FUN_08013728 (ADC code -> battery value by the table 0x08028C9C) (v2.05).
@ The table is v205_tab_08028C9C (16 words, firmware/tools/extract_tables.py, src/pwr/tables_v205.s).
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
    .equ PWR_TABLE_PREV,    0x000186A0      @ the word before the table, image 0x08028C98 (see fn_08013728)

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
    bl fn_08013728                          @ table conversion (0x0801351A)
    bl fn_080135B0                          @ history and trimmed mean (0x08013522)
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
@ fn_08013728 - battery value from the clamped ADC code (linear interpolation in the 16-entry table)
@ Replaces : 0x08013728 FUN_08013728 (v2.05)
@ In       : r0 = ADC code, 0x3FC..0xC30 (clamped by the caller)
@ Out      : r0 = (0x41A - 50 * i + (int)((float)((code - T[i]) * 50) / (float)(T[i-1] - T[i]))) & 0xFFFF,
@            i = first index with code >= T[i]
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Note     : for i = 0 (code = 0xC30 = T[0]) v2.05 reads T[-1], the word at 0x08028C98 just before the table
@            (0x0801377A..0x08013784), which is 0x000186A0 in the image; the same value is used here as the
@            constant PWR_TABLE_PREV, so the float operations are those of v2.05 for every input
@            (numerator 0, result 0x41A).
@ -----------------------------------------------------------------------------
LFUNC fn_08013728
    push {r4-r9, lr}
    sub sp, sp, #4
    mov r4, r0                              @ r4 = code
    ldr r6, =v205_tab_08028C9C              @ r6 = table T
    movs r5, #0                             @ r5 = index i
.L3728_find:                                @ 0x08013738..0x08013754
    ldr r0, [r6, r5, lsl #2]
    cmp r4, r0
    bhs .L3728_found                        @ code >= T[i]
    adds r5, r5, #1
    uxtb r5, r5
    b .L3728_find
.L3728_found:
    movw r0, #0x41A
    movs r1, #50
    mls r7, r1, r5, r0                      @ r7 = 0x41A - 50 * i (0x0801375E)
    ldr r0, [r6, r5, lsl #2]
    subs r0, r4, r0
    muls r0, r1, r0                         @ (code - T[i]) * 50
    bl fn_08012F74                          @ unsigned to float (RT) (0x08013774)
    mov r9, r0
    cbnz r5, .L3728_prev_tab
    ldr r0, =PWR_TABLE_PREV                 @ T[-1] (see Note)
    b .L3728_prev
.L3728_prev_tab:
    sub r0, r5, #1
    ldr r0, [r6, r0, lsl #2]                @ T[i-1] (0x08013784)
.L3728_prev:
    ldr r1, [r6, r5, lsl #2]
    subs r0, r0, r1                         @ T[i-1] - T[i]
    bl fn_08012F74                          @ 0x08013794
    mov r1, r0
    mov r0, r9
    bl fn_08012F94                          @ float divide (RT) (0x0801379C)
    bl fn_08013370                          @ float to int, truncating (RT) (0x080137A0)
    add r0, r7, r0
    uxth r0, r0                             @ 0x080137AA
    add sp, sp, #4
    pop {r4-r9, pc}
ENDFUNC fn_08013728

    .ltorg
