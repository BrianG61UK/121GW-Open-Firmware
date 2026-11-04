@ =============================================================================
@ acdc.s - MAC module: ACV with DC component (AC+DC), dBm value
@
@ AC+DC (acdc_active = 1, mode 2) alternates two phases: 5 means of the AC row (acdc_dc_phase = 0), then 3
@ means of the DC row (acdc_dc_phase = 1).  At the end of a phase fn_0800A608 stores the phase value and
@ re-applies the configuration row and calibration record of the next phase; at the end of the DC phase the
@ two values are combined as sqrt(AC^2 + DC^2) and published.  Spec: analysis/hy3131_modes_ac_current.md 7.4.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"

    .section .text.mac, "ax", %progbits

@ -----------------------------------------------------------------------------
@ fn_0800A5BC (mac_acdc_phase_count) - AC+DC phase mean counter: count a mean of the current phase and end the phase after 5 AC / 3 DC means
@ Replaces : 0x0800A5BC FUN_0800a5bc (v2.05)
@ In       : r0 = current phase (0 = AC, 1 = DC)
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080076BC)
@ Registers: r4 = phase argument
@ RAM      : reads  0x200080BE acdc_count
@            writes 0x200080BE acdc_count
@ Spec     : analysis/hy3131_modes_ac_current.md 7.4
@ Deviation: none
@ -----------------------------------------------------------------------------
FUNC fn_0800A5BC
    push {r4, lr}                        @ 0800A5BC
    movs r4, r0                          @ 0800A5BE
    @ AC phase: 5th mean ends it and starts the DC phase (fn_0800A608(1))
    uxtb r4, r4                          @ 0800A5C0
    cmp r4, #0                           @ 0800A5C2
    bne .Lmac_acdc_phase_count_dc        @ 0800A5C4  if phase != 0
    ldr r0, =v_200080BE                  @ 0800A5C6
    ldrb r0, [r0]                        @ 0800A5CA  r0 = acdc_count (u8)
    adds r0, r0, #1                      @ 0800A5CC  r0 = acdc_count + 1
    ldr r1, =v_200080BE                  @ 0800A5CE
    strb r0, [r1]                        @ 0800A5D2  acdc_count (u8) = (acdc_count + 1)
    ldr r0, =v_200080BE                  @ 0800A5D4
    ldrb r0, [r0]                        @ 0800A5D8  r0 = acdc_count (u8)
    cmp r0, #5                           @ 0800A5DA
    blt .Lmac_acdc_phase_count_exit      @ 0800A5DC  if acdc_count < (signed) 5
    movs r0, #1                          @ 0800A5DE
    bl fn_0800A608                       @ 0800A5E0  MAC: AC+DC phase end
    b .Lmac_acdc_phase_count_exit        @ 0800A5E4
.Lmac_acdc_phase_count_dc:   @ DC phase
    @ DC phase: 3rd mean ends it, publishes the combined value and starts the AC phase (fn_0800A608(0))
    ldr r0, =v_200080BE                  @ 0800A5E6
    ldrb r0, [r0]                        @ 0800A5EA  r0 = acdc_count (u8)
    adds r0, r0, #1                      @ 0800A5EC  r0 = acdc_count + 1
    ldr r1, =v_200080BE                  @ 0800A5EE
    strb r0, [r1]                        @ 0800A5F2  acdc_count (u8) = (acdc_count + 1)
    ldr r0, =v_200080BE                  @ 0800A5F4
    ldrb r0, [r0]                        @ 0800A5F8  r0 = acdc_count (u8)
    cmp r0, #3                           @ 0800A5FA
    blt .Lmac_acdc_phase_count_exit      @ 0800A5FC  if acdc_count < (signed) 3
    movs r0, #0                          @ 0800A5FE
    bl fn_0800A608                       @ 0800A600  MAC: AC+DC phase end
.Lmac_acdc_phase_count_exit:   @ return
    pop {r4, pc}                         @ 0800A604
    .ltorg
ENDFUNC fn_0800A5BC
    .global mac_acdc_phase_count
    .set mac_acdc_phase_count, fn_0800A5BC

@ -----------------------------------------------------------------------------
@ fn_0800A608 (mac_acdc_phase_end) - end of an AC+DC phase: store the phase value, start the next phase (row and record), and at the end of
@   the DC phase combine, smooth and publish the reading
@ Replaces : 0x0800A608 FUN_0800a608 (v2.05)
@ In       : r0 = next phase (1 = DC phase follows, 0 = AC phase follows)
@ Out      : -
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800A5BC)
@ Registers: r4 = next phase
@ RAM      : reads  0x20007D64 reading, 0x2000803C meter_mode, 0x2000803D meter_range
@            writes 0x20007D64 reading, 0x20007D68 sample_value, 0x20007E9C acdc_ac, 0x20007EA0 acdc_dc,
@            0x2000805D new_reading, 0x2000805E bargraph_update, 0x200080BB, 0x200080BC, 0x200080BD acdc_dc_phase,
@            0x200080BE acdc_count
@ Spec     : analysis/hy3131_modes_ac_current.md 7.4
@ Deviation: OF-28 (own smoothing history for the combined value)
@ -----------------------------------------------------------------------------
FUNC fn_0800A608
    push {r4, lr}                        @ 0800A608
    movs r4, r0                          @ 0800A60A
    @ mean counter = 0; acdc_dc_phase = next phase
    movs r0, #0                          @ 0800A60C
    ldr r1, =v_200080BE                  @ 0800A60E
    strb r0, [r1]                        @ 0800A612  acdc_count (u8) = 0
    ldr r0, =acdc_use_dcv_cal            @ 0800A614
    strb r4, [r0]                        @ 0800A618  acdc_dc_phase (u8) = next
    @ next phase DC: the AC phase just ended, keep its reading as the AC value
    uxtb r4, r4                          @ 0800A61A
    cmp r4, #1                           @ 0800A61C
    bne .Lmac_acdc_phase_end_dcval       @ 0800A61E  if next != 1
    ldr r0, =v_20007D64                  @ 0800A620
    ldr r0, [r0]                         @ 0800A624  r0 = reading (u32)
    ldr r1, =v_20007E9C                  @ 0800A626
    str r0, [r1]                         @ 0800A62A  acdc_ac (u32) = reading
    movs r0, #1                          @ 0800A62C
    ldr r1, =v_200080BC                  @ 0800A62E
    strb r0, [r1]                        @ 0800A632  v_200080BC (u8) = 1
    b .Lmac_acdc_phase_end_combine       @ 0800A634
.Lmac_acdc_phase_end_dcval:   @ the DC phase ended
    @ next phase AC: the DC phase just ended, keep its reading as the DC value
    ldr r0, =v_20007D64                  @ 0800A636
    ldr r0, [r0]                         @ 0800A63A  r0 = reading (u32)
    ldr r1, =v_20007EA0                  @ 0800A63C
    str r0, [r1]                         @ 0800A640  acdc_dc (u32) = reading
    movs r0, #1                          @ 0800A642
    ldr r1, =v_200080BB                  @ 0800A644
    strb r0, [r1]                        @ 0800A648  v_200080BB (u8) = 1
.Lmac_acdc_phase_end_combine:   @ value stored
    @ DC phase ended: combine, smooth (threshold 20, depth 10), publish, per-sample value = reading
    uxtb r4, r4                          @ 0800A64A
    cmp r4, #0                           @ 0800A64C
    bne .Lmac_acdc_phase_end_apply       @ 0800A64E  if next != 0
    bl fn_0800A6A8                       @ 0800A650  MAC: AC+DC combine
    movs r2, #0xa                        @ 0800A654
    movs r1, #0x14                       @ 0800A656  = 20
    ldr r0, =v_20007D64                  @ 0800A658
    ldr r0, [r0]                         @ 0800A65C  r0 = reading (u32)
    @ ---- v2.05 0x0800A65E replaced (see Deviation in the header) ----
    ldr r3, =func_st_acdc_sum                @ OF-28: the combined value has its own history (r0 = D, r1 = 20, r2 = 10)
    bl func_smooth_hist
    ldr r1, =v_20007D64                  @ 0800A662
    str r0, [r1]                         @ 0800A666  reading (u32) = r0
    movs r0, #1                          @ 0800A668
    ldr r1, =v_2000805D                  @ 0800A66A
    strb r0, [r1]                        @ 0800A66E  new_reading (u8) = 1
    movs r0, #1                          @ 0800A670
    ldr r1, =v_2000805E                  @ 0800A672
    strb r0, [r1]                        @ 0800A676  bargraph_update (u8) = 1
    ldr r0, =v_20007D64                  @ 0800A678
    ldr r0, [r0]                         @ 0800A67C  r0 = reading (u32)
    ldr r1, =v_20007D68                  @ 0800A67E
    str r0, [r1]                         @ 0800A682  sample_value (u32) = reading
.Lmac_acdc_phase_end_apply:   @ apply the new phase
    @ configuration row and calibration record of the new phase
    ldr r0, =meter_range                 @ 0800A684
    ldrb r1, [r0]                        @ 0800A688  r1 = meter_range (u8)
    ldr r0, =meter_mode                  @ 0800A68A
    ldrb r0, [r0]                        @ 0800A68E  r0 = meter_mode (u8)
    bl fn_0800B974                       @ 0800A690  HY: write the configuration row and INTE for (mode r0, range r1)
    ldr r0, =meter_range                 @ 0800A694
    ldrb r1, [r0]                        @ 0800A698  r1 = meter_range (u8)
    ldr r0, =meter_mode                  @ 0800A69A
    ldrb r0, [r0]                        @ 0800A69E  r0 = meter_mode (u8)
    bl load_cal_record_from_eeprom       @ 0800A6A0
    pop {r4, pc}                         @ 0800A6A4
    .ltorg
ENDFUNC fn_0800A608
    .global mac_acdc_phase_end
    .set mac_acdc_phase_end, fn_0800A608

@ -----------------------------------------------------------------------------
@ fn_0800A6A8 (mac_acdc_combine) - combine the AC and DC values of AC+DC: reading = sqrt(|AC|^2 + |DC|^2), 100000 when a component is >= 60001
@ Replaces : 0x0800A6A8 FUN_0800a6a8 (v2.05)
@ In       : -
@ Out      : reading (0x20007D64)
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_0800A608)
@ RAM      : reads  0x20007E9C acdc_ac, 0x20007EA0 acdc_dc; writes 0x20007E9C, 0x20007EA0 (absolute values),
@            0x20007EA4 acdc_ac_sq, 0x20007EA8 acdc_dc_sq (low words of the squares, as v2.05 left them), 0x20007D64 reading
@ Spec     : analysis/hy3131_modes_ac_current.md 7.4; ORIGINAL_FIRMWARE_ISSUES.md OF-25
@ Deviation: OF-25 (64-bit sum of squares), components compared as unsigned (the absolute value of INT_MIN is not treated as small)
@ -----------------------------------------------------------------------------
FUNC fn_0800A6A8
    @ ---- v2.05 0x0800A6A8 replaced (see Deviation in the header) ----
    push {r4, lr}                           @ r4 holds the high word of the sum across the helper calls
    @ |AC| and |DC| in place
    ldr r0, =v_20007E9C                  @ 0800A6AA
    ldr r0, [r0]                         @ 0800A6AE  r0 = acdc_ac (u32)
    cmp r0, #0                           @ 0800A6B0
    bpl .Lmac_acdc_combine_0800A6C2      @ 0800A6B2  if acdc_ac >= 0
    ldr r0, =v_20007E9C                  @ 0800A6B4
    ldr r0, [r0]                         @ 0800A6B8  r0 = acdc_ac (u32)
    rsbs r0, r0, #0                      @ 0800A6BA  r0 = -acdc_ac
    ldr r1, =v_20007E9C                  @ 0800A6BC
    str r0, [r1]                         @ 0800A6C0  acdc_ac (u32) = -acdc_ac
.Lmac_acdc_combine_0800A6C2:   @ branch target from 0800A6B2
    ldr r0, =v_20007EA0                  @ 0800A6C2
    ldr r0, [r0]                         @ 0800A6C6  r0 = acdc_dc (u32)
    cmp r0, #0                           @ 0800A6C8
    bpl .Lmac_acdc_combine_0800A6DA      @ 0800A6CA  if acdc_dc >= 0
    ldr r0, =v_20007EA0                  @ 0800A6CC
    ldr r0, [r0]                         @ 0800A6D0  r0 = acdc_dc (u32)
    rsbs r0, r0, #0                      @ 0800A6D2  r0 = -acdc_dc
    ldr r1, =v_20007EA0                  @ 0800A6D4
    str r0, [r1]                         @ 0800A6D8  acdc_dc (u32) = -acdc_dc
.Lmac_acdc_combine_0800A6DA:   @ branch target from 0800A6CA
    @ either component >= 60001 (unsigned): overload value 100000
    ldr r0, =v_20007E9C                  @ 0800A6DA
    ldr r0, [r0]                         @ 0800A6DE  r0 = acdc_ac (u32)
    movw r1, #0xea61                     @ 0800A6E0  = 60001
    cmp r0, r1                           @ 0800A6E4
    @ ---- v2.05 0x0800A6E6 replaced (see Deviation in the header) ----
    bhs .Lmac_acdc_combine_over         @ unsigned: abs(INT_MIN) = INT_MIN counts as large (v2.05 used a signed branch)
    ldr r0, =v_20007EA0                  @ 0800A6E8
    ldr r0, [r0]                         @ 0800A6EC  r0 = acdc_dc (u32)
    movw r1, #0xea61                     @ 0800A6EE  = 60001
    cmp r0, r1                           @ 0800A6F2
    @ ---- v2.05 0x0800A6F4 replaced (see Deviation in the header) ----
    blo .Lmac_acdc_combine_square         @ both components below 60001 (unsigned)
.Lmac_acdc_combine_over:   @ a component is too large: reading = 100000
    ldr r0, =0x000186A0                  @ 0800A6F6
    ldr r1, =v_20007D64                  @ 0800A6FA
    str r0, [r1]                         @ 0800A6FE  reading (u32) = 100000
    b .Lmac_acdc_combine_exit            @ 0800A700
.Lmac_acdc_combine_square:   @ squares
    @ both below 60001: the sum of squares is below 7.2e9, a 33-bit value; v2.05 formed it with 32-bit muls/adds
    @ ---- v2.05 0x0800A702..0x0800A740 replaced (see Deviation in the header) ----
    ldr r2, =v_20007E9C
    ldr r2, [r2]                            @ a = |AC|
    umull r0, r1, r2, r2                    @ OF-25: r1:r0 = a * a (64 bit)
    ldr r3, =v_20007EA4
    str r0, [r3]                            @ acdc_ac_sq: low word, as in v2.05
    ldr r2, =v_20007EA0
    ldr r2, [r2]                            @ b = |DC|
    umull r2, r3, r2, r2                    @ r3:r2 = b * b
    ldr r12, =v_20007EA8
    str r2, [r12]                           @ acdc_dc_sq: low word, as in v2.05
    adds r0, r0, r2                         @ low word of a*a + b*b
    adc r4, r1, r3                          @ r4 = high word (0 or 1)
    bl fn_08013ED8                          @ RT: double r0:r1 = (double)(uint32) low word
    cbz r4, 1f
    movs r2, #0
    ldr r3, =0x41F00000                     @ 2^32 as double (0x41F00000:00000000)
    bl fn_080131B8                          @ RT: double r0:r1 = r0:r1 + 2^32
1:  bl fn_08013EF4                          @ RT: double r0:r1 = sqrt(r0:r1)
    bl fn_080132A0                          @ RT: int32 r0 = (int)double r0:r1
    ldr r1, =v_20007D64                  @ 0800A744
    str r0, [r1]                         @ 0800A748  reading (u32) = r0
.Lmac_acdc_combine_exit:   @ return
    @ ---- v2.05 0x0800A74A replaced (see Deviation in the header) ----
    pop {r4, pc}
    .ltorg
ENDFUNC fn_0800A6A8
    .global mac_acdc_combine
    .set mac_acdc_combine, fn_0800A6A8

@ -----------------------------------------------------------------------------
@ fn_0800A74C (mac_dbm) - dBm value of the AC reading for the secondary display: 10 * log10(x * x / 0.6) with x = reading / 10^(4 - range)
@ Replaces : 0x0800A74C FUN_0800a74c (v2.05)
@ In       : -
@ Out      : dbm (0x20007E94) as float32; reading unchanged
@ Clobbers : r0, r1, r2, r3, r12, flags
@ Context  : main only (fn_080076BC)
@ Registers: r4 = x (float32), r5 = scratch
@ RAM      : reads  0x20007D64 reading, 0x2000803D meter_range
@            writes 0x20007E94 dbm
@ Spec     : analysis/hy3131_modes_ac_current.md 4 notes; ORIGINAL_FIRMWARE_ISSUES.md OF-04
@ Deviation: OF-04 (x = 1.0 when meter_range > 3, where v2.05 used an unset register); IMP-08 (production: the divisor 0.6
@            is the entry of set_dbm_ref in set_dbm_divisor, set/dbm.s)
@ -----------------------------------------------------------------------------
FUNC fn_0800A74C
    push {r3, r4, r5, lr}                @ 0800A74C
    ldr r4, =0x3F800000                     @ OF-04: x = 1.0f for a range above 3 (v2.05 left r4 unset on that path)
    @ x (r4) = reading as float32 divided by 10000 / 1000 / 100 / 10 for range 0 / 1 / 2 / 3
    ldr r0, =meter_range                 @ 0800A74E
    ldrb r0, [r0]                        @ 0800A752  r0 = meter_range (u8)
    cmp r0, #0                           @ 0800A754
    beq .Lmac_dbm_0800A764               @ 0800A756  if meter_range == 0
    cmp r0, #2                           @ 0800A758
    beq .Lmac_dbm_0800A790               @ 0800A75A  if meter_range == 2
    blo .Lmac_dbm_0800A77A               @ 0800A75C  if meter_range < (unsigned) 2
    cmp r0, #3                           @ 0800A75E
    beq .Lmac_dbm_0800A7A6               @ 0800A760  if meter_range == 3
    b .Lmac_dbm_square                   @ 0800A762
.Lmac_dbm_0800A764:   @ branch target from 0800A756
    ldr r0, =v_20007D64                  @ 0800A764
    ldr r0, [r0]                         @ 0800A768  r0 = reading (u32)
    bl fn_08012F60                       @ 0800A76A  RT: float32 = (int32)r0
    ldr r1, =0x461C4000                  @ 0800A76E  0x461C4000 = 10000.0f (range 0)
    bl fn_08012F94                       @ 0800A772  RT: float32 r0 = r0 / r1
    movs r4, r0                          @ 0800A776
    b .Lmac_dbm_square                   @ 0800A778
.Lmac_dbm_0800A77A:   @ branch target from 0800A75C
    ldr r0, =v_20007D64                  @ 0800A77A
    ldr r0, [r0]                         @ 0800A77E  r0 = reading (u32)
    bl fn_08012F60                       @ 0800A780  RT: float32 = (int32)r0
    ldr r1, =0x447A0000                  @ 0800A784  0x447A0000 = 1000.0f (range 1)
    bl fn_08012F94                       @ 0800A788  RT: float32 r0 = r0 / r1
    movs r4, r0                          @ 0800A78C
    b .Lmac_dbm_square                   @ 0800A78E
.Lmac_dbm_0800A790:   @ branch target from 0800A75A
    ldr r0, =v_20007D64                  @ 0800A790
    ldr r0, [r0]                         @ 0800A794  r0 = reading (u32)
    bl fn_08012F60                       @ 0800A796  RT: float32 = (int32)r0
    ldr r1, =0x42C80000                  @ 0800A79A  0x42C80000 = 100.0f (range 2)
    bl fn_08012F94                       @ 0800A79E  RT: float32 r0 = r0 / r1
    movs r4, r0                          @ 0800A7A2
    b .Lmac_dbm_square                   @ 0800A7A4
.Lmac_dbm_0800A7A6:   @ branch target from 0800A760
    ldr r0, =v_20007D64                  @ 0800A7A6
    ldr r0, [r0]                         @ 0800A7AA  r0 = reading (u32)
    bl fn_08012F60                       @ 0800A7AC  RT: float32 = (int32)r0
    ldr r1, =0x41200000                  @ 0800A7B0  0x41200000 = 10.0f (range 3)
    bl fn_08012F94                       @ 0800A7B4  RT: float32 r0 = r0 / r1
    movs r4, r0                          @ 0800A7B8
.Lmac_dbm_square:   @ x known
    @ x * x, as double
    movs r0, r4                          @ 0800A7BA
    movs r1, r4                          @ 0800A7BC
    bl fn_08013090                       @ 0800A7BE  RT: float32 r0 = r0 * r1
    @ divided by 0.6 (0x3FE3333333333333)
    bl fn_08013168                       @ 0800A7C2  RT: double r0:r1 = (double)float32 r0
    @ IMP-08: divisor of the selected reference (0.6 / 0.05 / 0.075 / 1.0; code 0 is the v2.05 constant, FEATURES.md 2.2)
    ldr r2, =set_dbm_ref
    ldrb r2, [r2]                        @ r2 = reference code (0..3, set_dbm_load and set_dbm_edit keep it in range)
    and r2, r2, #3                       @ index inside the 4-entry table
    ldr r3, =set_dbm_divisor
    add r3, r3, r2, lsl #3               @ 8 bytes per double
    ldrd r2, r3, [r3]                    @ r2:r3 = divisor (low word, high word)
    bl fn_0801B874                       @ 0800A7CE  RT: double r0:r1 = r0:r1 / r2:r3
    @ rounded to float32, back to double, log10, times 10.0 (0x40240000:0), to float32
    bl fn_0801BACC                       @ 0800A7D2  RT: float32 r0 = (float)double r0:r1
    movs r5, r0                          @ 0800A7D6
    movs r0, r5                          @ 0800A7D8
    bl fn_08013168                       @ 0800A7DA  RT: double r0:r1 = (double)float32 r0
    bl fn_0801BB5C                       @ 0800A7DE  RT: double r0:r1 = log10(r0:r1)
    movs r2, #0                          @ 0800A7E2
    ldr r3, =0x40240000                  @ 0800A7E4  0x40240000:0 = 10.0 (double)
    bl fn_0801BB64                       @ 0800A7E8  RT: double r0:r1 = r0:r1 * r2:r3
    bl fn_0801BACC                       @ 0800A7EC  RT: float32 r0 = (float)double r0:r1
    ldr r1, =v_20007E94                  @ 0800A7F0
    str r0, [r1]                         @ 0800A7F4  dbm (u32) = r0
    pop {r0, r4, r5, pc}                 @ 0800A7F6
    .ltorg
ENDFUNC fn_0800A74C
    .global mac_dbm
    .set mac_dbm, fn_0800A74C

