@ =============================================================================
@ usart.s - BLE: USART2 link, interrupt handler, transmit pump, echo queue
@
@ BLE module, part 1: USART2 link to the BLE module (PD5 TX, PD6 RX, PF15 module supply), interrupt
@ handler, transmit pump and echo queue (analysis/ble_packet.md 1, 2, 6).
@
@ Transmit design (DESIGN.md 6.26, OF-10, NF-04): the status frame is built in ble_frame_b (packet.s) and
@ marked complete; at TIM2 count 50 sys_tim2_isr calls ble_tx_start_frame, which only records the request
@ and enables the TXE interrupt.  ble_tx_pump (called from ble_usart2_isr on every TXE event) then copies
@ the complete frame to the v2.05 buffer ble_tx_frame (0x20007AE0) and sends it byte by byte exactly as
@ v2.05 (index 0..18); queued command echoes (ble_tx_queue_put) go out between frames, never inside one.
@ While HSE is the system clock (SD card access) nothing is sent and received bytes are dropped, because
@ the USART baud rate divider was computed for MSI (NF-04).
@ The receive interrupt also clears an overrun that arrives with RXNE = 0 (OF-71) and feeds the extended link diagnosis
@ counters (ble/xdiag.s, IMP-44).
@ Context: main and USART2 interrupt as stated per routine.
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "hw.inc"
    .include "ram_v205.inc"
    .include "config.inc"

@ Module-local names of v2.05 RAM variables (address = the v_XXXXXXXX symbol of ram_v205.inc)
    .equ ble_tx_frame,          v_20007AE0   @ 19-byte status frame being transmitted
    .equ ble_rx_buf,            v_20007B80   @ USART2 receive buffer (up to 20 bytes)
    .equ ble_enable,            v_2000802B   @ BLE / serial transfer enabled (long PEAK)
    .equ ble_rx_idx,            v_2000802D   @ receive index
    .equ ble_rx_expect,         v_2000802E   @ expected length of the frame being received (5 or 15)
    .equ ble_rx_len,            v_2000802F   @ length of the last complete frame
    .equ ble_rx_ready,          v_20008030   @ a complete command frame is waiting
    .equ ble_tx_idx,            v_20008031   @ index of the byte of the status frame sent last

    .equ BLE_FRAME_LEN, 19              @ status frame length (analysis/ble_packet.md 3)
    .equ BLE_TXQ_LEN,   256             @ echo / answer queue size, power of two, at most 256 (the indices ble_txq_head and
                                        @ ble_txq_tail are bytes: ldrb / strb, masked with BLE_TXQ_LEN - 1 = 255).  The 0x82 answers of
                                        @ ble/bftsd.s are up to 243 bytes (IMP-36); with 64 bytes they could never be queued.  One
                                        @ slot always stays free (full = head + 1 == tail), so 255 bytes fit.
    .equ BLE_TX_IDLE,   0               @ nothing in transmission
    .equ BLE_TX_FRAME,  1               @ status frame being transmitted
    .equ BLE_TX_ECHO,   2               @ queued echo bytes being transmitted
    .equ BLE_SWS_HSE,   0x08            @ RCC_CFGR SWS = 10b: HSE is the system clock (RM0038 6.3.3)

    .section .bss_port.ble, "aw", %nobits
    .balign 4
@ BLE port RAM (owner BLE; DESIGN.md 5.1 .bss_port).  The v2.05 frame buffer ble_tx_frame (0x20007AE0) keeps its
@ address; the builder works in ble_frame_b and the transmit side copies it (OF-10).
    .global ble_frame_b
ble_frame_b:        .space 20           @ build buffer of the status frame (19 bytes used)
    .global ble_txq
ble_txq:            .space BLE_TXQ_LEN  @ ring of queued echo bytes
    .global ble_frame_ready
ble_frame_ready:    .space 1            @ 1 = ble_frame_b holds a complete frame not yet transmitted
    .global ble_tx_state
ble_tx_state:       .space 1            @ BLE_TX_IDLE / BLE_TX_FRAME / BLE_TX_ECHO
    .global ble_start_pending
ble_start_pending:  .space 1            @ a frame start was requested and has not begun yet
    .global ble_usart_on
ble_usart_on:       .space 1            @ 1 between the end of usart2_init and the start of usart2_deinit
    .global ble_txq_head
ble_txq_head:       .space 1            @ queue write index (main)
    .global ble_txq_tail
ble_txq_tail:       .space 1            @ queue read index (USART2 handler)

    .section .text.ble, "ax", %progbits

@ -----------------------------------------------------------------------------
@ ble_sysclk_is_hse - is HSE the system clock?
@ Replaces : nothing in v2.05 (new, NF-04)
@ In       : -
@ Out      : r0 = 1 if RCC_CFGR.SWS is not MSI (SD card access, sys_clock_select(1): PLL, or HSE as v2.05), else 0
@ Clobbers : r0, flags
@ Context  : ISR-safe
@ Spec     : RM0038 6.3.3 RCC_CFGR SWS; DESIGN.md 6.26 NF-04
@ -----------------------------------------------------------------------------
FUNC ble_sysclk_is_hse
    ldr r0, =RCC_CFGR                       @ clock configuration register
    ldr r0, [r0]
    ands r0, r0, #RCC_CFGR_SWS_MASK         @ SWS bits 3:2 = clock in use
    cmp r0, #0                              @ 00b = MSI: the baud rate was computed for it (IMP-41: a card session
    ite ne                                  @ runs on the PLL, v2.05 on HSE: both are "not MSI")
    movne r0, #1                            @ a card-session clock
    moveq r0, #0                            @ MSI
    bx lr
ENDFUNC ble_sysclk_is_hse
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_link_reset - clear the transmit and receive state of the link
@ Replaces : nothing in v2.05 (new, OF-10 / OF-11)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main only
@ RAM      : writes ble_tx_state, ble_start_pending, ble_frame_ready, ble_txq_head, ble_txq_tail, ble_tx_idx,
@            ble_rx_idx, ble_rx_expect, ble_rx_ready
@ -----------------------------------------------------------------------------
FUNC ble_link_reset
    mrs r3, primask                         @ the USART2 handler uses this state: mask it for the reset
    cpsid i
    movs r0, #0
    ldr r1, =ble_tx_state
    strb r0, [r1]                           @ idle
    ldr r1, =ble_start_pending
    strb r0, [r1]                           @ no frame start requested
    ldr r1, =ble_frame_ready
    strb r0, [r1]                           @ no complete frame
    ldr r1, =ble_txq_head
    strb r0, [r1]                           @ echo queue empty (head = tail = 0)
    ldr r1, =ble_txq_tail
    strb r0, [r1]
    ldr r1, =ble_tx_idx
    strb r0, [r1]                           @ v2.05 0x20008031
    ldr r1, =ble_rx_idx
    strb r0, [r1]                           @ receive parser at the start of a frame (v2.05 0x2000802D)
    ldr r1, =ble_rx_expect
    strb r0, [r1]                           @ no expected length (v2.05 0x2000802E)
    ldr r1, =ble_rx_ready
    strb r0, [r1]                           @ no command waiting (v2.05 0x20008030)
    msr primask, r3                         @ restore the interrupt mask
    bx lr
ENDFUNC ble_link_reset
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_tx_kick - start the transmit interrupt if something is waiting (also exported as ble_tx_tick)
@ Replaces : nothing in v2.05 (new, OF-10, NF-04)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : ISR-safe (TIM2 handler, main).  The CR1 update is done with interrupts masked.
@ Spec     : DESIGN.md 6.26; RM0038 27.6.4 (USART_CR1.TXEIE)
@ Note     : TXEIE is set only when the link is up, no transmission is running, the system clock is not HSE (NF-04)
@            and a frame start or an echo is waiting.  The TXE interrupt then fires at once (TXE = 1) and
@            ble_tx_pump sends the first byte.  W1 should call this routine on every TIM2 tick (ble_tx_tick) so a
@            start deferred by HSE use begins on the first tick back on MSI; without that call the deferred start
@            happens at the next count-50 call of ble_tx_start_frame.
@ -----------------------------------------------------------------------------
FUNC ble_tx_kick
    .global ble_tx_tick
    .thumb_set ble_tx_tick, ble_tx_kick
    push {r4, lr}
    ldr r0, =ble_usart_on
    ldrb r0, [r0]
    cbz r0, .Lkick_ret                      @ link down: nothing to start
    ldr r0, =ble_tx_state
    ldrb r0, [r0]
    cbnz r0, .Lkick_ret                     @ a transmission is running: the TXE interrupt continues it
    bl ble_sysclk_is_hse
    cbnz r0, .Lkick_ret                     @ NF-04: HSE in use, the baud rate is wrong, wait
    ldr r0, =ble_start_pending
    ldrb r0, [r0]
    cbnz r0, .Lkick_go                      @ a frame start is waiting
    ldr r0, =ble_txq_tail
    ldrb r0, [r0]
    ldr r1, =ble_txq_head
    ldrb r1, [r1]
    cmp r0, r1
    beq .Lkick_ret                          @ queue empty: nothing to send
.Lkick_go:
    mrs r3, primask                         @ read-modify-write of CR1 is shared with the USART2 handler
    cpsid i
    ldr r2, =USART2_BASE
    ldrh r0, [r2, #USART_CR1]
    orr r0, r0, #USART_CR1_TXEIE            @ TXE interrupt on
    strh r0, [r2, #USART_CR1]
    msr primask, r3
.Lkick_ret:
    pop {r4, pc}
ENDFUNC ble_tx_kick
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_tx_start_frame - request the transmission of the status frame (TIM2 count 50)
@ Replaces : 0x08024630..0x0802465A (inline in IRQ28_Handler 0x0802428C; OF-10)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : ISR-safe (called by sys_tim2_isr)
@ RAM      : reads ble_enable; writes ble_start_pending
@ Spec     : analysis/ble_packet.md 2; DESIGN.md 6.26
@ Deviation: OF-10 (the frame is copied from ble_frame_b by ble_tx_pump only when complete and no transmission is
@            running), NF-04 (deferred while HSE is the system clock)
@ Note     : v2.05 resets the transmit index, sends byte 0 and enables the TXE interrupt in the TIM2 handler
@            (0x08024630..0x08024658) whenever 0x2000802B is set.
@ -----------------------------------------------------------------------------
FUNC ble_tx_start_frame
    ldr r0, =bft_active
    ldrb r0, [r0]
    cbnz r0, .Lsf_ret                       @ IMP-28: no status frames while the page Ld owns the link
    ldr r0, =ble_enable
    ldrb r0, [r0]
    cbz r0, .Lsf_ret                        @ BLE off: nothing (v2.05 0x08024630)
    movs r0, #1
    ldr r1, =ble_start_pending
    strb r0, [r1]                           @ frame start requested
    push {lr}
    bl ble_tx_kick                          @ begin now unless busy or on the card-session clock
    pop {pc}
.Lsf_ret:
    bx lr
ENDFUNC ble_tx_start_frame
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_tx_queue_put - queue bytes for transmission after the frame in progress
@ Replaces : nothing in v2.05 (new, OF-10: v2.05 sends command echoes from the main loop with blocking USART_SendData
@            calls that can interleave with a status frame, 0x0800C308)
@ In       : r0 = pointer to the bytes, r1 = count
@ Out      : r0 = 0 queued, 1 refused (link down, or the queue lacks room: nothing is queued)
@ Clobbers : r0-r3, r12, flags (r4-r6 saved)
@ Context  : main only
@ RAM      : writes ble_txq, ble_txq_head; reads ble_txq_tail, ble_usart_on; xd_tx_q_full (xd_inc, IMP-44)
@ Note     : a refusal for lack of room is counted in xd_tx_q_full while the extended diagnosis is on; the refusal because
@            the link is down is not (nothing could ever have been sent).
@ -----------------------------------------------------------------------------
FUNC ble_tx_queue_put
    push {r4-r6, lr}
    mov r6, r0                              @ source pointer
    ldr r2, =ble_usart_on
    ldrb r2, [r2]
    cbz r2, .Lqp_refuse                     @ link down: the bytes could never be sent
    ldr r2, =ble_txq_head
    ldrb r4, [r2]                           @ head
    ldr r3, =ble_txq_tail
    ldrb r3, [r3]                           @ tail
    subs r3, r3, r4
    subs r3, r3, #1
    ands r3, r3, #(BLE_TXQ_LEN - 1)         @ free bytes = (tail - head - 1) mod size
    cmp r1, r3
    bhi .Lqp_full                           @ not enough room: queue nothing
    ldr r5, =ble_txq
.Lqp_loop:
    cbz r1, .Lqp_done                       @ all bytes copied
    ldrb r0, [r6], #1                       @ next source byte
    strb r0, [r5, r4]                       @ ble_txq[head]
    adds r4, r4, #1
    ands r4, r4, #(BLE_TXQ_LEN - 1)         @ head = (head + 1) mod size
    subs r1, r1, #1
    b .Lqp_loop
.Lqp_done:
    strb r4, [r2]                           @ publish the new head after the data (the handler reads up to head)
    bl ble_tx_kick                          @ start the TXE interrupt if idle
    movs r0, #0
    pop {r4-r6, pc}
.Lqp_full:
    ldr r0, =xd_tx_q_full
    bl xd_inc                               @ IMP-44: the queue lacked room (counted while the diagnosis is on)
.Lqp_refuse:
    movs r0, #1
    pop {r4-r6, pc}
ENDFUNC ble_tx_queue_put
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_tx_pump - one TXE event: send the next byte or stop
@ Replaces : the TXE branch of IRQ38_Handler 0x080247D8 (0x080247E8..0x08024810) and the inline first-byte send of
@            IRQ28_Handler 0x08024630..0x08024658
@ In       : -  (called with TXEIE and TXE set)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ Context  : USART2 interrupt
@ RAM      : ble_tx_state, ble_tx_idx, ble_tx_frame, ble_frame_b, ble_frame_ready, ble_start_pending, ble_txq,
@            ble_txq_tail (writes), ble_txq_head (reads)
@ Spec     : analysis/ble_packet.md 2 (TXE branch: idx++, send buf[idx] while idx < 0x13, else TXE interrupt off);
@            DESIGN.md 6.26
@ Deviation: OF-10 (frame snapshot in ble_tx_frame taken only for a complete frame, echo bytes only between frames),
@            NF-04 (nothing is sent while HSE is the system clock)
@ Note     : If HSE becomes the system clock while a frame is being sent, the frame is abandoned and the state set
@            to idle (otherwise nothing would ever restart the interrupt).
@            Every path either writes one byte to USART2_DR (through fn_0800D170) or clears TXEIE, so the interrupt
@            cannot repeat without making progress.
@ -----------------------------------------------------------------------------
FUNC ble_tx_pump
    push {r4, r5, lr}
    ldr r4, =USART2_BASE
    ldr r0, =ble_usart_on
    ldrb r0, [r0]
    cmp r0, #0
    beq .Lpump_stop                         @ link down: only switch the interrupt off
    bl ble_sysclk_is_hse
    cmp r0, #0
    bne .Lpump_hse                          @ NF-04: HSE in use, transmit later (ble_tx_kick restarts)
    ldr r5, =ble_tx_state
    ldrb r0, [r5]
    cmp r0, #BLE_TX_FRAME
    bne .Lpump_idle_echo                    @ no status frame in transmission
    ldr r2, =ble_tx_idx                     @ v2.05 0x20008031
    ldrb r3, [r2]
    adds r3, r3, #1                         @ idx++ (v2.05 0x080247F2..0x080247FA)
    strb r3, [r2]
    cmp r3, #BLE_FRAME_LEN
    bhs .Lpump_framedone                    @ idx >= 19: the frame is complete (v2.05 0x08024800)
    ldr r1, =ble_tx_frame
    ldrb r1, [r1, r3]                       @ next byte of the frame (v2.05 0x08024812..0x08024818)
    b .Lpump_send
.Lpump_framedone:
    movs r0, #BLE_TX_IDLE
    strb r0, [r5]                           @ the frame is finished
.Lpump_idle_echo:
    ldrb r0, [r5]
    cmp r0, #BLE_TX_ECHO
    beq .Lpump_echo                         @ echo bytes in transmission
.Lpump_idle:
    ldr r2, =ble_start_pending
    ldrb r0, [r2]
    cbz r0, .Lpump_queue                    @ no frame start requested
    movs r0, #0
    strb r0, [r2]                           @ the request is consumed now
    ldr r2, =ble_frame_ready
    ldrb r0, [r2]
    cbz r0, .Lpump_queue                    @ no complete frame (not built, or the value was invalid, OF-34)
    movs r0, #0
    strb r0, [r2]                           @ the frame is taken
    ldr r1, =ble_frame_b
    ldr r2, =ble_tx_frame
    movs r3, #BLE_FRAME_LEN
.Lpump_copy:
    ldrb r0, [r1], #1
    strb r0, [r2], #1                       @ ble_tx_frame = snapshot of the complete frame (OF-10)
    subs r3, r3, #1
    bne .Lpump_copy
    movs r0, #0
    ldr r2, =ble_tx_idx
    strb r0, [r2]                           @ v2.05 0x08024638: transmit index = 0
    movs r0, #BLE_TX_FRAME
    strb r0, [r5]                           @ frame in transmission
    ldr r1, =ble_tx_frame
    ldrb r1, [r1]                           @ byte 0 = 0xF2 (v2.05 0x0802464C)
    b .Lpump_send
.Lpump_queue:
    ldr r2, =ble_txq_tail
    ldr r3, =ble_txq_head
    ldrb r0, [r2]
    ldrb r1, [r3]
    cmp r0, r1
    beq .Lpump_stop                         @ queue empty: nothing more to send
    movs r0, #BLE_TX_ECHO
    strb r0, [r5]                           @ echo bytes in transmission
.Lpump_echo:
    ldr r2, =ble_txq_tail
    ldr r3, =ble_txq_head
    ldrb r0, [r2]                           @ tail
    ldrb r1, [r3]                           @ head
    cmp r0, r1
    beq .Lpump_echodone                     @ queue drained
    ldr r1, =ble_txq
    ldrb r1, [r1, r0]                       @ next queued byte
    adds r0, r0, #1
    ands r0, r0, #(BLE_TXQ_LEN - 1)         @ tail = (tail + 1) mod size
    strb r0, [r2]
    b .Lpump_send
.Lpump_echodone:
    movs r0, #BLE_TX_IDLE
    strb r0, [r5]                           @ echo finished: a waiting frame start may go next
    b .Lpump_idle
.Lpump_hse:
    ldr r5, =ble_tx_state
    movs r0, #BLE_TX_IDLE
    strb r0, [r5]                           @ NF-04: a half-sent frame is abandoned (the receiver resynchronises on 0xF2);
                                            @ queued echo bytes stay queued and ble_tx_kick resumes them on MSI
.Lpump_stop:
    ldrh r0, [r4, #USART_CR1]
    bic r0, r0, #USART_CR1_TXEIE            @ TXE interrupt off (v2.05 0x0802480C: USART_ITConfig(0x727, 0))
    strh r0, [r4, #USART_CR1]
    pop {r4, r5, pc}
.Lpump_send:
    mov r0, r4                              @ USART2
    bl fn_0800D170                          @ send r1 (bounded wait for TXE)
    pop {r4, r5, pc}
ENDFUNC ble_tx_pump
    .ltorg

@ -----------------------------------------------------------------------------
@ ble_usart2_isr - USART2 interrupt (IRQ 38)
@ Replaces : 0x080247D8 IRQ38_Handler (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (hardware stacking; r4-r6 saved)
@ Context  : USART2 interrupt, priority 0
@ RAM      : reads ble_usart_on; writes ble_rx_buf, ble_rx_idx, ble_rx_expect, ble_rx_len, ble_rx_ready; the extended
@            diagnosis counters (xd_*, ble/xdiag.s)
@ Spec     : analysis/ble_packet.md 6 (receive side); DESIGN.md 6.26; RM0038 27.3.3 (overrun error), 27.6.1 (SR.ORE)
@ Deviation: OF-10 (TXE branch moved to ble_tx_pump), NF-04 (bytes received while HSE is the system clock are
@            discarded and the parser is reset), OF-71 (an overrun flag with RXNE = 0 is cleared, below), IMP-44 (counters)
@ Note     : TXE branch: v2.05 0x080247DA..0x08024810 (GetITStatus 0x727).  RXNE branch: 0x08024820..0x080248AE
@            (GetITStatus 0x525).  Parser: byte stored at buf[idx], idx wraps at 20; with idx = 1 the first byte
@            selects the expected length (0xF4: 5, 0xF8: 15, else resynchronise); a frame is complete when
@            idx >= expected.
@            OF-71: v2.05 asks USART_GetITStatus(0x525) (0x0801CC7C), which is true only when SR.RXNE and CR1.RXNEIE are
@            both set, and returns without a DR read otherwise.  RM0038 27.3.3: the RXNEIE interrupt is also generated by
@            ORE, and "if RXNE=0 ... the new data is received during the reading sequence (between the USART_SR register
@            read access and the USART_DR read access)": ORE is then set with RXNE = 0 and only SR read then DR read
@            clears it.  Without that DR read the interrupt fires again at once for ever (the main loop starves).  Here
@            r6 holds the SR value read for the sequence; with RXNE = 0, ORE = 1 and RXNEIE = 1 the DR is read once and
@            the (lost) byte is dropped, counted as an overrun.
@ -----------------------------------------------------------------------------
FUNC ble_usart2_isr
    push {r4, r5, r6, lr}
    ldr r4, =USART2_BASE
    ldrh r0, [r4, #USART_SR]
    ldrh r1, [r4, #USART_CR1]
    tst r0, #USART_SR_TXE
    beq .Lisr_rx                            @ TXE not set
    tst r1, #USART_CR1_TXEIE
    beq .Lisr_rx                            @ TXE interrupt not enabled
    bl ble_tx_pump                          @ send the next byte or stop
.Lisr_rx:
    ldrh r6, [r4, #USART_SR]                @ r6 = SR: the first half of the "read SR, then read DR" clearing sequence
    ldrh r1, [r4, #USART_CR1]
    tst r6, #USART_SR_RXNE
    bne .Lisr_byte                          @ a received byte is waiting
    tst r6, #USART_SR_ORE
    beq .Lisr_done                          @ neither a received byte nor an overrun
    tst r1, #USART_CR1_RXNEIE
    beq .Lisr_done                          @ RXNE interrupt not enabled: the overrun raises no interrupt (RM0038 27.3.3)
    @ OF-71: ORE with RXNE = 0 (the byte that overran was lost, nothing is left to read).  The SR read above and this DR
    @ read are the sequence that clears ORE (RM0038 27.6.1); without them the interrupt line stays active.
    ldrh r0, [r4, #USART_DR]                @ value not used: the byte is dropped
    mov r0, r6
    movs r1, #0                             @ no received byte, only the overrun is counted
    bl xd_rx_account
    b .Lisr_done
.Lisr_byte:
    tst r1, #USART_CR1_RXNEIE
    beq .Lisr_done                          @ RXNE interrupt not enabled
    ldrh r5, [r4, #USART_DR]                @ received byte (the read clears RXNE; v2.05 0x08024830)
    uxtb r5, r5                             @ the buffer holds bytes (v2.05 stores the low byte)
    movw r0, #0xFFDF                        @ complement of the RXNE bit (bit 5): rc_w0 clear of RXNE only
    strh r0, [r4, #USART_SR]                @ v2.05 0x08024842 clears the RXNE flag again (USART_ClearITPendingBit)
    mov r0, r6                              @ IMP-44: count the byte and the error flags of its SR value
    movs r1, #1
    bl xd_rx_account
    ldr r0, =ble_usart_on
    ldrb r0, [r0]
    cbz r0, .Lisr_done                      @ link down: drop the byte
    bl ble_sysclk_is_hse
    cbz r0, .Lrx_store
    ldr r0, =xd_rx_dropped_hse
    bl xd_inc                               @ IMP-44: the byte is discarded (counted while the diagnosis is on)
    ldr r1, =ble_rx_idx
    movs r0, #0
    strb r0, [r1]                           @ NF-04: HSE in use, discard the byte and restart the frame
    b .Lisr_done
.Lrx_store:
    ldr r0, =bft_active
    ldrb r0, [r0]
    cbz r0, .Lrx_legacy
    mov r0, r5
    bl bft_rx_byte                          @ IMP-28: the page Ld owns the link, every byte goes to its ring
    b .Lisr_done
.Lrx_legacy:
    ldr r1, =ble_rx_buf
    ldr r2, =ble_rx_idx
    ldrb r3, [r2]
    cmp r3, #20
    blo .Lrx_idx_valid
    movs r3, #0                             @ index damaged (v2.05 would store past the 20-byte buffer): restart the frame
.Lrx_idx_valid:
    strb r5, [r1, r3]                       @ buf[idx] = byte (v2.05 0x0802483A)
    adds r3, r3, #1                         @ idx++ (v2.05 0x0802484A)
    cmp r3, #20
    blo .Lrx_idx_ok
    movs r3, #0                             @ the buffer holds 20 bytes: wrap (v2.05 0x08024854..0x0802485C)
.Lrx_idx_ok:
    strb r3, [r2]
    cmp r3, #1
    bne .Lrx_more                           @ not the first byte of a frame
    ldrb r0, [r1]                           @ first byte (v2.05 0x08024866..0x0802486A)
    cmp r0, #0xF4
    bne .Lrx_not_key
    movs r0, #5                             @ 0xF4: key frame, 5 bytes
    ldr r1, =ble_rx_expect
    strb r0, [r1]
    b .Lisr_done
.Lrx_not_key:
    cmp r0, #0xF8
    bne .Lrx_resync
    movs r0, #15                            @ 0xF8: set-clock frame, 15 bytes
    ldr r1, =ble_rx_expect
    strb r0, [r1]
    b .Lisr_done
.Lrx_resync:
    movs r0, #0                             @ any other first byte: ignore it (v2.05 0x08024886)
    strb r0, [r2]
    b .Lisr_done
.Lrx_more:
    ldr r0, =ble_rx_expect
    ldrb r0, [r0]
    cmp r3, r0
    blo .Lisr_done                          @ frame not complete (v2.05 0x08024896 bcc)
    movs r1, #1
    ldr r3, =ble_rx_ready
    strb r1, [r3]                           @ command waiting (v2.05 0x2000802B0 area: 0x20008030)
    ldr r3, =ble_rx_len
    strb r0, [r3]                           @ length of the frame = expected length
    movs r0, #0
    strb r0, [r2]                           @ next frame starts at index 0
.Lisr_done:
    pop {r4, r5, r6, pc}
ENDFUNC ble_usart2_isr
    .ltorg

@ -----------------------------------------------------------------------------
@ usart2_init_19200_pf15_high - power the BLE module and start USART2 at 19200 baud, 8N1
@ Replaces : 0x0801C390 usart2_init_19200_pf15_high (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0800C51A, BLE enable)
@ Spec     : analysis/ble_packet.md 1; DESIGN.md 4.2 (PD5/PD6), 4.3 (PF15 before PD5/PD6 become AF7)
@ Deviation: pins configured with brd_gpio_init (replaces gpio_init and two gpio_set_alternate_function calls: AF
@            number and mode in one policy-checked write); OF-10/OF-11 link state reset first; TXEIE cleared
@            explicitly; ble_usart_on set last
@ Note     : Order as v2.05: PF15 high (BLE module supply), GPIOD clock, PD5/PD6 AF7 with pull-up (PD6 is the RX line
@            driven by the module, PD5 TX), USART2 clock, USART_Init (19200, 8N1, TX and RX), USART enable, RXNE
@            interrupt on, NVIC IRQ 38 on.  The baud rate divider is computed once from RCC_GetClocksFreq (PCLK1), as
@            in v2.05 (NF-04: the rate is wrong while HSE is the system clock, so the link is idle then).
@ -----------------------------------------------------------------------------
FUNC usart2_init_19200_pf15_high
    push {lr}                               @ 0801C390
    bl ble_link_reset                    @ OF-10/OF-11: clean transmit and receive state before anything is enabled
    sub sp, #0x1c                           @ 0801C392
    mov r0, #0x8000                         @ 0801C394
    ldr.w r1, =(GPIOF_BASE + GPIO_BSRRL)    @ 0801C398
    strh r0, [r1, #0x0]                     @ 0801C39C  [(GPIOF_BASE + GPIO_BSRRL)] = 32768 (0x8000)
    movs r1, #0x1                           @ 0801C39E
    movs r0, #0x8                           @ 0801C3A0
    bl fn_0801FF80                          @ 0801C3A2  RCC_AHBPeriphClockCmd, r0 = peripheral mask, r1 = enable [r0=8, r1=1]
    ldr.w r0, =GPIOD_BASE                @ PD5 (USART2_TX), PD6 (USART2_RX): AF7, pull-up (v2.05 0x0801C3A6..0x0801C3E0)
    ldr.w r1, =ble_desc_usart_pins
    bl brd_gpio_init                     @ policy-checked: PD6 only AF7 (DESIGN.md 4.2)
    movs r1, #0x1                           @ 0801C3E4
    movs r0, #0x20000                       @ 0801C3E6
    bl fn_0801FFBC                          @ 0801C3EA  RCC_APB1PeriphClockCmd, r0 = peripheral mask, r1 = enable [r0=0x20000, r1=1]
    mov r0, #0x4b00                         @ 0801C3EE
    str r0, [sp, #0x8]                      @ 0801C3F2  local [sp+8] = 19200 (0x4B00)
    movs r0, #0x0                           @ 0801C3F4
    strh r0, [sp, #0xc]                     @ 0801C3F6  local [sp+12] = 0
    movs r0, #0x0                           @ 0801C3FA
    strh r0, [sp, #0xe]                     @ 0801C3FC  local [sp+14] = 0
    movs r0, #0x0                           @ 0801C400
    strh r0, [sp, #0x10]                    @ 0801C402  local [sp+16] = 0
    movs r0, #0x0                           @ 0801C406
    strh r0, [sp, #0x14]                    @ 0801C408  local [sp+20] = 0
    movs r0, #0xc                           @ 0801C40C
    strh r0, [sp, #0x12]                    @ 0801C40E  local [sp+18] = 12 (0xC)
    add r1, sp, #0x8                        @ 0801C412  r1 = address of local + 8
    ldr.w r0, =USART2_BASE                  @ 0801C414
    bl fn_0801CAEC                          @ 0801C418  USART_Init [r1=(address of local + 8)]
    movs r2, #0
    movw r1, #0x727
    ldr.w r0, =USART2_BASE
    bl fn_0801CC08                       @ TXE interrupt off (USART_Init keeps a stale TXEIE of an earlier session)
    movs r1, #0x1                           @ 0801C41C
    ldr.w r0, =USART2_BASE                  @ 0801C41E
    bl fn_0801CBDC                          @ 0801C422  USART_Cmd [r1=1]
    movs r2, #0x1                           @ 0801C426
    movw r1, #0x525                         @ 0801C428
    ldr.w r0, =USART2_BASE                  @ 0801C42C
    bl fn_0801CC08                          @ 0801C430  USART_ITConfig [r1=1317 (0x525), r2=1]
    movs r0, #0x26                          @ 0801C434
    bl fn_0801BE60                          @ 0801C436  NVIC_EnableIRQ-style call, r0 = IRQ number [r0=38 (0x26)]
    movs r0, #1
    ldr r1, =ble_usart_on
    strb r0, [r1]                        @ the link is up: the handlers may transmit and receive
    add sp, #0x1c                           @ 0801C43A
    pop {pc}                                @ 0801C43C
ENDFUNC usart2_init_19200_pf15_high
    .ltorg

@ -----------------------------------------------------------------------------
@ usart2_deinit_pf15_low - stop USART2 and switch the BLE module off
@ Replaces : 0x0801C954 usart2_deinit_pf15_low (v2.05)
@ In       : -
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0800C51A, BLE disable; BRD power-down)
@ Spec     : analysis/ble_packet.md 1; DESIGN.md 4.3 (PF15 low first at deinit)
@ Deviation: OF-10: the link state is cleared first (ble_usart_on = 0), and the TXE interrupt is switched off with the
@            RXNE interrupt, so a transmission cut off by the disable cannot resume after the next enable
@ Note     : PF15 low (module off), RXNE and TXE interrupts off, USART disabled, USART2 clock off (v2.05
@            0x0801C956..0x0801C978).
@ -----------------------------------------------------------------------------
FUNC usart2_deinit_pf15_low
    push {r7, lr}                           @ 0801C954
    movs r0, #0
    ldr r1, =ble_usart_on
    strb r0, [r1]                        @ link down first: the USART2 handler stops using the link
    bl ble_link_reset                    @ and the transmit / receive state is cleared
    mov r0, #0x8000                         @ 0801C956
    ldr.w r1, =(GPIOF_BASE + GPIO_BSRRH)    @ 0801C95A
    strh r0, [r1, #0x0]                     @ 0801C95C  [(GPIOF_BASE + GPIO_BSRRH)] = 32768 (0x8000)
    movs r2, #0x0                           @ 0801C95E
    movw r1, #0x525                         @ 0801C960
    ldr.w r0, =USART2_BASE                  @ 0801C964
    bl fn_0801CC08                          @ 0801C966  USART_ITConfig [r1=1317 (0x525), r2=0]
    movs r2, #0
    movw r1, #0x727
    ldr.w r0, =USART2_BASE
    bl fn_0801CC08                       @ TXE interrupt off as well
    movs r1, #0x0                           @ 0801C96A
    ldr.w r0, =USART2_BASE                  @ 0801C96C
    bl fn_0801CBDC                          @ 0801C96E  USART_Cmd [r1=0]
    movs r1, #0x0                           @ 0801C972
    movs r0, #0x20000                       @ 0801C974
    bl fn_0801FFBC                          @ 0801C978  RCC_APB1PeriphClockCmd, r0 = peripheral mask, r1 = enable [r0=0x20000, r1=0]
    pop {r0, pc}                            @ 0801C97C
ENDFUNC usart2_deinit_pf15_low
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CAEC - USART_Init (StdPeriph)
@ Replaces : 0x0801CAEC FUN_0801CAEC (v2.05)
@ In       : r0 = USART base, r1 = pointer to {baud u32, wordlength u16, stopbits u16, parity u16, mode u16, hwflow
@            u16}
@ Out      : -
@ Clobbers : r0-r3, r12, flags (r4-r9 saved)
@ Context  : main only
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : Writes CR2 stop bits, CR1 word length / parity / mode, CR3 flow control, and BRR from the PCLK of
@            RCC_GetClocksFreq (integer and fractional part for oversampling by 16, or by 8 when CR1.OVER8 is set).
@ -----------------------------------------------------------------------------
FUNC fn_0801CAEC
    push {r4, r5, r6, r7, r8, r9, lr}       @ 0801CAEC
    sub sp, #0x14                           @ 0801CAF0
    movs r4, r0                             @ 0801CAF2
    movs r5, r1                             @ 0801CAF4
    movs r9, #0x0                           @ 0801CAF6
    movs r6, #0x0                           @ 0801CAFA
    movs r7, #0x0                           @ 0801CAFC
    movs r8, #0x0                           @ 0801CAFE
    ldrh r0, [r5, #0xc]                     @ 0801CB02  r0 = [r5+12]
    cmp r0, #0x0                            @ 0801CB04  compare r0 with 0
    ldrh r0, [r4, #0x10]                    @ 0801CB06  r0 = [r4+16]
    mov r9, r0                              @ 0801CB08
    bics r9, r9, #0x3000                    @ 0801CB0A  r9 = r9 &~ 12288 (0x3000)
    ldrh r0, [r5, #0x6]                     @ 0801CB0E  r0 = [r5+6]
    orrs r9, r0, r9                         @ 0801CB10  r9 = r0 | (r9 &~ 12288 (0x3000))
    strh r9, [r4, #0x10]                    @ 0801CB14  [r4+16] = (r0 | (r9 &~ 12288 (0x3000)))
    ldrh r0, [r4, #0xc]                     @ 0801CB18  r0 = [r4+12]
    mov r9, r0                              @ 0801CB1A
    ldr.w r0, =0xFFFFE9F3                   @ 0801CB1C
    ands r9, r0, r9                         @ 0801CB1E  r9 = 0xFFFFE9F3 & r9
    ldrh r0, [r5, #0x4]                     @ 0801CB22  r0 = [r5+4]
    ldrh r1, [r5, #0x8]                     @ 0801CB24  r1 = [r5+8]
    orrs r0, r1                             @ 0801CB26  r0 = r0 | r1
    ldrh r1, [r5, #0xa]                     @ 0801CB28  r1 = [r5+10]
    orrs r0, r1                             @ 0801CB2A  r0 = (r0 | r1) | r1
    orrs r9, r0, r9                         @ 0801CB2C  r9 = ((r0 | r1) | r1) | (0xFFFFE9F3 & r9)
    strh r9, [r4, #0xc]                     @ 0801CB30  [r4+12] = (((r0 | r1) | r1) | (0xFFFFE9F3 & r9))
    ldrh r0, [r4, #0x14]                    @ 0801CB34  r0 = [r4+20]
    mov r9, r0                              @ 0801CB36
    bics r9, r9, #0x300                     @ 0801CB38  r9 = r9 &~ 768 (0x300)
    ldrh r0, [r5, #0xc]                     @ 0801CB3C  r0 = [r5+12]
    orrs r9, r0, r9                         @ 0801CB3E  r9 = r0 | (r9 &~ 768 (0x300))
    strh r9, [r4, #0x14]                    @ 0801CB42  [r4+20] = (r0 | (r9 &~ 768 (0x300)))
    mov r0, sp                              @ 0801CB46
    bl fn_0801FE2A                          @ 0801CB48  RCC_GetClocksFreq, r0 = result structure
    ldr.w r0, =0x40013800                   @ 0801CB4C
    cmp r4, r0                              @ 0801CB4E  compare r4 with 0x40013800
    bne .L0801CB58                          @ 0801CB50  if r4 != 0x40013800
    ldr r0, [sp, #0xc]                      @ 0801CB52  r0 = local [sp+12]
    movs r6, r0                             @ 0801CB54
    b .L0801CB5C                            @ 0801CB56
.L0801CB58:  @ reached from 0801CB50 bne (r4 != 0x40013800)
    ldr r0, [sp, #0x8]                      @ 0801CB58  r0 = local [sp+8]
    movs r6, r0                             @ 0801CB5A
.L0801CB5C:  @ reached from 0801CB56 b
    ldrh r0, [r4, #0xc]                     @ 0801CB5C  r0 = [r4+12]
    lsls r0, r0, #0x10                      @ 0801CB5E  r0 = r0 << 16 (0x10)
    bpl .L0801CB74                          @ 0801CB60  if bit 15 of r0 is clear
    movs r0, #0x19                          @ 0801CB62
    mul r0, r0, r6                          @ 0801CB64  r0 = 25 (0x19) * r6
    ldr r1, [r5, #0x0]                      @ 0801CB68  r1 = [r5]
    lsls r1, r1, #0x1                       @ 0801CB6A  r1 = r1 << 1
    udiv r0, r0, r1                         @ 0801CB6C  r0 = (25 (0x19) * r6) / (r1 << 1)
    movs r7, r0                             @ 0801CB70
    b .L0801CB84                            @ 0801CB72
.L0801CB74:  @ reached from 0801CB60 bpl (bit 15 of r0 is clear)
    movs r0, #0x19                          @ 0801CB74
    mul r0, r0, r6                          @ 0801CB76  r0 = 25 (0x19) * r6
    ldr r1, [r5, #0x0]                      @ 0801CB7A  r1 = [r5]
    lsls r1, r1, #0x2                       @ 0801CB7C  r1 = r1 << 2
    udiv r0, r0, r1                         @ 0801CB7E  r0 = (25 (0x19) * r6) / (r1 << 2)
    movs r7, r0                             @ 0801CB82
.L0801CB84:  @ reached from 0801CB72 b
    movs r0, #0x64                          @ 0801CB84
    udiv r0, r7, r0                         @ 0801CB86  r0 = r7 / 100 (0x64)
    lsls r0, r0, #0x4                       @ 0801CB8A  r0 = (r7 / 100 (0x64)) << 4
    mov r9, r0                              @ 0801CB8C
    lsrs r0, r9, #0x4                       @ 0801CB8E  r0 = ((r7 / 100 (0x64)) << 4) >> 4
    movs r1, #0x64                          @ 0801CB92
    mls r0, r1, r0, r7                      @ 0801CB94  r0 = r7 - 100 (0x64) * (((r7 / 100 (0x64)) << 4) >> 4)
    mov r8, r0                              @ 0801CB98
    ldrh r0, [r4, #0xc]                     @ 0801CB9A  r0 = [r4+12]
    lsls r0, r0, #0x10                      @ 0801CB9C  r0 = r0 << 16 (0x10)
    bpl .L0801CBB6                          @ 0801CB9E  if bit 15 of r0 is clear
    lsls r0, r8, #0x3                       @ 0801CBA0  r0 = (r7 - 100 (0x64) * (((r7 / 100 (0x64)) << 4) >> 4)) << 3
    adds r0, #0x32                          @ 0801CBA4  r0 = ((r7 - 100 (0x64) * (((r7 / 100 (0x64)) << 4) >> 4)) << 3) + 50 (0x32)
    movs r1, #0x64                          @ 0801CBA6
    udiv r0, r0, r1                         @ 0801CBA8  r0 = (((r7 - 100 (0x64) * (((r7 / 100 (0x64)) << 4) >> 4)) << 3) + 50 (0x32)) / 100 (0x64)
    @ OF-72: v2.05 masks the rounded fraction with & 7 (0x0801CBAC) and loses the carry when it rounds up to 8:
    @ BRR is then one mantissa step (16) too low.  The fraction 8 is a carry into the mantissa (BRR bit 3 stays 0
    @ with OVER8, RM0038 27.6.3).
    cmp r0, #8
    it eq
    moveq r0, #0x10                         @ fraction 8 = mantissa + 1, fraction 0
    add r9, r9, r0
    b .L0801CBCA                            @ 0801CBB4
.L0801CBB6:  @ reached from 0801CB9E bpl (bit 15 of r0 is clear)
    lsls r0, r8, #0x4                       @ 0801CBB6  r0 = r8 << 4
    adds r0, #0x32                          @ 0801CBBA  r0 = (r8 << 4) + 50 (0x32)
    movs r1, #0x64                          @ 0801CBBC
    udiv r0, r0, r1                         @ 0801CBBE  r0 = ((r8 << 4) + 50 (0x32)) / 100 (0x64)
    @ OF-72: v2.05 masks the rounded fraction with & 15 (0x0801CBC2) and loses the carry when it rounds up to 16
    @ (PCLK1 4.2916 .. 4.3008 MHz at 19200): BRR 16 too low, the baud 7 % too high.  Adding it carries into the
    @ mantissa (fraction 0 .. 16, mantissa in bits 15:4).
    add r9, r9, r0
.L0801CBCA:  @ reached from 0801CBB4 b
    strh r9, [r4, #0x8]                     @ 0801CBCA  [r4+8] = r9
    add sp, #0x14                           @ 0801CBCE
    pop {r4, r5, r6, r7, r8, r9, pc}        @ 0801CBD0
ENDFUNC fn_0801CAEC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CBDC - USART_Cmd (StdPeriph)
@ Replaces : 0x0801CBDC FUN_0801CBDC (v2.05)
@ In       : r0 = USART base, r1 = enable (0/1)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main only
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : Sets or clears CR1.UE.
@ -----------------------------------------------------------------------------
FUNC fn_0801CBDC
    uxtb r1, r1                             @ 0801CBDC
    cmp r1, #0x0                            @ 0801CBDE  compare r1 with 0
    beq .L0801CBEC                          @ 0801CBE0  if r1 == 0
    ldrh r2, [r0, #0xc]                     @ 0801CBE2  r2 = [r0+12]
    orrs r2, r2, #0x2000                    @ 0801CBE4  r2 = r2 | 8192 (0x2000)
    strh r2, [r0, #0xc]                     @ 0801CBE8  [r0+12] = (r2 | 8192 (0x2000))
    b .L0801CBF6                            @ 0801CBEA
.L0801CBEC:  @ reached from 0801CBE0 beq (r1 == 0)
    ldrh r2, [r0, #0xc]                     @ 0801CBEC  r2 = [r0+12]
    movw r3, #0xdfff                        @ 0801CBEE
    ands r2, r3                             @ 0801CBF2  r2 = r2 & 57343 (0xDFFF)
    strh r2, [r0, #0xc]                     @ 0801CBF4  [r0+12] = (r2 & 57343 (0xDFFF))
.L0801CBF6:  @ reached from 0801CBEA b
    bx lr                                   @ 0801CBF6
ENDFUNC fn_0801CBDC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CBF8 - USART_SendData (StdPeriph)
@ Replaces : 0x0801CBF8 FUN_0801CBF8 (v2.05)
@ In       : r0 = USART base, r1 = value (9 bits)
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main and ISR (USART2 handler, ble_tx_pump)
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : Writes DR & 0x1FF.
@ -----------------------------------------------------------------------------
FUNC fn_0801CBF8
    lsls r2, r1, #0x17                      @ 0801CBF8  r2 = r1 << 23 (0x17)
    lsrs r2, r2, #0x17                      @ 0801CBFA  r2 = (r1 << 23 (0x17)) >> 23 (0x17)
    strh r2, [r0, #0x4]                     @ 0801CBFC  [r0+4] = ((r1 << 23 (0x17)) >> 23 (0x17))
    bx lr                                   @ 0801CBFE
ENDFUNC fn_0801CBF8
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CC00 - USART_ReceiveData (StdPeriph)
@ Replaces : 0x0801CC00 FUN_0801CC00 (v2.05)
@ In       : r0 = USART base
@ Out      : r0 = DR & 0x1FF
@ Clobbers : r0-r3, flags
@ Context  : main and ISR (USART2 handler, ble_tx_pump)
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : Reading DR clears RXNE.
@ -----------------------------------------------------------------------------
FUNC fn_0801CC00
    ldrh r0, [r0, #0x4]                     @ 0801CC00  r0 = [r0+4]
    lsls r0, r0, #0x17                      @ 0801CC02  r0 = r0 << 23 (0x17)
    lsrs r0, r0, #0x17                      @ 0801CC04  r0 = (r0 << 23 (0x17)) >> 23 (0x17)
    bx lr                                   @ 0801CC06
ENDFUNC fn_0801CC00
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CC08 - USART_ITConfig (StdPeriph)
@ Replaces : 0x0801CC08 FUN_0801CC08 (v2.05)
@ In       : r0 = USART base, r1 = interrupt code (register index << 5 | bit, flag number << 8), r2 = enable
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main only
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : The code 0x525 selects CR1 bit 5 (RXNEIE), 0x727 CR1 bit 7 (TXEIE).
@ -----------------------------------------------------------------------------
FUNC fn_0801CC08
    push {r4, r5, r6, r7}                   @ 0801CC08
    movs r3, #0x0                           @ 0801CC0A
    movs r4, #0x0                           @ 0801CC0C
    movs r5, #0x0                           @ 0801CC0E
    movs r6, #0x0                           @ 0801CC10
    uxth r1, r1                             @ 0801CC12
    movw r7, #0x96a                         @ 0801CC14
    cmp r1, r7                              @ 0801CC18  compare r1 with 2410 (0x96A)
    movs r6, r0                             @ 0801CC1A
    movs r7, r1                             @ 0801CC1C
    uxtb r7, r7                             @ 0801CC1E
    lsrs r7, r7, #0x5                       @ 0801CC20  r7 = r7 >> 5
    uxtb r7, r7                             @ 0801CC22
    movs r3, r7                             @ 0801CC24
    uxth r1, r1                             @ 0801CC26
    ands r7, r1, #0x1f                      @ 0801CC28  r7 = r1 & 31 (0x1F)
    movs r4, r7                             @ 0801CC2C
    movs r7, #0x1                           @ 0801CC2E
    lsls r7, r4                             @ 0801CC30  r7 = 1 << (r1 & 31 (0x1F))
    movs r5, r7                             @ 0801CC32
    cmp r3, #0x1                            @ 0801CC34  compare (r7 >> 5) with 1
    bne .L0801CC3C                          @ 0801CC36  if (r7 >> 5) != 1
    adds r6, #0xc                           @ 0801CC38  r6 = r6 + 12 (0xC)
    b .L0801CC46                            @ 0801CC3A
.L0801CC3C:  @ reached from 0801CC36 bne ((r7 >> 5) != 1)
    cmp r3, #0x2                            @ 0801CC3C  compare r3 with 2
    bne .L0801CC44                          @ 0801CC3E  if r3 != 2
    adds r6, #0x10                          @ 0801CC40  r6 = r6 + 16 (0x10)
    b .L0801CC46                            @ 0801CC42
.L0801CC44:  @ reached from 0801CC3E bne (r3 != 2)
    adds r6, #0x14                          @ 0801CC44  r6 = r6 + 20 (0x14)
.L0801CC46:  @ reached from 0801CC3A b, 0801CC42 b
    uxtb r2, r2                             @ 0801CC46
    cmp r2, #0x0                            @ 0801CC48  compare r2 with 0
    beq .L0801CC54                          @ 0801CC4A  if r2 == 0
    ldr r7, [r6, #0x0]                      @ 0801CC4C  r7 = [r6]
    orrs r7, r5                             @ 0801CC4E  r7 = r7 | r5
    str r7, [r6, #0x0]                      @ 0801CC50  [r6] = (r7 | r5)
    b .L0801CC5A                            @ 0801CC52
.L0801CC54:  @ reached from 0801CC4A beq (r2 == 0)
    ldr r7, [r6, #0x0]                      @ 0801CC54  r7 = [r6]
    bics r7, r5                             @ 0801CC56  r7 = r7 &~ r5
    str r7, [r6, #0x0]                      @ 0801CC58  [r6] = (r7 &~ r5)
.L0801CC5A:  @ reached from 0801CC52 b
    pop {r4, r5, r6, r7}                    @ 0801CC5A
    bx lr                                   @ 0801CC5C
ENDFUNC fn_0801CC08
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CC5E - USART_GetFlagStatus (StdPeriph)
@ Replaces : 0x0801CC5E FUN_0801CC5E (v2.05)
@ In       : r0 = USART base, r1 = SR mask
@ Out      : r0 = 1 if any masked SR bit is set
@ Clobbers : r0-r3, flags
@ Context  : main and ISR (USART2 handler, ble_tx_pump)
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ -----------------------------------------------------------------------------
FUNC fn_0801CC5E
    movs r2, r0                             @ 0801CC5E
    movs r0, #0x0                           @ 0801CC60
    uxth r1, r1                             @ 0801CC62
    cmp r1, #0x200                          @ 0801CC64  compare r1 with 512 (0x200)
    ldrh r3, [r2, #0x0]                     @ 0801CC68  r3 = [r2]
    tst r3, r1                              @ 0801CC6A  test r3 & r1
    beq .L0801CC74                          @ 0801CC6C  if (r3 & r1) == 0
    movs r3, #0x1                           @ 0801CC6E
    movs r0, r3                             @ 0801CC70
    b .L0801CC78                            @ 0801CC72
.L0801CC74:  @ reached from 0801CC6C beq ((r3 & r1) == 0)
    movs r3, #0x0                           @ 0801CC74
    movs r0, r3                             @ 0801CC76
.L0801CC78:  @ reached from 0801CC72 b
    uxtb r0, r0                             @ 0801CC78
    bx lr                                   @ 0801CC7A
ENDFUNC fn_0801CC5E
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CC7C - USART_GetITStatus (StdPeriph)
@ Replaces : 0x0801CC7C FUN_0801CC7C (v2.05)
@ In       : r0 = USART base, r1 = interrupt code
@ Out      : r0 = 1 if the interrupt is enabled and its flag set
@ Clobbers : r0-r3, flags
@ Context  : main and ISR (USART2 handler, ble_tx_pump)
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ -----------------------------------------------------------------------------
FUNC fn_0801CC7C
    push {r4, r5, r6}                       @ 0801CC7C
    movs r3, r0                             @ 0801CC7E
    movs r4, #0x0                           @ 0801CC80
    movs r6, #0x0                           @ 0801CC82
    movs r5, #0x0                           @ 0801CC84
    movs r0, #0x0                           @ 0801CC86
    uxth r1, r1                             @ 0801CC88
    movw r2, #0x96a                         @ 0801CC8A
    cmp r1, r2                              @ 0801CC8E  compare r1 with 2410 (0x96A)
    movs r2, r1                             @ 0801CC90
    uxtb r2, r2                             @ 0801CC92
    lsrs r2, r2, #0x5                       @ 0801CC94  r2 = r2 >> 5
    uxtb r2, r2                             @ 0801CC96
    movs r5, r2                             @ 0801CC98
    uxth r1, r1                             @ 0801CC9A
    ands r2, r1, #0x1f                      @ 0801CC9C  r2 = r1 & 31 (0x1F)
    movs r6, r2                             @ 0801CCA0
    movs r2, #0x1                           @ 0801CCA2
    lsls r6, r2, r6                         @ 0801CCA4  r6 = 1 << (r1 & 31 (0x1F))
    cmp r5, #0x1                            @ 0801CCA8  compare (r2 >> 5) with 1
    bne .L0801CCB2                          @ 0801CCAA  if (r2 >> 5) != 1
    ldrh r2, [r3, #0xc]                     @ 0801CCAC  r2 = [r3+12]
    ands r6, r2                             @ 0801CCAE  r6 = (1 << (r1 & 31 (0x1F))) & r2
    b .L0801CCC0                            @ 0801CCB0
.L0801CCB2:  @ reached from 0801CCAA bne ((r2 >> 5) != 1)
    cmp r5, #0x2                            @ 0801CCB2  compare r5 with 2
    bne .L0801CCBC                          @ 0801CCB4  if r5 != 2
    ldrh r2, [r3, #0x10]                    @ 0801CCB6  r2 = [r3+16]
    ands r6, r2                             @ 0801CCB8  r6 = r6 & r2
    b .L0801CCC0                            @ 0801CCBA
.L0801CCBC:  @ reached from 0801CCB4 bne (r5 != 2)
    ldrh r2, [r3, #0x14]                    @ 0801CCBC  r2 = [r3+20]
    ands r6, r2                             @ 0801CCBE  r6 = r6 & r2
.L0801CCC0:  @ reached from 0801CCB0 b, 0801CCBA b
    movs r2, r1                             @ 0801CCC0
    uxth r2, r2                             @ 0801CCC2
    lsrs r2, r2, #0x8                       @ 0801CCC4  r2 = r2 >> 8
    uxth r2, r2                             @ 0801CCC6
    movs r4, r2                             @ 0801CCC8
    movs r2, #0x1                           @ 0801CCCA
    lsls r4, r2, r4                         @ 0801CCCC  r4 = 1 << (r2 >> 8)
    ldrh r2, [r3, #0x0]                     @ 0801CCD0  r2 = [r3]
    ands r4, r2                             @ 0801CCD2  r4 = (1 << (r2 >> 8)) & r2
    cmp r6, #0x0                            @ 0801CCD4  compare r6 with 0
    beq .L0801CCE2                          @ 0801CCD6  if r6 == 0
    cmp r4, #0x0                            @ 0801CCD8  compare ((1 << (r2 >> 8)) & r2) with 0
    beq .L0801CCE2                          @ 0801CCDA  if ((1 << (r2 >> 8)) & r2) == 0
    movs r2, #0x1                           @ 0801CCDC
    movs r0, r2                             @ 0801CCDE
    b .L0801CCE6                            @ 0801CCE0
.L0801CCE2:  @ reached from 0801CCD6 beq (r6 == 0), 0801CCDA beq (((1 << (r2 >> 8)) & r2) == 0)
    movs r2, #0x0                           @ 0801CCE2
    movs r0, r2                             @ 0801CCE4
.L0801CCE6:  @ reached from 0801CCE0 b
    uxtb r0, r0                             @ 0801CCE6
    pop {r4, r5, r6}                        @ 0801CCE8
    bx lr                                   @ 0801CCEA
ENDFUNC fn_0801CC7C
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0801CCEC - USART_ClearITPendingBit (StdPeriph)
@ Replaces : 0x0801CCEC FUN_0801CCEC (v2.05)
@ In       : r0 = USART base, r1 = interrupt code
@ Out      : -
@ Clobbers : r0-r3, flags
@ Context  : main and ISR (USART2 handler, ble_tx_pump)
@ Spec     : RM0038 27.6 (USART registers); STM32L1 StdPeriph USART driver (the compiled form is in v2.05)
@ Note     : Writes the complement of the flag bit to SR (rc_w0 flags).
@ -----------------------------------------------------------------------------
FUNC fn_0801CCEC
    push {r4}                               @ 0801CCEC
    movs r3, #0x0                           @ 0801CCEE
    movs r4, #0x0                           @ 0801CCF0
    uxth r1, r1                             @ 0801CCF2
    movw r2, #0x96a                         @ 0801CCF4
    cmp r1, r2                              @ 0801CCF8  compare r1 with 2410 (0x96A)
    movs r2, r1                             @ 0801CCFA
    uxth r2, r2                             @ 0801CCFC
    lsrs r2, r2, #0x8                       @ 0801CCFE  r2 = r2 >> 8
    movs r3, r2                             @ 0801CD00
    movs r2, #0x1                           @ 0801CD02
    lsls r2, r3                             @ 0801CD04  r2 = 1 << (r2 >> 8)
    movs r4, r2                             @ 0801CD06
    uxth r4, r4                             @ 0801CD08
    mvns r2, r4                             @ 0801CD0A  r2 = ~(1 << (r2 >> 8))
    strh r2, [r0, #0x0]                     @ 0801CD0C  [r0] = (~(1 << (r2 >> 8)))
    pop {r4}                                @ 0801CD0E
    bx lr                                   @ 0801CD10
ENDFUNC fn_0801CCEC
    .ltorg

@ -----------------------------------------------------------------------------
@ fn_0800D170 - send one byte on a USART, waiting (bounded) for TXE
@ Replaces : 0x0800D170 FUN_0800D170 (v2.05)
@ In       : r0 = USART base, r1 = byte
@ Out      : r0 = 1 sent, 0 TXE never became set within SYS_WAIT_POLLS polls (byte not sent)
@ Clobbers : r0-r3, flags (r4-r6 saved)
@ Context  : main and USART2 interrupt
@ Deviation: HW rule "every hardware wait is bounded" (DESIGN.md 1): v2.05 spins until TXE with no bound
@            (0x0800D176..0x0800D180)
@ Note     : Used by ble_tx_pump for every transmitted byte (TXE is already set there, so the wait ends at once).
@ -----------------------------------------------------------------------------
FUNC fn_0800D170
    push {r4, r5, r6, lr}
    movs r4, r0                          @ USART base
    movs r5, r1                          @ byte
    ldr r6, =SYS_WAIT_POLLS              @ poll bound
.Lsb_wait:
    movs r1, #USART_SR_TXE
    movs r0, r4
    bl fn_0801CC5E                       @ USART_GetFlagStatus(TXE)
    cmp r0, #0
    bne .Lsb_send                        @ TXE set: transmit data register empty
    subs r6, r6, #1
    bne .Lsb_wait                        @ keep polling until the bound is used up
    movs r0, #0                          @ timeout: nothing sent
    pop {r4, r5, r6, pc}
.Lsb_send:
    uxtb r5, r5
    movs r1, r5
    uxth r1, r1
    movs r0, r4
    bl fn_0801CBF8                       @ USART_SendData
    movs r0, #1
    pop {r4, r5, r6, pc}
ENDFUNC fn_0800D170
    .ltorg

    .section .rodata.ble, "a", %progbits
    .balign 4
@ PD5, PD6: alternate function 7 (USART2), 40 MHz speed, push-pull, pull-up, ODR kept (v2.05 0x0801C3A6..0x0801C3E0)
ble_desc_usart_pins:
    GPIO_DESC 0x0060, GPIO_MODE_AF, GPIO_SPEED_40M, GPIO_OT_PP, GPIO_PUPD_UP, 7, BRD_LEVEL_KEEP
