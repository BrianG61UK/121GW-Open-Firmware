@ =============================================================================
@ bl_ble.s - Bluetooth link of the bootloader and the update protocol (bootloader/DESIGN.md 5 items 4 and 8, 6.3, 6.5)
@
@ Link: the BLE module (BLE112) is supplied through PF15 and talks over USART2 (PD5 TX, PD6 RX, AF7), 19200 baud 8N1,
@ as in the firmware (firmware/src/ble/usart.s usart2_init_19200_pf15_high: PF15 high before PD5/PD6 become AF7).  The
@ bootloader runs on MSI 4.194 MHz while the link is open, so the baud divider is the firmware's (bl.inc).  Received
@ bytes go to a ring through the USART2 interrupt; the handler and the vector table are in RAM while the link is open,
@ so the interrupt is taken while a flash operation runs (bl_flash.s).  Answers are sent by polling.
@
@ Protocol (packets as the firmware's ble/bft.s): B5 5B type seq(2) len(1) payload(<= 232) crc16(2), CRC-16/CCITT-FALSE
@ over type..payload; answer B5 5B 81 seq(2) 03 status next(2) crc16(2).  The sender may have two packets in flight:
@ every packet is answered once it is handled, in order.
@   1 START   size(4) crc32(4) kind(1) [version(4)]: kind 0 firmware (0x124..0x4C000 bytes, programmed at 0x08006000),
@             kind 2 bootloader image (1..0x5B00 bytes, into the slot not holding the running bootloader); the target
@             is erased first (the firmware mark first of all), so the answer comes after the erase
@   2 DATA    seq = packet number from 0; the bytes are programmed in half-pages as they arrive
@   3 END     all bytes sent: the flash is checked against the CRC-32; firmware: image check, firmware mark; bootloader:
@             slot header, INSTALL record; the meter restarts half a second after the answer
@   4 ABORT   back to waiting (an erased firmware stays without mark: the bootloader stays in update mode)
@   5 STATUS  payload index(1): 0 bootloader version (major << 8 | minor), 1 state, 2 bytes received / 256
@ Status: 0 accepted, 1 CRC wrong, 2 not the expected packet (next = expected), 3 not allowed now, 4 START refused,
@         5 bytes beyond the size, 0x10 + n END failed: n = 2 length or CRC-32 wrong, 3 not a firmware image,
@         6 flash write or check failed.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "bl.inc"

    .equ RING_LEN,          1024            @ power of two: four full packets
    .equ MAXPAY,            232
    .equ ST_WAIT,           0
    .equ ST_RECV,           1
    .equ ST_DONE,           2
    .equ KIND_FW,           0
    .equ KIND_BL,           2
    .equ GAP_TICKS,         20              @ 200 ms without a byte drops a packet being assembled
    .equ APB1_USART2,       0x00020000      @ RCC_APB1ENR bit 17
    .equ AHB_GPIOD,         0x00000008
    .equ NVIC_ISER1,        0xE000E104
    .equ NVIC_ICER1,        0xE000E184
    .equ IRQ38_BIT,         0x00000040      @ IRQ 38 = bit 6 of the second ISER / ICER word
    .equ CR1_ON,            0x0000202C      @ UE | RXNEIE | TE | RE (RM0038 26.6.4)
    .equ SR_RXNE,           0x20
    .equ SR_TXE,            0x80
    .equ SR_TC,             0x40
    .equ VEC_WORDS,         73

    .section .bss.bl_ble, "aw", %nobits
    .balign 4
    .global bl_ble_activity
bl_ring:        .space RING_LEN
bl_pkt:         .space 8 + MAXPAY
bl_stage:       .space 384                  @ bytes waiting for their half-page: < 128 left + 232 of a packet
bl_ans:         .space 12
bl_size:        .space 4
bl_crc:         .space 4
bl_recv:        .space 4
bl_dest0:       .space 4                    @ first address of the image
bl_dest:        .space 4                    @ next half-page to program
bl_slot:        .space 4                    @ slot of a bootloader image
bl_ble_activity: .space 4                   @ ticks of the last received packet (bl_main.s timeouts)
bl_rx_head:     .space 2                    @ written by the interrupt
bl_rx_tail:     .space 2
bl_pos:         .space 2
bl_seq:         .space 2
bl_staged:      .space 2
bl_state:       .space 1
bl_kind:        .space 1
    .global bl_reset_due
bl_reset_due:   .space 1                    @ 1: restart (bl_main.s) once the answer is out

    .section .ramvec, "aw", %nobits         @ vector table in RAM while the link is open (512-byte boundary)
    .balign 512
bl_ram_vectors: .space VEC_WORDS * 4

    .section .text.bl_ble, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_ble_on - BLE module on, USART2 at 19200 baud, receive interrupt from the RAM vector table
@ Clobbers : r0-r3, r12, flags
@ -----------------------------------------------------------------------------
FUNC bl_ble_on
    push {r4, lr}
    ldr r0, =(GPIOF_BASE + GPIO_BSRRL)
    mov r1, #0x8000
    strh r1, [r0]                           @ PF15 high: BLE module supply (before PD5/PD6 become AF7)
    ldr r0, =RCC_AHBENR
    ldr r1, [r0]
    orr r1, r1, #AHB_GPIOD
    str r1, [r0]
    ldr r0, =GPIOD_BASE
    ldr r1, =bl_desc_usart
    bl brd_gpio_init                        @ PD5 TX, PD6 RX: AF7, pull-up (as the firmware)
    ldr r0, =RCC_APB1ENR
    ldr r1, [r0]
    orr r1, r1, #APB1_USART2
    str r1, [r0]
    movs r0, #0
    ldr r1, =bl_rx_head
    strh r0, [r1]
    ldr r1, =bl_rx_tail
    strh r0, [r1]
    ldr r1, =bl_pos
    strh r0, [r1]
    ldr r1, =bl_state
    strb r0, [r1]
    @ vector table to RAM: every entry from the flash table, USART2 (exception 54) to the RAM handler
    ldr r0, =bl_vectors
    ldr r1, =bl_ram_vectors
    movs r2, #VEC_WORDS
1:  ldr r3, [r0], #4
    str r3, [r1], #4
    subs r2, r2, #1
    bne 1b
    ldr r1, =bl_ram_vectors
    ldr r0, =bl_usart_isr
    str r0, [r1, #(54 * 4)]
    dsb
    ldr r0, =SCB_VTOR
    str r1, [r0]
    dsb
    isb
    ldr r4, =USART2_BASE_BL
    movs r0, #USART_BRR_19200
    str r0, [r4, #USART_BRR]
    ldr r0, =CR1_ON
    str r0, [r4, #USART_CR1]
    ldr r0, =NVIC_ISER1
    movs r1, #IRQ38_BIT
    str r1, [r0]
    pop {r4, pc}
ENDFUNC bl_ble_on

@ -----------------------------------------------------------------------------
@ bl_ble_off - USART2 and its interrupt off, the flash vector table again, BLE module supply off (PF15 low)
@ Clobbers : r0-r3, flags
@ -----------------------------------------------------------------------------
FUNC bl_ble_off
    ldr r0, =NVIC_ICER1
    movs r1, #IRQ38_BIT
    str r1, [r0]
    ldr r0, =USART2_BASE_BL
    movs r1, #0
    str r1, [r0, #USART_CR1]
    ldr r0, =SCB_VTOR
    ldr r1, =BL_BASE
    str r1, [r0]
    dsb
    isb
    ldr r0, =(GPIOF_BASE + GPIO_BSRRH)
    mov r1, #0x8000
    strh r1, [r0]
    bx lr
ENDFUNC bl_ble_off

@ -----------------------------------------------------------------------------
@ bl_ble_send - send r1 bytes from r0, polled (TXE before each byte, TC at the end)
@ Clobbers : r0-r3, flags
@ -----------------------------------------------------------------------------
LFUNC bl_ble_send
    ldr r2, =USART2_BASE_BL
1:  ldr r3, [r2, #USART_SR]
    tst r3, #SR_TXE
    beq 1b
    ldrb r3, [r0], #1
    str r3, [r2, #USART_DR]
    subs r1, r1, #1
    bne 1b
2:  ldr r3, [r2, #USART_SR]
    tst r3, #SR_TC
    beq 2b
    bx lr
ENDFUNC bl_ble_send

@ -----------------------------------------------------------------------------
@ bl_crc16 - CRC-16/CCITT-FALSE of r1 bytes at r0; Out r0; clobbers r1-r3, r12
@ -----------------------------------------------------------------------------
LFUNC bl_crc16
    movw r2, #0xFFFF
    movw r12, #0x1021
1:  cbz r1, 4f
    ldrb r3, [r0], #1
    eor r2, r2, r3, lsl #8
    movs r3, #8
2:  lsls r2, r2, #1
    tst r2, #0x10000
    it ne
    eorne r2, r2, r12
    subs r3, r3, #1
    bne 2b
    uxth r2, r2
    subs r1, r1, #1
    b 1b
4:  mov r0, r2
    bx lr
ENDFUNC bl_crc16

@ -----------------------------------------------------------------------------
@ bl_answer - answer the packet in bl_pkt: r0 = status, r1 = next
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_answer
    push {r4, lr}
    ldr r4, =bl_ans
    movs r2, #0xB5
    strb r2, [r4, #0]
    movs r2, #0x5B
    strb r2, [r4, #1]
    movs r2, #0x81
    strb r2, [r4, #2]
    ldr r2, =bl_pkt
    ldrb r3, [r2, #3]
    strb r3, [r4, #3]
    ldrb r3, [r2, #4]
    strb r3, [r4, #4]
    movs r2, #3
    strb r2, [r4, #5]
    strb r0, [r4, #6]
    strb r1, [r4, #7]
    lsrs r1, r1, #8
    strb r1, [r4, #8]
    adds r0, r4, #2
    movs r1, #7
    bl bl_crc16
    strb r0, [r4, #9]
    lsrs r0, r0, #8
    strb r0, [r4, #10]
    mov r0, r4
    movs r1, #11
    bl bl_ble_send
    pop {r4, pc}
ENDFUNC bl_answer

@ bl_le32 - little-endian u32 at r0 (any alignment); clobbers r1, r2
LFUNC bl_le32
    ldrb r1, [r0, #3]
    ldrb r2, [r0, #2]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #1]
    orr r1, r2, r1, lsl #8
    ldrb r2, [r0, #0]
    orr r0, r2, r1, lsl #8
    bx lr
ENDFUNC bl_le32

@ -----------------------------------------------------------------------------
@ bl_ble_poll - assemble packets from the ring; handle one complete packet per call
@ In       : r0 = 10 ms tick count (bl_main.s)
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
FUNC bl_ble_poll
    push {r4-r7, lr}
    mov r7, r0                              @ r7 = now (ticks)
    ldr r6, =bl_pkt
    ldr r0, =bl_pos                         @ a packet cut short is dropped after GAP_TICKS without a byte
    ldrh r1, [r0]
    cbz r1, 1f
    ldr r2, =bl_last_byte
    ldr r2, [r2]
    subs r2, r7, r2
    cmp r2, #GAP_TICKS
    blo 1f
    movs r1, #0
    strh r1, [r0]
1:  ldr r1, =bl_rx_tail
    ldrh r2, [r1]
    ldr r0, =bl_rx_head
    ldrh r0, [r0]
    cmp r0, r2
    beq 9f                                  @ ring empty
    ldr r0, =bl_ring
    ldrb r3, [r0, r2]
    adds r2, r2, #1
    bfc r2, #10, #22
    strh r2, [r1]
    ldr r0, =bl_last_byte
    str r7, [r0]
    ldr r1, =bl_pos
    ldrh r5, [r1]
    cbnz r5, 2f
    cmp r3, #0xB5
    bne 1b
    strb r3, [r6, #0]
    movs r5, #1
    b 8f
2:  cmp r5, #1
    bne 3f
    cmp r3, #0x5B
    beq 21f
    cmp r3, #0xB5
    ite eq
    moveq r5, #1
    movne r5, #0
    b 8f
21: strb r3, [r6, #1]
    movs r5, #2
    b 8f
3:  strb r3, [r6, r5]
    adds r5, r5, #1
    cmp r5, #6
    blo 8f
    ldrb r0, [r6, #5]
    cmp r0, #MAXPAY
    bls 4f
    movs r5, #0
    b 8f
4:  adds r0, r0, #8
    cmp r5, r0
    blo 8f
    movs r0, #0                             @ complete
    strh r0, [r1]
    ldr r0, =bl_ble_activity
    str r7, [r0]
    ldrb r4, [r6, #5]
    adds r0, r6, #2
    adds r1, r4, #4
    bl bl_crc16
    adds r4, r4, #6
    ldrb r1, [r6, r4]
    adds r4, r4, #1
    ldrb r2, [r6, r4]
    orr r1, r1, r2, lsl #8
    cmp r0, r1
    beq 5f
    movs r0, #1                             @ CRC wrong: resend
    movs r1, #0
    bl bl_answer
    b 9f
5:  bl bl_packet
    b 9f
8:  ldr r1, =bl_pos
    strh r5, [r1]
    b 1b
9:  pop {r4-r7, pc}
ENDFUNC bl_ble_poll

@ -----------------------------------------------------------------------------
@ bl_packet - handle the complete packet in bl_pkt
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_packet
    push {r4-r7, lr}
    ldr r4, =bl_pkt
    ldrb r0, [r4, #2]
    cmp r0, #1
    beq .Lp_start
    cmp r0, #2
    beq .Lp_data
    cmp r0, #3
    beq .Lp_end
    cmp r0, #4
    beq .Lp_abort
    cmp r0, #5
    beq .Lp_status
.Lp_notallowed:
    movs r0, #3
    movs r1, #0
    b .Lp_answer
.Lp_status:
    ldrb r0, [r4, #5]
    cmp r0, #1
    bne .Lp_notallowed
    ldrb r0, [r4, #6]
    cmp r0, #0
    bne 1f
    ldr r1, =((BL_VERSION >> 8) & 0xFFFF)
    b 3f
1:  cmp r0, #1
    bne 2f
    ldr r1, =bl_state
    ldrb r1, [r1]
    b 3f
2:  ldr r1, =bl_recv
    ldr r1, [r1]
    lsrs r1, r1, #8
3:  movs r0, #0
    b .Lp_answer
.Lp_abort:
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
    movs r1, #0
    b .Lp_answer
.Lp_start:
    ldr r0, =bl_state
    ldrb r0, [r0]
    cmp r0, #ST_DONE
    beq .Lp_notallowed                      @ the restart is due: nothing new
    ldrb r5, [r4, #5]                       @ payload length 9 or 13
    cmp r5, #9
    beq 1f
    cmp r5, #13
    bne .Lp_refuse
1:  adds r0, r4, #6
    bl bl_le32
    mov r6, r0                              @ r6 = size
    adds r0, r4, #10
    bl bl_le32
    ldr r1, =bl_crc
    str r0, [r1]
    movs r0, #0
    cmp r5, #13
    bne 2f
    adds r0, r4, #15
    bl bl_le32
2:  ldr r1, =bl_hdr_ver
    str r0, [r1]
    ldrb r7, [r4, #14]                      @ r7 = kind
    cmp r7, #KIND_FW
    beq .Lp_start_fw
    cmp r7, #KIND_BL
    bne .Lp_refuse
    @ bootloader image into the slot that does not hold the running bootloader
    subs r0, r6, #1
    cmp r0, #BL_MAX
    bhs .Lp_refuse
    bl bl_free_slot
    ldr r1, =bl_slot
    str r0, [r1]
    add r1, r0, #SLOT_SIZE
    bl bl_erase
    cbnz r0, .Lp_refuse_flash
    ldr r0, =bl_slot
    ldr r0, [r0]
    add r0, r0, #SLOT_IMG
    b .Lp_start_go
.Lp_start_fw:
    cmp r6, #0x124
    blo .Lp_refuse
    ldr r0, =APP_MAX
    cmp r6, r0
    bhi .Lp_refuse
    ldr r0, =FW_MARK                        @ the firmware mark first: from now on the bootloader stays in update mode
    add r1, r0, #0x100
    bl bl_erase
    cbnz r0, .Lp_refuse_flash
    ldr r0, =APP_BASE
    add r1, r6, #0xFF
    bic r1, r1, #0xFF
    add r1, r1, r0
    bl bl_erase
    cbnz r0, .Lp_refuse_flash
    ldr r0, =APP_BASE
.Lp_start_go:
    ldr r1, =bl_dest0
    str r0, [r1]
    ldr r1, =bl_dest
    str r0, [r1]
    ldr r1, =bl_size
    str r6, [r1]
    ldr r1, =bl_kind
    strb r7, [r1]
    movs r0, #0
    ldr r1, =bl_recv
    str r0, [r1]
    ldr r1, =bl_seq
    strh r0, [r1]
    ldr r1, =bl_staged
    strh r0, [r1]
    movs r0, #ST_RECV
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #0
    movs r1, #0
    b .Lp_answer
.Lp_refuse_flash:
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
.Lp_refuse:
    movs r0, #4
    movs r1, #0
    b .Lp_answer
.Lp_data:
    ldr r0, =bl_state
    ldrb r0, [r0]
    cmp r0, #ST_RECV
    bne .Lp_notallowed
    ldrb r0, [r4, #3]                       @ seq, little-endian
    ldrb r1, [r4, #4]
    orr r5, r0, r1, lsl #8                  @ r5 = seq
    ldr r2, =bl_seq
    ldrh r6, [r2]                           @ r6 = expected
    cmp r5, r6
    beq 1f
    blo 2f                                  @ an earlier packet again (its answer was lost): accepted, not stored
    movs r0, #2                             @ ahead: name the packet expected
    mov r1, r6
    b .Lp_answer
2:  movs r0, #0
    mov r1, r6
    b .Lp_answer
1:  ldrb r5, [r4, #5]                       @ r5 = payload length
    ldr r0, =bl_recv
    ldr r1, [r0]
    add r1, r1, r5
    ldr r2, =bl_size
    ldr r2, [r2]
    cmp r1, r2
    bls 3f
    movs r0, #5
    mov r1, r6
    b .Lp_answer
3:  str r1, [r0]
    @ payload to the stage, half-pages out
    ldr r7, =bl_staged
    ldrh r0, [r7]
    ldr r1, =bl_stage
    add r1, r1, r0
    adds r2, r4, #6
4:  cbz r5, 5f
    ldrb r3, [r2], #1
    strb r3, [r1], #1
    adds r0, r0, #1
    subs r5, r5, #1
    b 4b
5:  strh r0, [r7]
    bl bl_flush_stage                       @ every full half-page programmed
    cbnz r0, .Lp_flash_fail
    adds r6, r6, #1
    ldr r2, =bl_seq
    strh r6, [r2]
    movs r0, #0
    mov r1, r6
    b .Lp_answer
.Lp_flash_fail:
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #0x16
    movs r1, #0
    b .Lp_answer
.Lp_end:
    ldr r0, =bl_state
    ldrb r0, [r0]
    cmp r0, #ST_DONE
    bne 1f
    movs r0, #0                             @ END again (the answer was lost): done
    movs r1, #0
    b .Lp_answer
1:  cmp r0, #ST_RECV
    bne .Lp_notallowed
    ldr r0, =bl_recv
    ldr r0, [r0]
    ldr r1, =bl_size
    ldr r1, [r1]
    cmp r0, r1
    beq 2f
    movs r0, #2                             @ bytes missing
    ldr r1, =bl_seq
    ldrh r1, [r1]
    b .Lp_answer
2:  bl bl_end_check                         @ r0 = 0 or the END error n
    cbz r0, 3f
    adds r0, r0, #0x10
    movs r1, #ST_WAIT
    ldr r2, =bl_state
    strb r1, [r2]
    movs r1, #0
    b .Lp_answer
3:  movs r0, #ST_DONE
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #1
    ldr r1, =bl_reset_due
    strb r0, [r1]
    movs r0, #0
    movs r1, #0
.Lp_answer:
    bl bl_answer
    pop {r4-r7, pc}
ENDFUNC bl_packet

@ -----------------------------------------------------------------------------
@ bl_flush_stage - program the full half-pages of bl_stage; with r0 = 1 on entry from bl_end_check also the last,
@ partial one (zero padded)
@ Out      : r0 = 0, else non-zero
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_flush_stage
    movs r0, #0
bl_flush_stage_all:                         @ entry with r0 = 1: the partial half-page too
    push {r4-r6, lr}
    mov r6, r0
    ldr r4, =bl_staged
1:  ldrh r5, [r4]
    cmp r5, #128
    bhs 2f
    cbz r6, 8f
    cbz r5, 8f
    ldr r0, =bl_stage                       @ pad the last half-page with zeros
    add r0, r0, r5
    movs r1, #0
3:  strb r1, [r0], #1
    adds r5, r5, #1
    cmp r5, #128
    bne 3b
    strh r5, [r4]
2:  ldr r0, =bl_dest
    ldr r0, [r0]
    ldr r1, =bl_stage
    movs r2, #1
    bl bl_write_hp
    cbnz r0, 9f
    ldr r0, =bl_dest
    ldr r1, [r0]
    adds r1, r1, #128
    str r1, [r0]
    ldrh r5, [r4]                           @ move the rest down
    subs r5, r5, #128
    strh r5, [r4]
    ldr r0, =bl_stage
    add r1, r0, #128
    cmp r5, #0
    beq 1b
4:  ldrb r2, [r1], #1
    strb r2, [r0], #1
    subs r5, r5, #1
    bne 4b
    b 1b
8:  movs r0, #0
9:  pop {r4-r6, pc}
ENDFUNC bl_flush_stage

@ -----------------------------------------------------------------------------
@ bl_end_check - after the last byte: last half-page, CRC-32 of the programmed image, then mark or slot header
@ Out      : r0 = 0 done, 2 length or CRC wrong, 3 not a firmware image, 6 flash failed
@ Clobbers : r1-r3, r12, flags (r4, r5 saved)
@ -----------------------------------------------------------------------------
LFUNC bl_end_check
    push {r4, r5, lr}
    movs r0, #1
    bl bl_flush_stage_all
    cbnz r0, 6f
    ldr r1, =bl_dest0
    ldr r1, [r1]
    ldr r2, =bl_size
    ldr r2, [r2]
    bl bl_crc_final
    mov r5, r0                              @ r5 = CRC of the flash
    ldr r1, =bl_crc
    ldr r1, [r1]
    cmp r0, r1
    bne 2f
    ldr r0, =bl_kind
    ldrb r0, [r0]
    cmp r0, #KIND_BL
    beq 4f
    @ firmware: initial SP in the RAM, reset vector Thumb inside the firmware area
    ldr r4, =APP_BASE
    ldr r0, [r4, #0]
    ldr r1, =0x20000001
    cmp r0, r1
    blo 3f
    ldr r1, =0x2000C000
    cmp r0, r1
    bhi 3f
    ldr r0, [r4, #4]
    tst r0, #1
    beq 3f
    cmp r0, r4
    blo 3f
    ldr r1, =APP_LIMIT
    cmp r0, r1
    bhs 3f
    ldr r0, =FW_MARK
    ldr r1, =FW_MAGIC
    ldr r2, =bl_size
    ldr r2, [r2]
    mov r3, r5
    bl bl_write_header
    cbnz r0, 6f
    movs r0, #0
    pop {r4, r5, pc}
4:  ldr r0, =bl_slot                        @ bootloader: slot header, then the INSTALL record for the starter
    ldr r0, [r0]
    ldr r1, =HDR_MAGIC
    ldr r2, =bl_size
    ldr r2, [r2]
    mov r3, r5
    bl bl_write_header
    cbnz r0, 6f
    movs r0, #CMD_INSTALL
    ldr r1, =bl_slot
    ldr r1, [r1]
    bl bl_ctl_append
    cbnz r0, 6f
    movs r0, #0
    pop {r4, r5, pc}
2:  movs r0, #2
    pop {r4, r5, pc}
3:  movs r0, #3
    pop {r4, r5, pc}
6:  movs r0, #6
    pop {r4, r5, pc}
ENDFUNC bl_end_check

@ -----------------------------------------------------------------------------
@ bl_free_slot - the slot that does not hold the running bootloader: the starter copies a slot's header as the
@ bootloader mark, so slot A holds the running bootloader when its image CRC equals the mark's; then B is free, else A
@ Out      : r0 = slot address
@ Clobbers : r1-r3, r12, flags
@ -----------------------------------------------------------------------------
LFUNC bl_free_slot
    ldr r0, =SLOT_A
    ldr r1, [r0, #8]
    ldr r2, =BL_MARK
    ldr r2, [r2, #8]
    cmp r1, r2
    ite eq
    ldreq r0, =SLOT_B                       @ A holds the running one
    ldrne r0, =SLOT_A
    bx lr
ENDFUNC bl_free_slot

    .ltorg

    .section .rodata.bl_ble, "a", %progbits
bl_desc_usart:
    GPIO_DESC 0x0060, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 7, BRD_LEVEL_KEEP

    .section .bss.bl_ble_t, "aw", %nobits
    .balign 4
bl_last_byte:   .space 4                    @ ticks of the last received byte

@ -----------------------------------------------------------------------------
@ bl_usart_isr - USART2 interrupt, runs from RAM: received byte into the ring (a full ring drops it; the packet CRC
@ then fails and the sender repeats it).  Reading SR then DR also clears an overrun (RM0038 26.6.1).
@ -----------------------------------------------------------------------------
    .section .ramcode.bl_ble, "ax", %progbits
FUNC bl_usart_isr
    ldr r0, 7f
    ldr r1, [r0, #USART_SR]
    ldr r2, [r0, #USART_DR]
    tst r1, #SR_RXNE
    beq 2f
    ldr r0, 8f                              @ bl_rx_head
    ldrh r1, [r0]
    adds r3, r1, #1
    bfc r3, #10, #22
    ldr r12, 9f                             @ bl_rx_tail
    ldrh r12, [r12]
    cmp r3, r12
    beq 2f
    ldr r12, 10f                            @ bl_ring
    strb r2, [r12, r1]
    strh r3, [r0]
2:  bx lr
    .balign 4
7:  .word USART2_BASE_BL
8:  .word bl_rx_head
9:  .word bl_rx_tail
10: .word bl_ring
ENDFUNC bl_usart_isr
