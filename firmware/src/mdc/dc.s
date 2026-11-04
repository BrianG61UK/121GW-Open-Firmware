@ =============================================================================
@ dc.s - MDC: DC voltage, DC millivolt and DC current chains (per AD1 conversion)
@
@ Replaces v2.05 FUN_08007714 0x08007714 (DCV, LowZ DC, AC+DC DC phase), FUN_080077F0 0x080077F0 (DCmV, TEMP front part),
@ FUN_08007FA8 0x08007FA8 (DC currents with the two-channel scheme) and FUN_08008138 0x08008138 (DC currents with user zero).
@
@ Each handler is called by ad1_ready_dispatch (HY) for every conversion: when 0x20008081 = 1 (a mean was completed) it runs the
@ mean chain (fn_08006418), the display smoothing fn_0800B754 (FUNC) and sets the new-value flag 0x2000805D; it then always runs the
@ per-sample chain fn_080064D6.
@
@ IMP-01: the auto-ranged DC modes (DCV 1, DCmV 3, DC currents 17, 19, 21) are judged by ar_sample before their
@ conversion is accumulated (mdc_sample_precheck in ad1.s, called from ad1_ready_dispatch); the handlers here are unchanged by it.
@
@ OF-28: the AC+DC DC phase (mode 2 with AC+DC on, 0x200080BA) smooths through its own state block mdc_acdc_dc_state, so that it no
@ longer shares the v2.05 history (0x20007DF8, 0x20008085, 0x20007238) with the AC+DC combined value (MAC).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"


    .equ MDC_SMOOTH_STATE_BYTES, 96         @ one func_smooth_hist state block: s32 last output, u8 count, s32 history[21] (v2.05 0x20007DF8, 0x20008085, 0x20007238)

    .section .text.mdc.dc, "ax", %progbits

@ -----------------------------------------------------------------------------
@ mdc_dc_state - smoothing state block of the quantity a DC chain is processing (OF-28)
@ Replaces : new (OF-28: v2.05 passes every DC quantity through one history, 0x20007DF8 / 0x20008085 / 0x20007238)
@ In       : r0 = 0 voltage chain (fn_08007714), 1 current chain (fn_08008138)
@ Out      : r3 = func_smooth_hist state block of the quantity, or 0 = keep fn_0800B754 and its v2.05 state
@ Clobbers : r1, r2, r3, flags
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x200080A5
@ Spec     : ORIGINAL_FIRMWARE_ISSUES.md OF-28; requests/W6_to_W5.md 4; src/func/smooth.s (blocks)
@ Deviation: OF-28
@ Mode 2 (AC+DC DC phase): mdc_acdc_dc_state.  Modes 22, 23, 24 (DC VA): func_st_va_volt for the voltage chain, func_st_va_curr for the current chain.
@ Modes 17, 19, 21 with the burden option 0x200080A5 = 1 (two quantities alternate): func_st_burden_volt / func_st_burden_curr.  Everything else
@ (DCV, LowZ DC, DCmV, single-quantity current modes) shares the v2.05 history with no other quantity, so it keeps fn_0800B754.
@ -----------------------------------------------------------------------------
LFUNC mdc_dc_state
    ldr r1, =meter_mode
    ldrb r1, [r1]                           @ r1 = mode
    cmp r1, #2
    bne 1f
    cmp r0, #0
    bne 4f                                  @ the current chain never runs in mode 2
    ldr r3, =mdc_acdc_dc_state              @ AC+DC DC phase (voltage chain)
    bx lr
1:  subs r2, r1, #22
    cmp r2, #2
    bhi 2f                                  @ not 22..24
    ldr r3, =func_st_va_volt                @ DC VA, voltage chain
    cmp r0, #0
    beq 5f
    ldr r3, =func_st_va_curr                @ DC VA, current chain
5:  bx lr
2:  cmp r1, #17
    beq 3f
    cmp r1, #19
    beq 3f
    cmp r1, #21
    bne 4f                                  @ not a DC current mode
3:  ldr r2, =v_200080A5
    ldrb r2, [r2]
    cmp r2, #1
    bne 4f                                  @ burden option off: one quantity only
    ldr r3, =func_st_burden_volt            @ burden display, voltage
    cmp r0, #0
    beq 6f
    ldr r3, =func_st_burden_curr            @ burden display, current
6:  bx lr
4:  movs r3, #0                             @ v2.05 shared history
    bx lr
    .ltorg
ENDFUNC mdc_dc_state

@ -----------------------------------------------------------------------------
@ fn_08007714 - DC voltage chain (DCV, LowZ DC, AC+DC DC phase, DC current voltage channel)
@ Replaces : 0x08007714 FUN_08007714 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x200080BA acdc_active, 0x200080BD acdc_use_dcv_cal, 0x2000803C meter_mode, 0x20000239,
@            0x20007D64, 0x20008081
@            writes 0x20007D64, 0x2000805D
@ Spec     : analysis/hy3131_model.md 5.2, 4.2; hy3131_modes_ac_current.md
@ Deviation: OF-28
@ Mean branch (0x20008081 = 1): D = fn_08006418 (mean -> calibrated value), smoothed with threshold 2 counts and depth 2 (own state block per quantity, OF-28,
@ see mdc_dc_state); 0x2000805D = 1.
@ Called for modes 0 (LowZ DC), 1 (DCV), 2 with AC+DC on and 0x200080BD set (DC phase of AC+DC), and by FUN_08007FA8.
@ -----------------------------------------------------------------------------
FUNC fn_08007714
    push {r7, lr}                      @ 0x08007714  
    ldr r0, =v_20008081                @ 0x08007716 pool 0x08007FA4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x0800771A  0x20008081 = a mean was completed
    cmp r0, #0                         @ 0x0800771C
    beq .L08007778                     @ 0x0800771E
    bl fn_08006418                     @ 0x08007720  mean code -> 0x20007D64 (calibrated value)
    @ OF-28: the quantity gets a smoothing state of its own (mdc_dc_state): AC+DC DC phase, DC VA voltage, burden-display voltage;
    @ every other caller keeps the v2.05 state (fn_0800B754)
    movs r0, #0                             @ voltage chain
    bl mdc_dc_state                         @ r3 = state block, 0 = the v2.05 shared state
    movs r2, #2                        @ 0x08007724  r2 = depth 2
    movs r1, #2                        @ 0x08007726  r1 = threshold 2 counts
    ldr r0, =v_20007D64                @ 0x08007728 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x0800772C
    cmp r3, #0
    beq .Ld7_plain
    bl func_smooth_hist                     @ r0 = value, r1 = 2, r2 = 2, r3 = state block
    b .Ld7_smoothed
.Ld7_plain:
    bl fn_0800B754                          @ v2.05 0x0800772E: shared v2.05 history
.Ld7_smoothed:
    ldr r1, =v_20007D64                @ 0x08007732 pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007736  smoothed value back to 0x20007D64
    ldr r0, =meter_mode                @ 0x08007738 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800773A
    cmp r0, #2                         @ 0x0800773C  mode 2 (ACV) here means the AC+DC DC phase
    bne .L0800774A                     @ 0x0800773E
    ldr r0, =acdc_active               @ 0x08007740 pool 0x08007E60 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x08007744  0x200080BA AC+DC active
    cmp r0, #0                         @ 0x08007746
    bne .L08007752                     @ 0x08007748
.L0800774A:                              @ reached from 0x0800773E bne
    movs r0, #1                        @ 0x0800774A
    ldr r1, =v_2000805D                @ 0x0800774C pool 0x08007F9C = 0x2000805D
    strb r0, [r1, #0]                  @ 0x08007750  0x2000805D = 1: new value (not for the AC+DC DC phase, MAC publishes the combined value)
.L08007752:                              @ reached from 0x08007748 bne
    ldr r0, =meter_mode                @ 0x08007752 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08007754
    cmp r0, #2                         @ 0x08007756
    bne .L08007778                     @ 0x08007758
    ldr r0, =acdc_active               @ 0x0800775A pool 0x08007E60 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x0800775E
    cmp r0, #0                         @ 0x08007760
    beq .L08007778                     @ 0x08007762
    ldr r0, =acdc_use_dcv_cal          @ 0x08007764 pool 0x08007F98 = 0x200080BD
    ldrb r0, [r0, #0]                  @ 0x08007768
    cmp r0, #1                         @ 0x0800776A
    bne .L08007778                     @ 0x0800776C
    ldr r0, =acdc_use_dcv_cal          @ 0x0800776E pool 0x08007F98 = 0x200080BD
    ldrb r0, [r0, #0]                  @ 0x08007772
    bl fn_0800A5BC                     @ 0x08007774  AC+DC: FUN_0800A5BC (MAC) with 0x200080BD
.L08007778:                              @ reached from 0x0800771E beq, 0x08007758 bne, 0x08007762 beq, 0x0800776C bne
    @ ---- per-sample chain: not for AC+DC (mode 2 with 0x200080BA) and not for the current modes 16..21 (their handlers call it);
    @      LowZ (mode 0) only when 0x20000239 = 5 ----
    ldr r0, =meter_mode                @ 0x08007778 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800777A
    cmp r0, #2                         @ 0x0800777C
    bne .L0800778A                     @ 0x0800777E
    ldr r0, =acdc_active               @ 0x08007780 pool 0x08007E60 = 0x200080BA
    ldrb r0, [r0, #0]                  @ 0x08007784
    cmp r0, #0                         @ 0x08007786
    bne .L080077D8                     @ 0x08007788
.L0800778A:                              @ reached from 0x0800777E bne
    ldr r0, =meter_mode                @ 0x0800778A pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800778C
    cmp r0, #16                        @ 0x0800778E
    beq .L080077D8                     @ 0x08007790
    ldr r0, =meter_mode                @ 0x08007792 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x08007794
    cmp r0, #18                        @ 0x08007796
    beq .L080077D8                     @ 0x08007798
    ldr r0, =meter_mode                @ 0x0800779A pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x0800779C
    cmp r0, #20                        @ 0x0800779E
    beq .L080077D8                     @ 0x080077A0
    ldr r0, =meter_mode                @ 0x080077A2 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080077A4
    cmp r0, #17                        @ 0x080077A6
    beq .L080077D8                     @ 0x080077A8
    ldr r0, =meter_mode                @ 0x080077AA pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080077AC
    cmp r0, #19                        @ 0x080077AE
    beq .L080077D8                     @ 0x080077B0
    ldr r0, =meter_mode                @ 0x080077B2 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080077B4
    cmp r0, #21                        @ 0x080077B6
    beq .L080077D8                     @ 0x080077B8
    ldr r0, =meter_mode                @ 0x080077BA pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080077BC
    cmp r0, #0                         @ 0x080077BE  mode 0 (LowZ)?
    bne .L080077D4                     @ 0x080077C0
    ldr r0, =meter_mode                @ 0x080077C2 pool 0x080077DC = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080077C4
    cmp r0, #0                         @ 0x080077C6
    bne .L080077D8                     @ 0x080077C8
    ldr r0, =v_20000239                @ 0x080077CA pool 0x08008278 = 0x20000239
    ldrb r0, [r0, #0]                  @ 0x080077CE  0x20000239 = LowZ settle phase (5)
    cmp r0, #5                         @ 0x080077D0
    bne .L080077D8                     @ 0x080077D2
.L080077D4:                              @ reached from 0x080077C0 bne
    bl fn_080064D6                     @ 0x080077D4
.L080077D8:                              @ reached from 0x08007788 bne, 0x08007790 beq, 0x08007798 beq, 0x080077A0 beq, 0x080077A8 beq, 0x080077B0 beq, 0x080077B8 beq, 0x080077C8 bne, 0x080077D2 bne
    pop {r0, pc}                       @ 0x080077D8
    .ltorg
ENDFUNC fn_08007714

@ -----------------------------------------------------------------------------
@ fn_080077F0 - DC millivolt chain (DCmV, and the AD1 part of TEMP)
@ Replaces : 0x080077F0 FUN_080077F0 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags
@ Context  : main only
@ RAM      : reads  0x20007D64, 0x20008081
@            writes 0x20007D64, 0x2000805D
@ Spec     : analysis/hy3131_modes_misc.md 4.1 step 2
@ Deviation: none
@ Mean branch: D = fn_08006418, smoothed with threshold 5 counts, depth 10; 0x2000805D = 1.  1 count = 1 uV of thermocouple EMF in TEMP.
@ TEMP (mode 5) then continues in fn_08007840 (MTMP).
@ -----------------------------------------------------------------------------
FUNC fn_080077F0
    push {r7, lr}                      @ 0x080077F0
    ldr r0, =v_20008081                @ 0x080077F2 pool 0x08007FA4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x080077F6  0x20008081: a mean was completed
    cmp r0, #0                         @ 0x080077F8
    beq .L0800781C                     @ 0x080077FA
    bl fn_08006418                     @ 0x080077FC  mean code -> 0x20007D64
    movs r2, #10                       @ 0x08007800  r2 = depth 10
    movs r1, #5                        @ 0x08007802  r1 = threshold 5 counts (5 uV)
    ldr r0, =v_20007D64                @ 0x08007804 pool 0x08007F94 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007808
    bl fn_0800B754                     @ 0x0800780A  display smoothing (5, 10)
    ldr r1, =v_20007D64                @ 0x0800780E pool 0x08007F94 = 0x20007D64
    str r0, [r1, #0]                   @ 0x08007812
    movs r0, #1                        @ 0x08007814
    ldr r1, =v_2000805D                @ 0x08007816 pool 0x08007F9C = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800781A  0x2000805D = 1: new value
.L0800781C:                              @ reached from 0x080077FA beq
    bl fn_080064D6                     @ 0x0800781C
    pop {r0, pc}                       @ 0x08007820
    .ltorg
ENDFUNC fn_080077F0

@ -----------------------------------------------------------------------------
@ fn_08007FA8 - DC current modes 17, 19, 21: channel scheme around the DC current chain
@ Replaces : 0x08007FA8 FUN_08007FA8 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x20007D64, 0x20007E6C, 0x20008037, 0x2000805D, 0x2000805E, 0x20008081, 0x2000808A, 0x200080A5,
@            0x200080C5, 0x200080C4 va_channel
@            writes 0x20007E6C, 0x2000805D, 0x2000805E, 0x20008062, 0x200080A7, 0x200080C5, 0x200080C4 va_channel
@ Spec     : analysis/hy3131_modes_ac_current.md (DC currents)
@ Deviation: none
@ Handler of AD1 conversions in modes 17 (DCuA), 19 (DCmA), 21 (DCA).  The per-channel chains are FUN_08008138 (current, with user
@ zero) and FUN_08007714 (voltage channel).  mdc_sample_precheck (ad1.s) applies ar_sample to the current channel only.
@ -----------------------------------------------------------------------------
FUNC fn_08007FA8
    @ r4 = per-channel mean count limit (set below); 0x2000808A = calibration mode, 0x200080A5 = scheme selection byte (SET)
    @ ---- calibration mode, or 0x200080A5 != 1: single-channel chain FUN_08008138 only ----
    push {r4, lr}                      @ 0x08007FA8
    movs r4, #0                        @ 0x08007FAA
    ldr r0, =v_2000808A                @ 0x08007FAC pool 0x080087C0 = 0x2000808A
    ldrb r0, [r0, #0]                  @ 0x08007FB0
    ldr r1, =v_200080A5                @ 0x08007FB2 pool 0x080087E0 = 0x200080A5
    ldrb r1, [r1, #0]                  @ 0x08007FB6
    eors.w r1, r1, #1                  @ 0x08007FB8  0x200080A5 xor 1
    orrs r0, r1                        @ 0x08007FBC
    uxtb r0, r0                        @ 0x08007FBE
    cmp r0, #0                         @ 0x08007FC0
    beq .L08007FCA                     @ 0x08007FC2
    bl fn_08008138                     @ 0x08007FC4  single-channel chain
    b .L080080C6                       @ 0x08007FC8
.L08007FCA:                              @ reached from 0x08007FC2 beq
    @ ---- two-channel scheme: 0x200080C4 (va_channel) = 1: voltage chain FUN_08007714 (mean stored in 0x20007E6C); 0 : current chain FUN_08008138 ----
    ldr r0, =va_channel                @ 0x08007FCA pool 0x08008B54 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x08007FCE
    cmp r0, #0                         @ 0x08007FD0
    beq .L08007FF0                     @ 0x08007FD2
    bl fn_08007714                     @ 0x08007FD4  voltage chain
    ldr r0, =v_20008081                @ 0x08007FD8 pool 0x080087E4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x08007FDC
    cmp r0, #0                         @ 0x08007FDE
    beq .L08007FF4                     @ 0x08007FE0
    ldr r0, =v_20007D64                @ 0x08007FE2 pool 0x080087C8 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08007FE6
    ldr r1, =v_20007E6C                @ 0x08007FE8 pool 0x080087E8 = 0x20007E6C
    str r0, [r1, #0]                   @ 0x08007FEC
    b .L08007FF4                       @ 0x08007FEE
.L08007FF0:                              @ reached from 0x08007FD2 beq
    bl fn_08008138                     @ 0x08007FF0
.L08007FF4:                              @ reached from 0x08007FE0 beq, 0x08007FEE b
    @ ---- a new mean (0x2000805D) was published: count it in 0x200080C5; after r4 = 3 means the channel is switched ----
    ldr r0, =v_2000805D                @ 0x08007FF4 pool 0x080087EC = 0x2000805D
    ldrb r0, [r0, #0]                  @ 0x08007FF8
    cmp r0, #0                         @ 0x08007FFA
    beq .L080080C6                     @ 0x08007FFC
    ldr r0, =va_channel                @ 0x08007FFE pool 0x08008B54 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x08008002
    cmp r0, #0                         @ 0x08008004
    beq .L0800800E                     @ 0x08008006
    movs r0, #3                        @ 0x08008008
    movs r4, r0                        @ 0x0800800A
    b .L08008012                       @ 0x0800800C
.L0800800E:                              @ reached from 0x08008006 beq
    movs r0, #3                        @ 0x0800800E
    movs r4, r0                        @ 0x08008010
.L08008012:                              @ reached from 0x0800800C b
    ldr r0, =v_200080C5                @ 0x08008012 pool 0x080087F0 = 0x200080C5
    ldrb r0, [r0, #0]                  @ 0x08008016
    adds r0, r0, #1                    @ 0x08008018
    ldr r1, =v_200080C5                @ 0x0800801A pool 0x080087F0 = 0x200080C5
    strb r0, [r1, #0]                  @ 0x0800801E
    movs r0, r4                        @ 0x08008020
    ldr r1, =v_200080C5                @ 0x08008022 pool 0x080087F0 = 0x200080C5
    ldrb r1, [r1, #0]                  @ 0x08008026
    uxtb r0, r0                        @ 0x08008028
    cmp r0, r1                         @ 0x0800802A
    bcc .L08008040                     @ 0x0800802C
    movs r0, #0                        @ 0x0800802E
    ldr r1, =v_2000805E                @ 0x08008030 pool 0x080081F8 = 0x2000805E
    strb r0, [r1, #0]                  @ 0x08008032
    ldr r0, =v_2000805E                @ 0x08008034 pool 0x080081F8 = 0x2000805E
    ldrb r0, [r0, #0]                  @ 0x08008036
    ldr r1, =v_2000805D                @ 0x08008038 pool 0x080087EC = 0x2000805D
    strb r0, [r1, #0]                  @ 0x0800803C
    b .L080080C6                       @ 0x0800803E
.L08008040:                              @ reached from 0x0800802C bcc
    @ ---- limit reached: channel 1: 0x20007E6C = mean of three (FUN_0800B888), 0x200080A7 = 1 when it is above 5000; display value published ----
    ldr r0, =va_channel                @ 0x08008040 pool 0x08008B54 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x08008044
    cmp r0, #0                         @ 0x08008046
    beq .L08008098                     @ 0x08008048
    ldr r0, =v_20007E6C                @ 0x0800804A pool 0x080087E8 = 0x20007E6C
    ldr r0, [r0, #0]                   @ 0x0800804E
    bl fn_0800B888                     @ 0x08008050
    ldr r1, =v_20007E6C                @ 0x08008054 pool 0x080087E8 = 0x20007E6C
    str r0, [r1, #0]                   @ 0x08008058
    movs r0, #0                        @ 0x0800805A
    ldr r1, =v_200080A7                @ 0x0800805C pool 0x080087F4 = 0x200080A7
    strb r0, [r1, #0]                  @ 0x08008060
    ldr r0, =v_20007E6C                @ 0x08008062 pool 0x080087E8 = 0x20007E6C
    ldr r0, [r0, #0]                   @ 0x08008066
    movw r1, #5001                     @ 0x08008068  5001
    cmp r0, r1                         @ 0x0800806C
    blt .L08008078                     @ 0x0800806E
    movs r0, #1                        @ 0x08008070
    ldr r1, =v_200080A7                @ 0x08008072 pool 0x080087F4 = 0x200080A7
    strb r0, [r1, #0]                  @ 0x08008076
.L08008078:                              @ reached from 0x0800806E blt
    movs r0, #0                        @ 0x08008078
    ldr r1, =v_2000805E                @ 0x0800807A pool 0x080081F8 = 0x2000805E
    strb r0, [r1, #0]                  @ 0x0800807C
    ldr r0, =v_2000805E                @ 0x0800807E pool 0x080081F8 = 0x2000805E
    ldrb r0, [r0, #0]                  @ 0x08008080
    ldr r1, =v_2000805D                @ 0x08008082 pool 0x080087EC = 0x2000805D
    strb r0, [r1, #0]                  @ 0x08008086
    ldr r0, =v_20008037                @ 0x08008088 pool 0x08008B58 = 0x20008037
    ldrb r0, [r0, #0]                  @ 0x0800808C
    cmp r0, #11                        @ 0x0800808E
    bne .L08008098                     @ 0x08008090
    movs r0, #1                        @ 0x08008092
    ldr r1, =v_20008062                @ 0x08008094 pool 0x08008130 = 0x20008062
    strb r0, [r1, #0]                  @ 0x08008096
.L08008098:                              @ reached from 0x08008048 beq, 0x08008090 bne
    @ ---- toggle va_channel, restart the count, re-apply the front end for the new channel (FUN_080080C8, MODE) ----
    movs r0, #0                        @ 0x08008098
    ldr r1, =v_200080C5                @ 0x0800809A pool 0x080087F0 = 0x200080C5
    strb r0, [r1, #0]                  @ 0x0800809E
    ldr r0, =va_channel                @ 0x080080A0 pool 0x08008B54 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x080080A4
    eors.w r0, r0, #1                  @ 0x080080A6
    ldr r1, =va_channel                @ 0x080080AA pool 0x08008B54 = 0x200080C4
    strb r0, [r1, #0]                  @ 0x080080AE
    ldr r0, =va_channel                @ 0x080080B0 pool 0x08008B54 = 0x200080C4
    ldrb r0, [r0, #0]                  @ 0x080080B4
    cmp r0, #0                         @ 0x080080B6
    beq .L080080BE                     @ 0x080080B8
    movs r0, #1                        @ 0x080080BA
    b .L080080C0                       @ 0x080080BC
.L080080BE:                              @ reached from 0x080080B8 beq
    movs r0, #0                        @ 0x080080BE
.L080080C0:                              @ reached from 0x080080BC b
    uxtb r0, r0                        @ 0x080080C0
    bl fn_080080C8                     @ 0x080080C2  FUN_080080C8(channel != 0)
.L080080C6:                              @ reached from 0x08007FC8 b, 0x08007FFC beq, 0x0800803E b
    pop {r4, pc}                       @ 0x080080C6
    .ltorg
ENDFUNC fn_08007FA8

@ -----------------------------------------------------------------------------
@ fn_08008138 - DC current chain with user zero
@ Replaces : 0x08008138 FUN_08008138 (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 preserved)
@ Context  : main only
@ RAM      : reads  0x2000803C meter_mode, 0x2000803D meter_range, 0x20007D64, 0x20007D7C, 0x20007E0C, 0x20008037,
@            0x20008081, 0x200080A5
@            writes 0x20007D64, 0x2000805D, 0x20008062
@ Spec     : analysis/hy3131_modes_ac_current.md
@ Deviation: OF-28
@ Mean branch: D = smoothed(fn_08006418, 10, 10) + FUN_080087F8(0x20007D7C, D); in range 0 the user zero (0x20007E0C) is subtracted.
@ Then the per-sample chain; for modes 16..21 a redraw is requested when sub page 10 is shown.
@ -----------------------------------------------------------------------------
FUNC fn_08008138
    @ ---- r4 = burden correction (set below) ----
    push {r4, lr}                      @ 0x08008138
    movs r4, #0                        @ 0x0800813A
    ldr r0, =v_20008081                @ 0x0800813C pool 0x080087E4 = 0x20008081
    ldrb r0, [r0, #0]                  @ 0x08008140  0x20008081: a mean was completed
    cmp r0, #0                         @ 0x08008142
    beq .L080081A4                     @ 0x08008144
    @ ---- mean branch: mean -> calibrated value, smoothing (10, 10), burden-voltage correction FUN_080087F8 (MVA) ----
    bl fn_08006418                     @ 0x08008146
    movs r0, #1                             @ OF-28: current chain
    bl mdc_dc_state                         @ r3 = state block of the quantity, 0 = the v2.05 shared state
    movs r2, #10                       @ 0x0800814A  depth 10
    movs r1, #10                       @ 0x0800814C  threshold 10 counts
    ldr r0, =v_20007D64                @ 0x0800814E pool 0x080087C8 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08008152
    cmp r3, #0
    beq .Ld8_plain
    bl func_smooth_hist                     @ OF-28: own history (DC VA current, burden-display current)
    b .Ld8_smoothed
.Ld8_plain:
    bl fn_0800B754                     @ 0x08008154  display smoothing (10, 10), shared v2.05 history
.Ld8_smoothed:
    ldr r1, =v_20007D64                @ 0x08008158 pool 0x080087C8 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800815C
    ldr r0, =v_20007D64                @ 0x0800815E pool 0x080087C8 = 0x20007D64
    ldr r1, [r0, #0]                   @ 0x08008162
    ldr r0, =v_20007D7C                @ 0x08008164 pool 0x08008B60 = 0x20007D7C
    ldr r0, [r0, #0]                   @ 0x08008168
    bl fn_080087F8                     @ 0x0800816A  FUN_080087F8(0x20007D7C, D): correction term (MVA)
    movs r4, r0                        @ 0x0800816E
    ldr r0, =v_20007D64                @ 0x08008170 pool 0x080087C8 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x08008174
    adds r0, r4, r0                    @ 0x08008176
    ldr r1, =v_20007D64                @ 0x08008178 pool 0x080087C8 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800817C
    ldr r0, =meter_range               @ 0x0800817E pool 0x080087C4 = 0x2000803D
    @ ---- range 0: subtract the user zero 0x20007E0C (MVA, OF-09) ----
    ldrb r0, [r0, #0]                  @ 0x08008182
    cmp r0, #0                         @ 0x08008184
    bne .L0800819C                     @ 0x08008186
    ldr r0, =v_20007D64                @ 0x08008188 pool 0x080087C8 = 0x20007D64
    ldr r0, [r0, #0]                   @ 0x0800818C
    ldr r1, =v_20007E0C                @ 0x0800818E pool 0x08008B64 = 0x20007E0C
    ldr r1, [r1, #0]                   @ 0x08008192
    subs r0, r0, r1                    @ 0x08008194  D - user zero
    ldr r1, =v_20007D64                @ 0x08008196 pool 0x080087C8 = 0x20007D64
    str r0, [r1, #0]                   @ 0x0800819A
.L0800819C:                              @ reached from 0x08008186 bne
    movs r0, #1                        @ 0x0800819C
    ldr r1, =v_2000805D                @ 0x0800819E pool 0x080087EC = 0x2000805D
    strb r0, [r1, #0]                  @ 0x080081A2
.L080081A4:                              @ reached from 0x08008144 beq
    bl fn_080064D6                     @ 0x080081A4
    ldr r0, =meter_mode                @ 0x080081A8 pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081AC
    cmp r0, #16                        @ 0x080081AE
    beq .L080081E4                     @ 0x080081B0
    ldr r0, =meter_mode                @ 0x080081B2 pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081B6
    cmp r0, #18                        @ 0x080081B8
    beq .L080081E4                     @ 0x080081BA
    ldr r0, =meter_mode                @ 0x080081BC pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081C0
    cmp r0, #20                        @ 0x080081C2
    beq .L080081E4                     @ 0x080081C4
    ldr r0, =meter_mode                @ 0x080081C6 pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081CA
    cmp r0, #17                        @ 0x080081CC
    beq .L080081E4                     @ 0x080081CE
    ldr r0, =meter_mode                @ 0x080081D0 pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081D4
    cmp r0, #19                        @ 0x080081D6
    beq .L080081E4                     @ 0x080081D8
    ldr r0, =meter_mode                @ 0x080081DA pool 0x08008B5C = 0x2000803C
    ldrb r0, [r0, #0]                  @ 0x080081DE
    cmp r0, #21                        @ 0x080081E0
    bne .L080081F6                     @ 0x080081E2
.L080081E4:                              @ reached from 0x080081B0 beq, 0x080081BA beq, 0x080081C4 beq, 0x080081CE beq, 0x080081D8 beq
    @ ---- sub-display page 10 (0x20008037): request a redraw (0x20008062) ----
    ldr r0, =v_20008037                @ 0x080081E4 pool 0x08008B58 = 0x20008037
    ldrb r0, [r0, #0]                  @ 0x080081E8
    cmp r0, #10                        @ 0x080081EA
    bne .L080081F6                     @ 0x080081EC
    movs r0, #1                        @ 0x080081EE
    ldr r1, =v_20008062                @ 0x080081F0 pool 0x08008E58 = 0x20008062
    strb r0, [r1, #0]                  @ 0x080081F4
.L080081F6:                              @ reached from 0x080081E2 bne, 0x080081EC bne
    pop {r4, pc}                       @ 0x080081F6
    .ltorg
ENDFUNC fn_08008138


@ -----------------------------------------------------------------------------
@ Port RAM of module MDC
@ -----------------------------------------------------------------------------
    .section .bss_port.mdc, "aw", %nobits
    .balign 4
    .global mdc_acdc_dc_state
mdc_acdc_dc_state: .space MDC_SMOOTH_STATE_BYTES   @ OF-28: func_smooth_hist state of the AC+DC DC phase (mode 2)
