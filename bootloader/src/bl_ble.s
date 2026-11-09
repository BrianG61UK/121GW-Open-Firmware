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
@             Packed (IMP-63, B-1.15): START kind | 0x80 = the DATA bytes are the packed stream of the image: pieces
@             of raw length u16 (1 .. 2048), packed length u16 (1 .. 2064) and one final dynamic-code deflate block
@             of exactly those bytes, or packed length 0x8000 | raw length and the raw bytes; cut into packets anywhere; size and CRC-32 are those of the unpacked image.  A piece header is checked
@             against the bytes still due before anything is unpacked; a complete piece is unpacked
@             (firmware/src/sys/zinf.s) and its bytes take the plain path (bl_stage, half-pages); END checks the flash
@             as for a plain transfer.  A bad header, a piece that does not unpack to exactly its length, stream bytes
@             beyond the image or after the last piece at END: LdE 7, status 0x17, back to waiting (an erased
@             firmware stays without mark: the bootloader stays in update mode).
@   3 END     all bytes sent: the flash is checked against the CRC-32; firmware: image check, firmware mark; bootloader:
@             slot header, INSTALL record; the meter restarts 1.5 s after the END packet (RESET_DELAY, bl_main.s)
@   4 ABORT   back to waiting (an erased firmware stays without mark: the bootloader stays in update mode)
@   5 STATUS  payload index(1): 0x80 bootloader version (major << 8 | minor << 4 | patch), 1 state, 2 bytes received
@             / 256; the firmware's page Ld refuses index 0x80 (status 3), so the answer tells the bootloader
@             from the firmware
@ Status: 0 accepted, 1 CRC wrong, 2 not the expected packet (next = expected), 3 not allowed now, 4 START refused,
@         5 bytes beyond the size, 0x10 + n END failed: n = 2 length or CRC-32 wrong, 3 not a firmware image,
@         6 flash write or check failed, 7 the packed stream is damaged (also as status 0x17 to a DATA packet).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "bl.inc"

    .equ RING_LEN,          1024            @ power of two: four full packets
    .equ MAXPAY,            232             @ largest payload of one packet
    .equ ST_WAIT,           0               @ no transfer in progress: waiting for START
    .equ ST_RECV,           1               @ START accepted, DATA packets are being programmed
    .equ ST_DONE,           2               @ END accepted: the restart is due
    .equ KIND_FW,           0               @ START kind: firmware image
    .equ KIND_BL,           2               @ START kind: bootloader image
    .equ ZRAW_MAX,          2048            @ packed: raw bytes of one piece
    .equ ZPACK_MAX,         2064            @ packed: packed bytes of one piece (zlib: at most 2048 + 5, stored)
    .equ ZERR,              7               @ END / DATA error: the packed stream is damaged
    .equ GAP_TICKS,         20              @ 200 ms without a byte drops a packet being assembled
    .equ APB1_USART2,       0x00020000      @ RCC_APB1ENR bit 17
    .equ AHB_GPIOD,         0x00000008      @ RCC_AHBENR bit 3: GPIOD clock
    .equ NVIC_ISER1,        0xE000E104      @ NVIC set-enable register 1 (IRQ32..63)
    .equ NVIC_ICER1,        0xE000E184      @ NVIC clear-enable register 1 (IRQ32..63)
    .equ IRQ38_BIT,         0x00000040      @ IRQ 38 = bit 6 of the second ISER / ICER word
    .equ CR1_ON,            0x0000202C      @ UE | RXNEIE | TE | RE (RM0038 26.6.4)
    .equ SR_RXNE,           0x20            @ USART_SR: receive data register not empty
    .equ SR_TXE,            0x80            @ USART_SR: transmit data register empty
    .equ SR_TC,             0x40            @ USART_SR: transmission complete
    .equ VEC_WORDS,         73              @ table entries: 16 core exceptions + IRQ0..56 (bl_main.s bl_vectors)

@ RAM of the link: receive ring, the packet being assembled, the stage for half-pages and the transfer state.
    .section .bss.bl_ble, "aw", %nobits
    .balign 4
    .global bl_ble_activity
bl_ring:        .space RING_LEN             @ receive ring: filled by bl_usart_isr (head), emptied by bl_ble_poll (tail)
bl_pkt:         .space 8 + MAXPAY           @ packet being assembled: B5 5B type seq(2) len payload crc16(2)
bl_stage:       .space 384                  @ bytes waiting for their half-page: < 128 left + 232 of a packet
bl_ans:         .space 12                   @ answer packet, 11 bytes
bl_size:        .space 4                    @ image size from START
bl_crc:         .space 4                    @ image CRC-32 from START
bl_recv:        .space 4                    @ image bytes received so far
bl_dest0:       .space 4                    @ first address of the image
bl_dest:        .space 4                    @ next half-page to program
bl_slot:        .space 4                    @ slot of a bootloader image
bl_ble_activity: .space 4                   @ ticks of the last received packet (bl_main.s timeouts)
bl_rx_head:     .space 2                    @ written by the interrupt
bl_rx_tail:     .space 2                    @ read position of bl_ble_poll
bl_pos:         .space 2                    @ bytes of the packet assembled so far; 0 = waiting for B5
bl_seq:         .space 2                    @ number of the next DATA packet expected
bl_staged:      .space 2                    @ bytes in bl_stage
bl_state:       .space 1                    @ ST_WAIT, ST_RECV or ST_DONE
bl_kind:        .space 1                    @ KIND_FW or KIND_BL of the running transfer
bl_zmode:       .space 1                    @ 1 = the DATA bytes are the packed stream (START kind bit 7)
bl_zfill:       .space 2                    @ packed: bytes of the current piece collected (header included)
    .balign 4
bl_zbuf:        .space 4 + ZPACK_MAX        @ packed: the piece being collected (header, packed bytes)
bl_zraw:        .space ZRAW_MAX             @ packed: the unpacked piece
bl_last_pct:    .space 1                    @ percent shown, 200 = "Ld oK" shown, 0xFF = draw at the next chance
bl_show_err:    .space 1                    @ END or flash error to show, 0 none
bl_txt:         .space 5                    @ main display text
    .global bl_reset_due
bl_reset_due:   .space 1                    @ 1: restart (bl_main.s) once the answer is out

    .section .ramvec, "aw", %nobits         @ vector table in RAM while the link is open (512-byte boundary)
    .balign 512
bl_ram_vectors: .space VEC_WORDS * 4

    .section .text.bl_ble, "ax", %progbits

@ -----------------------------------------------------------------------------
@ bl_ble_on - BLE module on, USART2 at 19200 baud, receive interrupt from the RAM vector table
@ Clobbers : r0-r3, r12, flags
@ Context  : main, on entering update mode and when a key press switches the module on again (bl_main.s)
@ Note     : order as the firmware: PF15 high first, then PD5/PD6 become AF7.  The vector table is copied to RAM with
@            the USART2 entry (exception 54 = IRQ38 + 16) pointing at the RAM handler, and VTOR is moved there: the
@            handler can then run while a flash operation executes (the flash stalls instruction fetches from the bank
@            being written, bl_flash.s).
@ -----------------------------------------------------------------------------
FUNC bl_ble_on
    push {r4, lr}
    ldr r0, =(GPIOF_BASE + GPIO_BSRRL)
    mov r1, #0x8000
    strh r1, [r0]                           @ PF15 high: BLE module supply (before PD5/PD6 become AF7)
    @ GPIOD clock on
    ldr r0, =RCC_AHBENR
    ldr r1, [r0]
    orr r1, r1, #AHB_GPIOD
    str r1, [r0]
    ldr r0, =GPIOD_BASE
    ldr r1, =bl_desc_usart
    bl brd_gpio_init                        @ PD5 TX, PD6 RX: AF7, pull-up (as the firmware)
    @ USART2 clock on
    ldr r0, =RCC_APB1ENR
    ldr r1, [r0]
    orr r1, r1, #APB1_USART2
    str r1, [r0]
    @ ring, packet assembly and state cleared
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
    str r0, [r1, #(54 * 4)]                 @ USART2 handler into the RAM table
    dsb                                     @ table writes complete before VTOR changes
    ldr r0, =SCB_VTOR
    str r1, [r0]                            @ VTOR = the RAM table
    dsb
    isb                                     @ new table in effect before the next instruction
    ldr r4, =USART2_BASE_BL
    movs r0, #USART_BRR_19200               @ baud divider for MSI 4.194 MHz (bl.inc)
    str r0, [r4, #USART_BRR]
    ldr r0, =CR1_ON
    str r0, [r4, #USART_CR1]                @ UE | RXNEIE | TE | RE: USART on, receive interrupt on
    ldr r0, =NVIC_ISER1
    movs r1, #IRQ38_BIT
    str r1, [r0]                            @ IRQ38 (USART2) enabled in the NVIC
    pop {r4, pc}
ENDFUNC bl_ble_on

@ -----------------------------------------------------------------------------
@ bl_ble_off - USART2 and its interrupt off, the flash vector table again, BLE module supply off (PF15 low)
@ Clobbers : r0-r3, flags
@ Context  : main, before the firmware is started, before the card update, and after 10 minutes without a packet
@ -----------------------------------------------------------------------------
FUNC bl_ble_off
    ldr r0, =NVIC_ICER1
    movs r1, #IRQ38_BIT
    str r1, [r0]                            @ IRQ38 disabled in the NVIC
    ldr r0, =USART2_BASE_BL
    movs r1, #0
    str r1, [r0, #USART_CR1]                @ USART2 off
    ldr r0, =SCB_VTOR
    ldr r1, =BL_BASE
    str r1, [r0]                            @ VTOR back to the table in flash (BL_BASE)
    dsb
    isb
    ldr r0, =(GPIOF_BASE + GPIO_BSRRH)
    mov r1, #0x8000
    strh r1, [r0]                           @ GPIOF BSRRH bit 15: PF15 low
    bx lr
ENDFUNC bl_ble_off

@ -----------------------------------------------------------------------------
@ bl_ble_send - send r1 bytes from r0, polled (TXE before each byte, TC at the end)
@ In       : r0 = address, r1 = length (>= 1)
@ Clobbers : r0-r3, flags
@ Context  : main, only bl_answer
@ Note     : returns when the last byte has left the shift register, so the caller may do slow work (flash) after it.
@ -----------------------------------------------------------------------------
LFUNC bl_ble_send
    ldr r2, =USART2_BASE_BL
1:  ldr r3, [r2, #USART_SR]
    tst r3, #SR_TXE                         @ wait until the transmit register is empty
    beq 1b
    ldrb r3, [r0], #1                       @ next byte
    str r3, [r2, #USART_DR]
    subs r1, r1, #1
    bne 1b                                  @ all r1 bytes
2:  ldr r3, [r2, #USART_SR]
    tst r3, #SR_TC                          @ last byte completely shifted out?
    beq 2b
    bx lr
ENDFUNC bl_ble_send

@ -----------------------------------------------------------------------------
@ bl_crc16 - CRC-16/CCITT-FALSE of r1 bytes at r0
@ In       : r0 = address, r1 = length
@ Out      : r0 = CRC-16
@ Clobbers : r1-r3, r12
@ Context  : main (packet check, answer)
@ Note     : start value 0xFFFF, polynomial 0x1021, most significant bit first, no final XOR.  Bit 16 of the working
@            value is the bit shifted out; the bits above bit 15 are cut after each byte.
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
LFUNC bl_crc16
    movw r2, #0xFFFF                        @ start value
    movw r12, #0x1021                       @ polynomial
1:  cbz r1, 4f                              @ no bytes left: done
    ldrb r3, [r0], #1
    eor r2, r2, r3, lsl #8                  @ the byte joins the high half
    movs r3, #8
2:  lsls r2, r2, #1
    tst r2, #0x10000                        @ the bit shifted out of bit 15
    it ne
    eorne r2, r2, r12
    subs r3, r3, #1
    bne 2b
    uxth r2, r2                             @ drop the bits above bit 15
    subs r1, r1, #1
    b 1b
4:  mov r0, r2
    bx lr
ENDFUNC bl_crc16

@ -----------------------------------------------------------------------------
@ bl_answer - answer the packet in bl_pkt: r0 = status, r1 = next
@ In       : r0 = status, r1 = next (u16: the packet number expected, or a value for STATUS)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4 saved)
@ Context  : main, once per packet
@ Note     : answer B5 5B 81 seq(2) 03 status next(2) crc16(2): the sequence field is copied from the request, the
@            payload is 3 bytes, the CRC-16 covers type..payload (7 bytes).
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
    ldrb r3, [r2, #3]                       @ sequence number copied from the request
    strb r3, [r4, #3]
    ldrb r3, [r2, #4]
    strb r3, [r4, #4]
    movs r2, #3
    strb r2, [r4, #5]                       @ payload length 3
    strb r0, [r4, #6]                       @ status
    strb r1, [r4, #7]                       @ next, low byte
    lsrs r1, r1, #8
    strb r1, [r4, #8]                       @ next, high byte
    adds r0, r4, #2                         @ CRC over type..payload
    movs r1, #7                             @ 7 bytes: type, seq(2), length, status, next(2)
    bl bl_crc16
    strb r0, [r4, #9]                       @ CRC low byte
    lsrs r0, r0, #8
    strb r0, [r4, #10]                      @ CRC high byte
    mov r0, r4
    movs r1, #11                            @ 11 bytes in all
    bl bl_ble_send
    pop {r4, pc}
ENDFUNC bl_answer

@ -----------------------------------------------------------------------------
@ bl_le32 - little-endian u32 at r0 (any alignment)
@ Out      : r0 = value
@ Clobbers : r1, r2
@ Context  : main (packet fields are not aligned)
@ -----------------------------------------------------------------------------
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
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main, from the update loop while the link is open
@ Note     : packet layout in bl_pkt: [0] B5, [1] 5B, [2] type, [3..4] seq, [5] payload length, [6..] payload, then the
@            CRC-16 (low, high).  bl_pos counts the bytes assembled; r5 = bl_pos while a byte is handled.  A byte that
@            does not fit (no B5 at the start, no 5B after it) restarts the assembly, a length above MAXPAY drops the
@            packet.  bl_packet does the packet's work before returning, so the answer goes out inside this call.
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
FUNC bl_ble_poll
    push {r4-r7, lr}
    mov r7, r0                              @ r7 = now (ticks)
    ldr r6, =bl_pkt                         @ r6 = packet buffer
    ldr r0, =bl_pos                         @ a packet cut short is dropped after GAP_TICKS without a byte
    ldrh r1, [r0]
    cbz r1, 1f                              @ no packet in progress: no gap check
    ldr r2, =bl_last_byte
    ldr r2, [r2]
    subs r2, r7, r2                         @ ticks since the last byte
    cmp r2, #GAP_TICKS
    blo 1f
    movs r1, #0
    strh r1, [r0]
    @ take one byte from the ring, if any
1:  ldr r1, =bl_rx_tail
    ldrh r2, [r1]
    ldr r0, =bl_rx_head
    ldrh r0, [r0]
    cmp r0, r2
    beq 9f                                  @ ring empty
    ldr r0, =bl_ring
    ldrb r3, [r0, r2]                       @ r3 = the byte
    adds r2, r2, #1
    bfc r2, #10, #22                        @ wrap at RING_LEN (1024)
    strh r2, [r1]                           @ tail advanced
    ldr r0, =bl_last_byte
    str r7, [r0]                            @ tick of this byte
    ldr r1, =bl_pos
    ldrh r5, [r1]                           @ r5 = bytes assembled so far
    cbnz r5, 2f
    cmp r3, #0xB5                           @ first byte of a packet must be B5, anything else is skipped
    bne 1b
    strb r3, [r6, #0]
    movs r5, #1
    b 8f
    @ second byte: 5B continues; B5 again counts as a new start; anything else restarts
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
    @ further bytes are stored; from the sixth on, the length byte (index 5) says when the packet is complete
3:  strb r3, [r6, r5]
    adds r5, r5, #1
    cmp r5, #6                              @ length byte not in yet
    blo 8f
    ldrb r0, [r6, #5]                       @ payload length
    cmp r0, #MAXPAY
    bls 4f
    movs r5, #0                             @ longer than MAXPAY: drop the packet (r5 = 0)
    b 8f
4:  adds r0, r0, #8                         @ total bytes = 8 + payload (framing 6, CRC 2)
    cmp r5, r0
    blo 8f                                  @ not complete yet
    movs r0, #0                             @ complete
    strh r0, [r1]                           @ packet consumed: bl_pos = 0
    ldr r0, =bl_ble_activity
    str r7, [r0]
    ldrb r4, [r6, #5]
    adds r0, r6, #2                         @ CRC over type, seq, length and payload
    adds r1, r4, #4                         @ length + 4
    bl bl_crc16
    adds r4, r4, #6                         @ r4 = index of the CRC low byte (6 + length)
    ldrb r1, [r6, r4]
    adds r4, r4, #1
    ldrb r2, [r6, r4]
    orr r1, r1, r2, lsl #8                  @ received CRC-16
    cmp r0, r1
    beq 5f                                  @ equal: handle the packet
    movs r0, #1                             @ CRC wrong: resend
    movs r1, #0
    bl bl_answer
    b 9f
5:  bl bl_packet                            @ valid packet: execute
    b 9f
8:  ldr r1, =bl_pos
    strh r5, [r1]                           @ save the assembly position, take the next byte
    b 1b
9:  pop {r4-r7, pc}
ENDFUNC bl_ble_poll

@ -----------------------------------------------------------------------------
@ bl_packet - handle the complete packet in bl_pkt
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Context  : main, only bl_ble_poll, after the CRC-16 was verified
@ Note     : dispatch on the type byte: 1 START, 2 DATA, 3 END, 4 ABORT, 5 STATUS.  Every path ends in .Lp_answer with
@            r0 = status, r1 = next, then the display is redrawn.  r4 = bl_pkt throughout.  Status codes are listed in
@            the file header.
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
@ an unknown type, or a request that does not fit the state: status 3, next 0
.Lp_notallowed:
    movs r0, #3
    movs r1, #0
    b .Lp_answer
@ STATUS: one payload byte, the index; 0x80 bootloader version, 1 state, 2 bytes received / 256
.Lp_status:
    ldrb r0, [r4, #5]                       @ payload length must be 1
    cmp r0, #1
    bne .Lp_notallowed
    ldrb r0, [r4, #6]
    cmp r0, #0x80                           @ index 0x80
    bne 1f
    ldr r1, =((((BL_VERSION >> 16) & 0xFF) << 8) | (((BL_VERSION >> 8) & 0xF) << 4) | (BL_VERSION & 0xF))  @ major << 8 | minor << 4 | patch
    b 3f
1:  cmp r0, #1
    bne 2f
    ldr r1, =bl_state
    ldrb r1, [r1]                           @ bl_state
    b 3f
2:  cmp r0, #2
    bne .Lp_notallowed
    ldr r1, =bl_recv
    ldr r1, [r1]
    lsrs r1, r1, #8                         @ bytes received / 256
3:  movs r0, #0                             @ status 0, next = the value
    b .Lp_answer
@ ABORT: back to waiting
.Lp_abort:
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
    movs r1, #0
    b .Lp_answer
@ START: payload size(4) crc32(4) kind(1) [version(4)], i.e. 9 or 13 bytes
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
1:  adds r0, r4, #6                         @ size at +6
    bl bl_le32
    mov r6, r0                              @ r6 = size
    adds r0, r4, #10                        @ CRC-32 at +10
    bl bl_le32
    ldr r1, =bl_crc
    str r0, [r1]                            @ kept for END
    movs r0, #0
    cmp r5, #13                             @ the version field is there only in the 13-byte form, else 0
    bne 2f
    adds r0, r4, #15
    bl bl_le32
2:  ldr r1, =bl_hdr_ver
    str r0, [r1]                            @ version word of the header written at END (bl_flash.s)
    ldrb r7, [r4, #14]                      @ r7 = kind; bit 7 = packed
    lsrs r0, r7, #7
    ldr r1, =bl_zmode
    strb r0, [r1]
    and r7, r7, #0x7F
    cmp r7, #KIND_FW
    beq .Lp_start_fw
    cmp r7, #KIND_BL
    bne .Lp_refuse
    @ bootloader image into the slot that does not hold the running bootloader
    subs r0, r6, #1
    cmp r0, #BL_MAX
    bhs .Lp_refuse                          @ size must be 1..BL_MAX bytes
    bl bl_free_slot                         @ r0 = the slot not holding the running bootloader
    ldr r1, =bl_slot
    str r0, [r1]
    add r1, r0, #SLOT_SIZE                  @ the whole slot (header page and image) is erased
    bl bl_erase
    cmp r0, #0
    bne .Lp_refuse_flash                    @ erase failed: START refused, back to waiting
    ldr r0, =bl_slot
    ldr r0, [r0]
    add r0, r0, #SLOT_IMG                   @ the image starts behind the header page (SLOT_IMG)
    b .Lp_start_go
@ firmware: 0x124 (73 vector words) .. APP_MAX bytes
.Lp_start_fw:
    cmp r6, #0x124
    blo .Lp_refuse
    ldr r0, =APP_MAX
    cmp r6, r0
    bhi .Lp_refuse
    ldr r0, =FW_MARK                        @ the firmware mark first: from now on the bootloader stays in update mode
    add r1, r0, #0x100                      @ end of the mark page
    bl bl_erase
    cbnz r0, .Lp_refuse_flash
@ then the image area, size rounded up to whole 256-byte pages
    ldr r0, =APP_BASE
    add r1, r6, #0xFF                       @ size rounded up to 256
    bic r1, r1, #0xFF
    add r1, r1, r0
    bl bl_erase
    cbnz r0, .Lp_refuse_flash
    ldr r0, =APP_BASE                       @ programming starts at APP_BASE
@ common part of START: addresses, counters and state; the answer says accepted (status 0, next 0)
.Lp_start_go:
    ldr r1, =bl_dest0
    str r0, [r1]                            @ bl_dest0: first address of the image (for the CRC at END)
    ldr r1, =bl_dest
    str r0, [r1]                            @ bl_dest: next half-page to program
    ldr r1, =bl_size
    str r6, [r1]                            @ image size
    ldr r1, =bl_kind
    strb r7, [r1]                           @ kind
    movs r0, #0
    ldr r1, =bl_recv
    str r0, [r1]
    ldr r1, =bl_seq
    strh r0, [r1]
    ldr r1, =bl_staged
    strh r0, [r1]
    ldr r1, =bl_zfill
    strh r0, [r1]
    movs r0, #0xFF                          @ the percent is drawn at the next redraw
    ldr r1, =bl_last_pct
    strb r0, [r1]
    movs r0, #ST_RECV
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #0
    movs r1, #0
    b .Lp_answer
@ an erase failed: back to waiting, START refused
.Lp_refuse_flash:
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
@ START refused: status 4
.Lp_refuse:
    movs r0, #4
    movs r1, #0
    b .Lp_answer
@ DATA: only while receiving; packet number must be the expected one
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
    cmp r5, r6                              @ the expected packet
    beq 1f
    blo 2f                                  @ an earlier packet again (its answer was lost): accepted, not stored
    movs r0, #2                             @ ahead: name the packet expected
    mov r1, r6
    b .Lp_answer
2:  movs r0, #0
    mov r1, r6
    b .Lp_answer
1:  ldrb r5, [r4, #5]                       @ r5 = payload length
    ldr r0, =bl_zmode
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lp_zdata
    ldr r0, =bl_recv
    ldr r1, [r0]                            @ r1 = bytes received including this packet
    add r1, r1, r5
    ldr r2, =bl_size
    ldr r2, [r2]
    cmp r1, r2
    bls 3f                                  @ within the size from START
    movs r0, #5                             @ status 5: bytes beyond the size
    mov r1, r6
    b .Lp_answer
3:  str r1, [r0]                            @ bl_recv updated
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
    cbnz r0, .Lp_flash_fail                 @ flash write or check failed
    adds r6, r6, #1                         @ next packet number expected
    ldr r2, =bl_seq
    strh r6, [r2]
    movs r0, #0
    mov r1, r6                              @ next = the new expected number
    b .Lp_answer
@ packed DATA: the stream bytes through bl_zdata (pieces unpacked and programmed); a damaged stream ends the transfer
.Lp_zdata:
    adds r0, r4, #6
    mov r1, r5
    bl bl_zdata                             @ r0 = 0, 6 flash failed, ZERR stream damaged
    cmp r0, #6
    beq .Lp_flash_fail
    cbnz r0, .Lp_zfail
    adds r6, r6, #1                         @ next packet number expected
    ldr r2, =bl_seq
    strh r6, [r2]
    movs r0, #0
    mov r1, r6
    b .Lp_answer
.Lp_zfail:
    movs r0, #ZERR
    ldr r1, =bl_show_err
    strb r0, [r1]
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #(0x10 + ZERR)
    movs r1, #0
    b .Lp_answer
@ a flash write failed: LdE 6 on the display, back to waiting, status 0x16 (0x10 + 6)
.Lp_flash_fail:
    movs r0, #6
    ldr r1, =bl_show_err
    strb r0, [r1]
    movs r0, #ST_WAIT
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #0x16
    movs r1, #0
    b .Lp_answer
@ END: all bytes must be there, then the flash is checked
.Lp_end:
    ldr r0, =bl_state
    ldrb r0, [r0]
    cmp r0, #ST_DONE
    bne 1f
    movs r0, #0                             @ END again (the answer was lost): done
    movs r1, #0                             @ next 0
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
2:  ldr r0, =bl_zfill
    ldrh r0, [r0]
    cmp r0, #0
    bne .Lp_zfail                           @ packed: stream bytes after the last piece
    bl bl_end_check                         @ r0 = 0 or the END error n
    cbz r0, 3f
    ldr r1, =bl_show_err
    strb r0, [r1]
    adds r0, r0, #0x10                      @ status 0x10 + n
    movs r1, #ST_WAIT
    ldr r2, =bl_state
    strb r1, [r2]
    movs r1, #0
    b .Lp_answer
3:  movs r0, #ST_DONE                       @ check done: ST_DONE
    ldr r1, =bl_state
    strb r0, [r1]
    movs r0, #1
    ldr r1, =bl_reset_due
    strb r0, [r1]                           @ bl_main.s restarts after RESET_DELAY
    movs r0, #0
    movs r1, #0
@ answer first, then redraw: the sender is not held up
.Lp_answer:
    bl bl_answer
    bl bl_ble_draw                          @ the display after the answer: the sender is not held up
    pop {r4-r7, pc}
ENDFUNC bl_packet

@ -----------------------------------------------------------------------------
@ bl_ble_draw - main display during a transfer (as the firmware's page Ld): "Ld nn" percent received with the
@ bargraph, "Ld oK" when the image is checked (shown until the restart), "LdE n" after a failed END (n = END error 2, 3
@ or 6), a failed flash write (6) or a damaged packed stream (7); the sub display keeps "-IAP-"
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Context  : main, after every answer
@ Note     : the text is built in bl_txt (5 characters); bl_last_pct remembers what is shown so that the display is
@            redrawn only when the percent changes (0xFF forces a redraw, 200 = "Ld oK" shown).
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
LFUNC bl_ble_draw
    push {r4, r5, lr}
    ldr r4, =bl_txt                         @ r4 = text buffer: "Ld" then three characters
    movs r0, #'L'
    strb r0, [r4, #0]
    movs r0, #'d'
    strb r0, [r4, #1]
    ldr r0, =bl_show_err
    ldrb r5, [r0]
    cbz r5, 1f
    movs r1, #0
    strb r1, [r0]                           @ the error is drawn once, then cleared
    movs r0, #'E'                           @ "LdE n"
    strb r0, [r4, #2]
    movs r0, #' '
    strb r0, [r4, #3]
    adds r0, r5, #'0'                       @ digit of the error number
    strb r0, [r4, #4]
    b 8f
1:  ldr r0, =bl_state
    ldrb r0, [r0]
    cmp r0, #ST_DONE
    bne 2f
    ldr r1, =bl_last_pct
    ldrb r2, [r1]
    cmp r2, #200
    beq 9f                                  @ "Ld oK" already shown
    movs r2, #200
    strb r2, [r1]
    movs r0, #' '                           @ "Ld oK"
    strb r0, [r4, #2]
    movs r0, #'o'
    strb r0, [r4, #3]
    movs r0, #'K'
    strb r0, [r4, #4]
    movs r0, #26                            @ all 26 segments
    bl bl_lcd_bar
    b 8f
2:  cmp r0, #ST_RECV
    bne 9f                                  @ waiting: nothing to draw
    ldr r0, =bl_recv                        @ percent = received x 100 / size, at most 99 until the check
    ldr r0, [r0]
    ldr r1, =bl_size
    ldr r1, [r1]
    movs r2, #100
    muls r2, r0, r2
    udiv r2, r2, r1
    cmp r2, #99
    it hi
    movhi r2, #99
    ldr r3, =bl_last_pct
    ldrb r12, [r3]                          @ r12 = percent shown last
    cmp r2, r12
    beq 9f                                  @ unchanged: no redraw
    strb r2, [r3]                           @ remember it
    movs r3, #10
    udiv r12, r2, r3                        @ tens
    mls r3, r12, r3, r2                     @ units
    movs r0, #' '
    strb r0, [r4, #2]
    adds r12, r12, #'0'
    strb r12, [r4, #3]
    adds r3, r3, #'0'
    strb r3, [r4, #4]
    ldr r0, =bl_recv                        @ bargraph 25 x received / size
    ldr r0, [r0]
    movs r2, #25
    muls r0, r2, r0
    udiv r0, r0, r1
    bl bl_lcd_bar
8:  movs r0, #5                             @ main display, position 5
    mov r1, r4
    bl bl_lcd_text
    bl bl_lcd_commit
9:  pop {r4, r5, pc}
ENDFUNC bl_ble_draw

@ -----------------------------------------------------------------------------
@ bl_flush_stage - program the full half-pages of bl_stage; with r0 = 1 on entry from bl_end_check also the last,
@ partial one (zero padded)
@ Out      : r0 = 0, else non-zero
@ Clobbers : r1-r3, r12, flags (r4-r6 saved)
@ Context  : main (after every DATA packet, and at END)
@ Note     : DATA payloads (up to 232 bytes) are appended to bl_stage; the flash takes 128-byte half-pages, so the
@            stage keeps the remainder (< 128 bytes) between packets.  bl_dest is the next half-page to program.
@            Padding with zeros equals the erased state, so the image CRC is over the real bytes only (bl_size).
@ -----------------------------------------------------------------------------
@ -----------------------------------------------------------------------------
LFUNC bl_flush_stage
    movs r0, #0                             @ normal entry: full half-pages only
bl_flush_stage_all:                         @ entry with r0 = 1: the partial half-page too
    push {r4-r6, lr}
    mov r6, r0                              @ r6 = 1: also the partial half-page
    ldr r4, =bl_staged                      @ r4 = &bl_staged
1:  ldrh r5, [r4]                           @ bytes in the stage
    cmp r5, #128
    bhs 2f                                  @ a full half-page is there
    cbz r6, 8f                              @ not the end: leave the rest staged
    cbz r5, 8f                              @ nothing staged: done
    ldr r0, =bl_stage                       @ pad the last half-page with zeros
    add r0, r0, r5
    movs r1, #0
3:  strb r1, [r0], #1
    adds r5, r5, #1
    cmp r5, #128
    bne 3b
    strh r5, [r4]                           @ now a full half-page
2:  ldr r0, =bl_dest
    ldr r0, [r0]
    ldr r1, =bl_stage
    movs r2, #1                             @ one half-page
    bl bl_write_hp                          @ program bl_stage at bl_dest and read it back
    cbnz r0, 9f                             @ error: return it
    ldr r0, =bl_dest
    ldr r1, [r0]
    adds r1, r1, #128                       @ bl_dest += 128
    str r1, [r0]
    ldrh r5, [r4]                           @ move the rest down
    subs r5, r5, #128                       @ bytes staged after this half-page
    strh r5, [r4]
    ldr r0, =bl_stage
    add r1, r0, #128
    cmp r5, #0
    beq 1b                                  @ nothing left: the loop ends at the test above
4:  ldrb r2, [r1], #1                       @ the rest moves to the start of the stage
    strb r2, [r0], #1
    subs r5, r5, #1
    bne 4b
    b 1b
8:  movs r0, #0
9:  pop {r4-r6, pc}
ENDFUNC bl_flush_stage

@ -----------------------------------------------------------------------------
@ bl_zdata - packed DATA (IMP-63): r1 stream bytes at r0 into bl_zbuf; each complete piece is unpacked into bl_zraw
@            and programmed through bl_stage as plain DATA bytes; bl_recv advances by its raw length
@ Out      : r0 = 0 done, 6 a flash write failed, ZERR the stream is damaged or goes beyond the image
@ Clobbers : r0-r3, r12, flags (r4-r7 saved)
@ Note     : the header is checked as soon as its 4 bytes are there (raw 1 .. 2048, packed 1 .. 2064, raw at most the
@            bytes still due), so nothing beyond the erased image area is ever programmed; a new piece may not start
@            once the image is complete
@ -----------------------------------------------------------------------------
LFUNC bl_zdata
    push {r4-r7, lr}
    mov r4, r0                              @ r4 = next stream byte
    mov r5, r1                              @ r5 = stream bytes left
    ldr r6, =bl_zfill
    ldr r7, =bl_zbuf
1:  cmp r5, #0
    beq 8f
    ldrh r0, [r6]
    cbnz r0, 2f
    ldr r1, =bl_recv                        @ a new piece: only while bytes are still due
    ldr r1, [r1]
    ldr r2, =bl_size
    ldr r2, [r2]
    cmp r1, r2
    bhs 9f
2:  ldrb r1, [r4], #1
    strb r1, [r7, r0]
    adds r0, r0, #1
    strh r0, [r6]
    subs r5, r5, #1
    cmp r0, #4
    blo 1b
    bne 3f
    ldrh r1, [r7]                           @ the header: its limits
    ldrh r2, [r7, #2]
    subs r3, r1, #1
    cmp r3, #ZRAW_MAX
    bhs 9f
    tst r2, #0x8000
    beq 5f
    bic r2, r2, #0x8000                     @ a raw piece: exactly its raw length
    cmp r2, r1
    bne 9f
5:  subs r3, r2, #1
    movw r12, #ZPACK_MAX
    cmp r3, r12
    bhs 9f
    ldr r3, =bl_recv
    ldr r3, [r3]
    add r3, r3, r1
    ldr r12, =bl_size
    ldr r12, [r12]
    cmp r3, r12
    bhi 9f
    b 1b
3:  ldrh r2, [r7, #2]
    bic r2, r2, #0x8000
    adds r2, r2, #4
    cmp r0, r2
    blo 1b
    movs r0, #0
    strh r0, [r6]                           @ the next piece starts after this one
    ldr r2, =bl_recv
    ldr r3, [r2]
    ldrh r1, [r7]
    add r3, r3, r1
    str r3, [r2]                            @ received += raw length (an error below ends the transfer)
    adds r2, r7, #4                         @ a raw piece: its bytes are the source
    ldrh r1, [r7, #2]
    tst r1, #0x8000
    bne 6f
    mov r0, r2                              @ zinf(packed bytes, packed length, bl_zraw, raw length)
    ldr r2, =bl_zraw
    ldrh r3, [r7]
    bl zinf
    cbnz r0, 9f
    ldr r2, =bl_zraw
6:  ldrh r1, [r7]                           @ r2 = next raw byte, r1 = raw bytes left
4:  movs r3, #MAXPAY                        @ at most one packet's worth into the stage (it holds < 128 + 232)
    cmp r1, r3
    it lo
    movlo r3, r1
    sub r1, r1, r3
    ldr r12, =bl_staged
    ldrh r0, [r12]
    push {r1}
    ldr r1, =bl_stage
    add r1, r1, r0
    add r0, r0, r3
    strh r0, [r12]
5:  ldrb r0, [r2], #1
    strb r0, [r1], #1
    subs r3, r3, #1
    bne 5b
    push {r2}
    bl bl_flush_stage                       @ every full half-page programmed
    pop {r2}
    pop {r1}
    cbnz r0, 7f
    cmp r1, #0
    bne 4b
    b 1b
7:  movs r0, #6
    pop {r4-r7, pc}
8:  movs r0, #0
    pop {r4-r7, pc}
9:  movs r0, #ZERR
    pop {r4-r7, pc}
ENDFUNC bl_zdata

@ -----------------------------------------------------------------------------
@ bl_end_check - after the last byte: last half-page, CRC-32 of the programmed image, then mark or slot header
@ Out      : r0 = 0 done, 2 length or CRC wrong, 3 not a firmware image, 6 flash failed
@ Clobbers : r1-r3, r12, flags (r4, r5 saved)
@ Context  : main, from the END packet when all bytes have arrived
@ Note     : the CRC-32 is computed over the flash itself (bl_dest0, bl_size bytes), so it proves what was programmed,
@            not what was received.  The mark or slot header is written only after that check, so an interrupted or
@            bad transfer leaves no valid mark.  r5 = CRC-32 of the flash.
@ -----------------------------------------------------------------------------
LFUNC bl_end_check
    push {r4, r5, lr}
    movs r0, #1                             @ also the partial last half-page
    bl bl_flush_stage_all
    cbnz r0, 6f                             @ flash failure: 6
    @ CRC-32 of the programmed image against the value from START
    ldr r1, =bl_dest0
    ldr r1, [r1]
    ldr r2, =bl_size
    ldr r2, [r2]
    bl bl_crc_final
    mov r5, r0                              @ r5 = CRC of the flash
    ldr r1, =bl_crc
    ldr r1, [r1]
    cmp r0, r1                              @ differs: 2
    bne 2f
    ldr r0, =bl_kind
    ldrb r0, [r0]
    cmp r0, #KIND_BL
    beq 4f                                  @ bootloader image: slot header and INSTALL record
    @ firmware: initial SP in the RAM, reset vector Thumb inside the firmware area
    ldr r4, =APP_BASE
    ldr r0, [r4, #0]
    @ initial SP must lie in RAM 0x20000001..0x2000C000, as in bl_card.s
    ldr r1, =0x20000001
    cmp r0, r1
    blo 3f
    ldr r1, =0x2000C000
    cmp r0, r1
    bhi 3f
    ldr r0, [r4, #4]                        @ reset vector
    tst r0, #1                              @ Thumb bit
    beq 3f
    cmp r0, r4                              @ inside APP_BASE..APP_LIMIT
    blo 3f
    ldr r1, =APP_LIMIT
    cmp r0, r1
    bhs 3f
    @ image accepted: firmware mark (FW_MAGIC, size, CRC-32, version word from START)
    ldr r0, =FW_MARK
    ldr r1, =FW_MAGIC
    ldr r2, =bl_size
    ldr r2, [r2]
    mov r3, r5
    bl bl_write_header
    cbnz r0, 6f                             @ mark write failed: 6
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
@ Context  : main, at START of a bootloader image
@ -----------------------------------------------------------------------------
LFUNC bl_free_slot
    ldr r0, =SLOT_A
    ldr r1, [r0, #8]                        @ word 2 of the slot A header: image CRC-32
    ldr r2, =BL_MARK
    ldr r2, [r2, #8]                        @ word 2 of the bootloader mark: the same field
    cmp r1, r2
    ite eq
    ldreq r0, =SLOT_B                       @ A holds the running one
    ldrne r0, =SLOT_A                       @ else slot A
    bx lr
ENDFUNC bl_free_slot

    .ltorg

    .section .rodata.bl_ble, "a", %progbits
@ PD5 (TX) and PD6 (RX): AF7, 40 MHz, push-pull, pull-up
bl_desc_usart:
    GPIO_DESC 0x0060, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 7, BRD_LEVEL_KEEP

    .section .bss.bl_ble_t, "aw", %nobits
    .balign 4
bl_last_byte:   .space 4                    @ ticks of the last received byte

@ -----------------------------------------------------------------------------
@ bl_usart_isr - USART2 interrupt, runs from RAM: received byte into the ring (a full ring drops it; the packet CRC
@ then fails and the sender repeats it).  Reading SR then DR also clears an overrun (RM0038 26.6.1).
@ Context  : interrupt (exception 54, from the RAM vector table set up by bl_ble_on)
@ Note     : r1 = SR, r2 = DR (read unconditionally).  The ring holds RING_LEN - 1 bytes: head + 1 == tail means full.
@            The literals are in this routine's own RAM copy, so it reads no flash while a flash operation runs.
@ -----------------------------------------------------------------------------
    .section .ramcode.bl_ble, "ax", %progbits
FUNC bl_usart_isr
    ldr r0, 7f                              @ USART2 base
    ldr r1, [r0, #USART_SR]                 @ r1 = SR
    ldr r2, [r0, #USART_DR]                 @ r2 = DR; reading SR then DR clears RXNE and an overrun
    tst r1, #SR_RXNE
    beq 2f                                  @ no received byte: leave
    ldr r0, 8f                              @ bl_rx_head
    ldrh r1, [r0]                           @ r1 = head
    adds r3, r1, #1
    bfc r3, #10, #22                        @ next head, wrapped at 1024
    ldr r12, 9f                             @ bl_rx_tail
    ldrh r12, [r12]                         @ tail
    cmp r3, r12
    beq 2f                                  @ ring full: byte dropped
    ldr r12, 10f                            @ bl_ring
    strb r2, [r12, r1]                      @ store the byte
    strh r3, [r0]                           @ publish the new head
2:  bx lr
@ literals (RAM copy)
    .balign 4
7:  .word USART2_BASE_BL
8:  .word bl_rx_head
9:  .word bl_rx_tail
10: .word bl_ring
ENDFUNC bl_usart_isr
