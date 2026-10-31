@ =============================================================================
@ adc.s - BRD: internal ADC (PA4 thermistor channel 4, PA5 battery channel 5)
@
@ Replaces FUN_08013DD4 (ADC init), adc_select_channel_4_or_5 0x080137B4, adc_ch4_average_10 0x0801381E,
@ FUN_0801349C (alternation every 100 ms), FUN_0801C97E (ADC off), the ADC library routines 0x08020094,
@ 0x080200B4, 0x08020104, 0x0802012C, 0x080202EA, 0x080202F4, 0x080202FA, 0x08020314, 0x08020348 and the ADC
@ interrupt handler 0x08024A24 (v2.05).  All ADC flag waits are bounded by SYS_WAIT_POLLS (v2.05 waits without
@ bound at 0x080137CC, 0x08013806, 0x08013E0C); on a timeout the routine continues as if the flag had been seen,
@ so the conversion result is whatever ADC_DR holds.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .rodata.brd.adc, "a", %progbits
    .balign 4
@ ADC_Init structure of FUN_08013DD4 (stack at 0x08013DDE..0x08013DF8): resolution 0 (12 bit), scan 0,
@ continuous 0, external trigger edge 0 (NF-01: v2.05 leaves this word [sp+8] uninitialised), external trigger
@ 0, alignment 0 (right), number of conversions 1
brd_adc_init_cfg:
    .word 0                                 @ +0  resolution
    .byte 0                                 @ +4  scan conversion mode
    .byte 0                                 @ +5  continuous conversion mode
    .hword 0                                @ +6  padding
    .word 0                                 @ +8  external trigger edge (NF-01)
    .word 0                                 @ +12 external trigger
    .word 0                                 @ +16 data alignment
    .byte 1                                 @ +20 number of conversions
    .byte 0, 0, 0

    .section .text.brd.adc, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_08013DD4 - ADC reset, configuration, sample times, power-on
@ Replaces : 0x08013DD4 FUN_08013DD4 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (system init)
@ Spec     : RM0038 12.15.3, 12.15.6 ("SMPx bits must be written only when ADON=0")
@ Deviation: NF-01 (trigger edge 0); OF-13: the sample times of channels 4 and 5 (384 cycles, the value v2.05
@            writes on every conversion at 0x080137E0 / 0x080137F0) are written here once, while ADON = 0,
@            through the v2.05 channel routine with rank 1; adc_select_channel_4_or_5 then writes only the
@            rank-1 channel field of ADC_SQR5
@ -----------------------------------------------------------------------------
FUNC fn_08013DD4
    push {r4, lr}
    ldr r4, =ADC1_BASE
    mov r0, r4
    bl fn_08020094                          @ ADC reset pulse (0x08013DDA)
    ldr r1, =brd_adc_init_cfg
    mov r0, r4
    bl fn_080200B4                          @ ADC_Init (0x08013E00)
    movs r3, #ADC_SMP_384
    movs r2, #1
    movs r1, #ADC_CH_TEMP_SENSE
    mov r0, r4
    bl fn_0802012C                          @ OF-13: SMP4 = 384 cycles with ADON = 0
    movs r3, #ADC_SMP_384
    movs r2, #1
    movs r1, #ADC_CH_BATTERY
    mov r0, r4
    bl fn_0802012C                          @ OF-13: SMP5 = 384 cycles with ADON = 0
    movs r1, #1
    mov r0, r4
    bl fn_08020104                          @ ADON (0x08013E08)
    bl brd_adc_wait_adons                   @ wait ADONS, bounded (0x08013E0C)
    pop {r4, pc}
ENDFUNC fn_08013DD4

@ -----------------------------------------------------------------------------
@ brd_adc_wait_adons - bounded wait for ADC_SR ADONS (ADC ready after ADON)
@ Replaces : the unbounded loops 0x08013E0C (FUN_08013DD4) and 0x080137CC (adc_select_channel_4_or_5)
@ In       : -
@ Out      : r0 = 1 flag seen, 0 bound reached
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC brd_adc_wait_adons
    movs r1, #ADC_SR_ADONS
    b brd_adc_wait
ENDFUNC brd_adc_wait_adons

@ -----------------------------------------------------------------------------
@ brd_adc_wait_eoc - bounded wait for ADC_SR EOC (conversion complete)
@ Replaces : the unbounded loop 0x08013806 (adc_select_channel_4_or_5)
@ In       : -
@ Out      : r0 = 1 flag seen, 0 bound reached
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC brd_adc_wait_eoc
    movs r1, #ADC_SR_EOC
    b brd_adc_wait
ENDFUNC brd_adc_wait_eoc

@ -----------------------------------------------------------------------------
@ brd_adc_wait - poll ADC_GetFlagStatus(ADC1, mask) at most SYS_WAIT_POLLS times
@ Replaces : - (body of the two waits above)
@ In       : r1 = ADC_SR flag mask
@ Out      : r0 = 1 flag seen, 0 bound reached
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC brd_adc_wait
    push {r4, r5, r6, lr}
    mov r5, r1                              @ r5 = flag mask
    ldr r4, =SYS_WAIT_POLLS                 @ r4 = polls left
    ldr r6, =ADC1_BASE
.Lbaw_loop:
    mov r1, r5
    mov r0, r6
    bl fn_080202FA                          @ ADC_GetFlagStatus
    cbnz r0, .Lbaw_done
    subs r4, r4, #1
    bne .Lbaw_loop
.Lbaw_done:
    pop {r4, r5, r6, pc}
ENDFUNC brd_adc_wait

@ -----------------------------------------------------------------------------
@ adc_select_channel_4_or_5 - one conversion of channel 5 (r0 = 1) or channel 4 (otherwise)
@ Replaces : 0x080137B4 adc_select_channel_4_or_5 (v2.05)
@ In       : r0 = 1 battery (channel 5), any other value thermistor (channel 4)
@ Out      : r0 = 12-bit conversion result (ADC_DR, low halfword)
@ Clobbers : r1-r3, r12, flags
@ Context  : main
@ Deviation: OF-13 (no SMPR3 write here, see fn_08013DD4); bounded waits
@ -----------------------------------------------------------------------------
FUNC adc_select_channel_4_or_5
    push {r4, r5, r6, lr}
    uxtb r4, r0                             @ r4 = channel selector (v2.05 uxtb r4 at 0x080137DA)
    ldr r5, =ADC1_BASE
    movs r1, #1
    mov r0, #RCC_APB2_ADC1
    bl fn_0801FF9E                          @ ADC clock on (0x080137BE)
    movs r1, #1
    mov r0, r5
    bl fn_08020104                          @ ADON (0x080137C8)
    bl brd_adc_wait_adons                   @ 0x080137CC
    cmp r4, #1
    ite eq                                  @ channel for rank 1
    moveq r1, #ADC_CH_BATTERY               @ 1: channel 5 (0x080137E4)
    movne r1, #ADC_CH_TEMP_SENSE            @ otherwise channel 4 (0x080137F4)
    ldr r2, [r5, #ADC_SQR5]
    bic r2, r2, #0x1F                       @ rank-1 channel field SQ1 (RM0038 12.15.14), as fn_0802012C does
    orr r2, r2, r1                          @ for rank 1 (0x080201F8..0x0802021E)
    str r2, [r5, #ADC_SQR5]
    mov r0, r5
    bl fn_080202EA                          @ start conversion (0x08013802)
    bl brd_adc_wait_eoc                     @ 0x08013806
    mov r0, r5
    bl fn_080202F4                          @ result (0x08013818)
    pop {r4, r5, r6, pc}
ENDFUNC adc_select_channel_4_or_5

@ -----------------------------------------------------------------------------
@ adc_ch4_average_10 - thermistor conversion and temperature processing
@ Replaces : 0x0801381E adc_ch4_average_10 (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main (100 ms step)
@ RAM      : writes 0x20007FD2 (last ADC result, u16), 0x20008062
@ -----------------------------------------------------------------------------
FUNC adc_ch4_average_10
    push {r4, lr}
    movs r0, #0
    bl adc_select_channel_4_or_5            @ channel 4 (0x08013822)
    ldr r4, =v_20007FD2
    strh r0, [r4]                           @ 0x0801382A
    bl fn_0801C97E                          @ ADC off (0x0801382C)
    ldrh r0, [r4]
    cmp r0, #0x8000
    bge .Lca10_done                         @ signed compare as v2.05 (0x0801383A); never taken for a u16
    bl adc_ch4_process                      @ MTMP (0x08013842)
    ldr r0, =v_20008037
    ldrb r0, [r0]
    cbnz r0, .Lca10_done                    @ setup page shown: no redraw request
    movs r0, #1
    ldr r1, =v_20008062
    strb r0, [r1]                           @ 0x08013856
.Lca10_done:
    pop {r4, pc}
ENDFUNC adc_ch4_average_10

@ -----------------------------------------------------------------------------
@ fn_0801349C - every 100 ms alternate between thermistor and battery conversion
@ Replaces : 0x0801349C FUN_0801349C (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, r12, flags
@ Context  : main
@ RAM      : 0x20008086 (alternation index, owner BRD)
@ -----------------------------------------------------------------------------
FUNC fn_0801349C
    push {r3, lr}
    ldr r1, =v_20008086
    ldrb r0, [r1]
    adds r0, r0, #1
    strb r0, [r1]                           @ 0x080134AA
    uxtb r0, r0
    cmp r0, #2
    blt .L349c_sel                          @ signed byte compare as v2.05 (0x080134B4)
    movs r0, #0
    strb r0, [r1]
.L349c_sel:
    ldrb r0, [r1]
    cbz r0, .L349c_ch4
    cmp r0, #1
    bne .L349c_done
    bl adc_ch5_process                      @ battery (PWR) (0x080134D4)
    b .L349c_done
.L349c_ch4:
    bl adc_ch4_average_10                   @ 0x080134CE
.L349c_done:
    pop {r3, pc}
ENDFUNC fn_0801349C

@ -----------------------------------------------------------------------------
@ fn_0801C97E - ADC off and its clock off
@ Replaces : 0x0801C97E FUN_0801C97E (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
FUNC fn_0801C97E
    push {r3, lr}
    movs r1, #0
    ldr r0, =ADC1_BASE
    bl fn_08020104                          @ ADON = 0 (0x0801C984)
    movs r1, #0
    mov r0, #RCC_APB2_ADC1
    bl fn_0801FF9E                          @ ADC clock off (0x0801C98E)
    pop {r3, pc}
ENDFUNC fn_0801C97E

@ -----------------------------------------------------------------------------
@ brd_adc_isr - ADC1 interrupt (never enabled by v2.05; ported so that no v2.05 code is dropped)
@ Replaces : 0x08024A24 IRQ18_Handler (v2.05)
@ In/Out   : - / -
@ Clobbers : r0-r3 (exception frame)
@ Context  : IRQ18
@ -----------------------------------------------------------------------------
FUNC brd_adc_isr
    push {r3, lr}
    movw r1, #0x106                         @ ADC_IT_AWD (v2.05 0x08024A26)
    ldr r0, =ADC1_BASE
    bl fn_08020314
    cbz r0, .Lbai_done
    movw r1, #0x106
    ldr r0, =ADC1_BASE
    bl fn_08020348
.Lbai_done:
    pop {r3, pc}
ENDFUNC brd_adc_isr

@ =============================================================================
@ ADC library routines (v2.05 StdPeriph code, same register effects)
@ =============================================================================

@ -----------------------------------------------------------------------------
@ fn_08020094 - ADC reset through RCC_APB2RSTR (ADC_DeInit)
@ Replaces : 0x08020094 (v2.05)
@ In       : r0 = ADC base (only ADC1 acts)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_08020094
    push {r4, lr}
    ldr r1, =ADC1_BASE
    cmp r0, r1
    bne .L20094_done
    movs r1, #1
    mov r0, #RCC_APB2_ADC1
    bl fn_0801FFDA                          @ reset asserted (0x080200A4)
    movs r1, #0
    mov r0, #RCC_APB2_ADC1
    bl fn_0801FFDA                          @ reset released (0x080200AE)
.L20094_done:
    pop {r4, pc}
ENDFUNC fn_08020094

@ -----------------------------------------------------------------------------
@ fn_080200B4 - ADC configuration (ADC_Init)
@ Replaces : 0x080200B4 (v2.05)
@ In       : r0 = ADC base, r1 = structure (layout at brd_adc_init_cfg)
@ Out      : -
@ Clobbers : r2, r3, r12, flags
@ Context  : main
@ Spec     : RM0038 12.15.2, 12.15.3, 12.15.10
@ -----------------------------------------------------------------------------
LFUNC fn_080200B4
    push {r4, r5}
    ldr r3, [r0, #ADC_CR1]
    ldr r4, =ADC_CR1_KEEP
    ands r3, r3, r4
    ldrb r4, [r1, #4]                       @ scan mode
    ldr r5, [r1]                            @ resolution
    orr r4, r5, r4, lsl #8
    orrs r3, r3, r4
    str r3, [r0, #ADC_CR1]                  @ 0x080200CC
    ldr r3, [r0, #ADC_CR2]
    ldr r4, =ADC_CR2_KEEP
    ands r3, r3, r4
    ldr r4, [r1, #16]                       @ alignment
    ldr r5, [r1, #12]                       @ external trigger
    orrs r4, r4, r5
    ldr r5, [r1, #8]                        @ external trigger edge
    orrs r4, r4, r5
    ldrb r5, [r1, #5]                       @ continuous mode
    orr r4, r4, r5, lsl #1
    orrs r3, r3, r4
    str r3, [r0, #ADC_CR2]                  @ 0x080200E8
    ldr r3, [r0, #ADC_SQR1]
    bic r3, r3, #0x01F00000                 @ L field (0x080200EE)
    ldrb r4, [r1, #20]
    subs r4, r4, #1
    uxtb r4, r4
    orr r3, r3, r4, lsl #20
    str r3, [r0, #ADC_SQR1]
    pop {r4, r5}
    bx lr
ENDFUNC fn_080200B4

@ -----------------------------------------------------------------------------
@ fn_08020104 - ADC on/off (ADC_Cmd)
@ Replaces : 0x08020104 (v2.05)
@ In       : r0 = ADC base, r1 = 0 off, else on
@ Out      : -
@ Clobbers : r1, r2
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_08020104
    uxtb r1, r1
    ldr r2, [r0, #ADC_CR2]
    cbz r1, .L20104_off
    orr r2, r2, #ADC_CR2_ADON
    str r2, [r0, #ADC_CR2]
    bx lr
.L20104_off:
    bic r2, r2, #ADC_CR2_ADON               @ v2.05 lsrs/lsls #1 (0x08020116)
    str r2, [r0, #ADC_CR2]
    bx lr
ENDFUNC fn_08020104

@ -----------------------------------------------------------------------------
@ fn_0802012C - regular channel rank and sample time (ADC_RegularChannelConfig)
@ Replaces : 0x0802012C (v2.05)
@ In       : r0 = ADC base, r1 = channel, r2 = rank 1..28, r3 = sample time 0..7
@ Out      : -
@ Clobbers : r1-r3, r12, flags
@ Spec     : RM0038 12.15.4..12.15.6, 12.15.10..12.15.14, 12.15.18
@ Context  : main; called only while ADON = 0 (OF-13)
@ -----------------------------------------------------------------------------
LFUNC fn_0802012C
    push {r4-r7}
    uxtb r1, r1
    uxtb r3, r3
    uxtb r2, r2
    @ sample time register and field: channel >= 30 SMPR0, >= 20 SMPR1, >= 10 SMPR2, else SMPR3
    cmp r1, #30
    blt .L2012c_s1
    sub r4, r1, #30
    movs r5, #ADC_SMPR0
    b .L2012c_smp
.L2012c_s1:
    cmp r1, #20
    blt .L2012c_s2
    sub r4, r1, #20
    movs r5, #ADC_SMPR1
    b .L2012c_smp
.L2012c_s2:
    cmp r1, #10
    blt .L2012c_s3
    sub r4, r1, #10
    movs r5, #ADC_SMPR2
    b .L2012c_smp
.L2012c_s3:
    mov r4, r1
    movs r5, #ADC_SMPR3
.L2012c_smp:                                @ r4 = field index, r5 = register offset
    add r4, r4, r4, lsl #1                  @ 3 bits per channel
    ldr r6, [r0, r5]
    movs r7, #7
    lsl r7, r7, r4
    bic r6, r6, r7
    lsl r7, r3, r4
    orr r6, r6, r7
    str r6, [r0, r5]
    @ sequence register and field: rank < 7 SQR5, < 13 SQR4, < 19 SQR3, < 25 SQR2, else SQR1
    cmp r2, #7
    bge .L2012c_q4
    sub r4, r2, #1
    movs r5, #ADC_SQR5
    b .L2012c_seq
.L2012c_q4:
    cmp r2, #13
    bge .L2012c_q3
    sub r4, r2, #7
    movs r5, #ADC_SQR4
    b .L2012c_seq
.L2012c_q3:
    cmp r2, #19
    bge .L2012c_q2
    sub r4, r2, #13
    movs r5, #ADC_SQR3
    b .L2012c_seq
.L2012c_q2:
    cmp r2, #25
    bge .L2012c_q1
    sub r4, r2, #19
    movs r5, #ADC_SQR2
    b .L2012c_seq
.L2012c_q1:
    sub r4, r2, #25
    movs r5, #ADC_SQR1
.L2012c_seq:                                @ r4 = field index, r5 = register offset
    add r4, r4, r4, lsl #2                  @ 5 bits per rank
    ldr r6, [r0, r5]
    movs r7, #0x1F
    lsl r7, r7, r4
    bic r6, r6, r7
    lsl r7, r1, r4
    orr r6, r6, r7
    str r6, [r0, r5]
    pop {r4-r7}
    bx lr
ENDFUNC fn_0802012C

@ -----------------------------------------------------------------------------
@ fn_080202EA - start a regular conversion (ADC_SoftwareStartConv)
@ Replaces : 0x080202EA (v2.05)
@ In       : r0 = ADC base
@ Out      : -
@ Clobbers : r1
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_080202EA
    ldr r1, [r0, #ADC_CR2]
    orr r1, r1, #ADC_CR2_SWSTART
    str r1, [r0, #ADC_CR2]
    bx lr
ENDFUNC fn_080202EA

@ -----------------------------------------------------------------------------
@ fn_080202F4 - conversion result (ADC_GetConversionValue)
@ Replaces : 0x080202F4 (v2.05)
@ In       : r0 = ADC base
@ Out      : r0 = ADC_DR low halfword
@ Clobbers : none besides r0
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_080202F4
    ldr r0, [r0, #ADC_DR]
    uxth r0, r0
    bx lr
ENDFUNC fn_080202F4

@ -----------------------------------------------------------------------------
@ fn_080202FA - ADC_SR flag status (ADC_GetFlagStatus)
@ Replaces : 0x080202FA (v2.05)
@ In       : r0 = ADC base, r1 = flag mask (low halfword)
@ Out      : r0 = 1 set, 0 clear
@ Clobbers : r1-r3
@ Context  : main
@ -----------------------------------------------------------------------------
LFUNC fn_080202FA
    ldr r3, [r0, #ADC_SR]
    uxth r1, r1
    tst r3, r1
    ite ne                                  @ result from the flag test
    movne r0, #1                            @ flag set
    moveq r0, #0                            @ flag clear
    bx lr
ENDFUNC fn_080202FA

@ -----------------------------------------------------------------------------
@ fn_08020314 - ADC interrupt status (ADC_GetITStatus)
@ Replaces : 0x08020314 (v2.05)
@ In       : r0 = ADC base, r1 = interrupt code (bits 15:8 ADC_SR mask, bits 7:0 ADC_CR1 enable bit number)
@ Out      : r0 = 1 flag set and interrupt enabled, else 0
@ Clobbers : r1-r3, r12
@ Context  : IRQ18 (brd_adc_isr)
@ -----------------------------------------------------------------------------
LFUNC fn_08020314
    uxth r1, r1
    lsrs r3, r1, #8                         @ status mask
    ldr r12, [r0, #ADC_CR1]
    movs r2, #1
    lsl r2, r2, r1                          @ enable bit (shift by the low byte, as lsls r6,r1 at 0x08020328)
    and r12, r12, r2
    ldr r2, [r0, #ADC_SR]
    movs r0, #0
    tst r2, r3
    beq .L20314_done
    cmp r12, #0
    it ne                                   @ status set and interrupt enabled
    movne r0, #1                            @ status set and enable bit set: 1
.L20314_done:
    bx lr
ENDFUNC fn_08020314

@ -----------------------------------------------------------------------------
@ fn_08020348 - clear ADC interrupt flag (ADC_ClearITPendingBit): ADC_SR = ~(code >> 8)
@ Replaces : 0x08020348 (v2.05)
@ In       : r0 = ADC base, r1 = interrupt code
@ Out      : -
@ Clobbers : r1, r2
@ Context  : IRQ18 (brd_adc_isr)
@ -----------------------------------------------------------------------------
LFUNC fn_08020348
    uxth r1, r1
    lsrs r1, r1, #8
    uxtb r1, r1
    mvns r2, r1
    str r2, [r0, #ADC_SR]
    bx lr
ENDFUNC fn_08020348

    .ltorg
