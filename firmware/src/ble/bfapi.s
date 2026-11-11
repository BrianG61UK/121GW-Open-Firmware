@ =============================================================================
@ bfapi.s - BLE: the meter API - settings, the meter's state and any SETUP page over Bluetooth on every screen
@ (production image only, DESIGN.md 10 IMP-65, FEATURES.md 2.39)
@
@ Owner 2026-11-09: "make yourself a interface in the meter that can directly choose the settings and allow inputs
@ directly"; "its like a meter api with all commands in it you can run".  Before this module the settings requests
@ (ble/bftset.s) were taken only while the page Ld was shown, and nothing told the computer which page the meter showed
@ (in BEEP every page sends the threshold code in the status frame).
@
@ Packets.  The B5 5B packet of ble/bft.s (B5 5B type seq(2) len payload crc16(2), CRC-16/CCITT-FALSE over type .. payload)
@ with a payload of at most API_MAXPAY bytes (inc/config.inc) is now also taken outside the page Ld: the key / clock parser of the USART2
@ handler (ble/usart.s) recognises the first byte 0xB5 and collects the packet in ble_rx_buf (20 bytes), and the command
@ step (ble/commands.s fn_0800C332) passes it here.  Answers are the type 0x82 answer of ble/bftsd.s (bfx_reply), sent
@ from the transmit queue between status frames (on link 2 inside TEXT blocks).
@     0x16 GET   as ble/bftset.s
@     0x17 PUT   as ble/bftset.s (the setting is changed and saved exactly as its page does)
@     0x1B WHERE no payload.  Answer: status 0, field = API_VERSION, data (API_WHERE_LEN bytes):
@                [0] dial position (dial_latched), [1] meter_mode, [2] set_item (the SETUP page), [3] set_edit,
@                [4] flags: bit 0 page Ld owns the link, 1 logging, 2 MEM view, 3 calibration mode, 4 MIN/MAX on,
@                    5 power-on window open, 6 restart due (bootloader install done)
@     0x1C SHOW  payload item(1): show that SETUP page.  The meter takes the same steps as short SETUP presses
@                (fn_08015410, key/short.s .Lsh_setup_next without the beep) until set_item is the item; a page of the
@                meter walk (items 1..8, 20, 21, 25, 39, 40, 44, 47) is reached from the page SEt with what a long SETUP
@                does there (set_menu_enter).  Every page passed loads what it loads under the keys (no logic is
@                copied).  At most API_STEPS steps; a page that does not exist in this function (or this state) is
@                not reached: the meter walks back to the page it showed and answers 0x22.  Status 0, field = the item.
@     any other type: status 3.
@ The page Ld (bft_packet) also takes WHERE and SHOW (its own GET / PUT stay as they were).
@ Refusals (status 3): calibration mode and a restart due (every type but WHERE); for PUT and SHOW also logging, the MEM
@ view, the power-on window open (exactly the states in which short SETUP does not walk, key/short.s .Lsh_key_setup)
@ and, for SHOW, a page being edited (set_edit; PUT checks it itself).
@ A packet with a wrong CRC, a second byte other than 0x5B or a length that does not match is dropped (counted in
@ xd_bad_frames); the sender repeats when no answer comes.
@
@ Calibration, serial and options: nothing here writes the EEPROM; PUT goes through ble/bftset.s and set_nvm_store
@ (SETTINGS class only) as on the page Ld, SHOW only moves between pages.
@
@ Context: main only (fn_0800C332, bft_packet).
@ =============================================================================

    .syntax unified
    .cpu cortex-m3
    .thumb
    .include "macros.inc"
    .include "ram_v205.inc"
    .include "config.inc"
    .include "key.inc"
    .include "dial.inc"

    .equ API_VERSION,       1               @ field of the WHERE answer
    .equ API_WHERE_LEN,     5               @ bytes of the WHERE answer's data
    .equ API_STEPS,         64              @ walk steps of one SHOW (a full walk is about 22 steps, DESIGN.md IMP-65)
    .equ API_T_GET,         0x16
    .equ API_T_PUT,         0x17
    .equ API_T_WHERE,       0x1B
    .equ API_T_SHOW,        0x1C
    .equ API_ST_NOTALLOWED, 3
    .equ API_ST_ARG,        0x22
    .equ API_ITEM_SET,      43              @ the page SEt (set/menu.s)

    .equ api_set_item,      v_20008037      @ set_item (set/setup.s)
    .equ api_set_edit,      v_2000806E      @ set_edit
    .equ api_set_redraw,    v_20008062      @ set_redraw
    .equ api_cal_mode,      v_2000808A      @ calibration mode (key_cal_mode)
    .equ ble_cmd_buf,       v_20007B94      @ copy of the received frame (ble/commands.s)
    .equ ble_rx_len,        v_2000802F      @ its length (ble/commands.s, ble/usart.s)

    .section .bss_port.bfapi, "aw", %nobits
    .balign 2
    .global api_ticks
api_ticks:      .space 2                    @ free-running 10 ms tick count; only TIM2 writes it (bft_tick)
    .global api_rx_last
api_rx_last:    .space 2                    @ api_ticks at the last byte the key / clock parser took; only USART2 writes
                                            @ it.  One writer each, halfword stores: no read-modify-write between the two
                                            @ interrupts (the gap of a cut packet, ble/usart.s)

    .section .text.ble.bfapi, "ax", %progbits

@ -----------------------------------------------------------------------------
@ api_packet - a B5 5B packet received outside the page Ld
@ In       : ble_cmd_buf (ble_rx_len bytes, 8 .. 8 + API_MAXPAY: ble/usart.s)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only (fn_0800C332, first byte 0xB5)
@ RAM      : writes bft_pkt (not used outside the page Ld: bft_poll assembles only while the page is shown)
@ Note     : checks the copy, not ble_rx_buf (a byte arriving meanwhile overwrites ble_rx_buf, not ble_cmd_buf)
@ -----------------------------------------------------------------------------
FUNC api_packet
    push {r4, r5, r6, lr}
    ldr r0, =bft_active
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lap_ret                            @ the page Ld took the link meanwhile: bft_pkt is its packet being assembled
    ldr r4, =ble_cmd_buf
    ldr r0, =ble_rx_len
    ldrb r5, [r0]                           @ r5 = bytes of the packet
    ldrb r0, [r4, #1]
    cmp r0, #0x5B
    bne .Lap_bad
    ldrb r0, [r4, #5]                       @ payload length
    adds r0, r0, #8
    cmp r0, r5
    bne .Lap_bad
    adds r0, r4, #2
    subs r1, r5, #4                         @ type, seq(2), len, payload
    bl bft_crc16
    adds r1, r4, r5
    ldrb r2, [r1, #-2]
    ldrb r3, [r1, #-1]
    orr r2, r2, r3, lsl #8                  @ the CRC sent, little endian
    cmp r0, r2
    bne .Lap_bad
    ldr r6, =bft_pkt
    movs r0, #0
1:  ldrb r1, [r4, r0]
    strb r1, [r6, r0]                       @ the request as bfs_get / bfs_put / bfx_reply read it
    adds r0, r0, #1
    cmp r0, r5
    blo 1b
    bl fn_0800ED26                          @ activity: reload the auto-power-off counter (as bft_packet)
    ldrb r0, [r6, #2]                       @ type
    movs r1, #1                             @ outside the page Ld
    bl api_request
.Lap_ret:
    pop {r4, r5, r6, pc}
.Lap_bad:
    ldr r0, =xd_bad_frames
    bl xd_inc                               @ IMP-44 counter: a packet rejected
    pop {r4, r5, r6, pc}
ENDFUNC api_packet

@ -----------------------------------------------------------------------------
@ api_request - answer one API request of bft_pkt
@ In       : r0 = type, r1 = 1 outside the page Ld, 0 on the page (bft_packet: WHERE and SHOW only)
@ Out      : -
@ Clobbers : r0-r3, r12, flags (AAPCS)
@ Context  : main only
@ -----------------------------------------------------------------------------
FUNC api_request
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = type
    mov r5, r1                              @ r5 = outside
    cmp r4, #API_T_WHERE
    bne 0f
    bl api_where                            @ WHERE first: it reports a due restart (flag bit 6) instead of refusing
    b .Lar_reply
0:  ldr r0, =bft_reset_due
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lar_refuse                         @ the meter is about to restart
1:  ldr r0, =api_cal_mode
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lar_refuse                         @ calibration mode: no settings, no pages
    cmp r4, #API_T_GET
    bne 2f
    cmp r5, #0
    beq .Lar_refuse                         @ the page Ld routes GET itself (bfx_request)
    bl bfs_get
    b .Lar_reply
2:  cmp r4, #API_T_PUT
    beq 3f
    cmp r4, #API_T_SHOW
    bne .Lar_refuse
3:  cmp r4, #API_T_PUT
    bne 4f
    cmp r5, #0
    beq .Lar_refuse                         @ the page Ld routes PUT itself
4:  ldr r0, =key_logging
    ldrb r0, [r0]
    ldr r1, =key_mem_view
    ldrb r1, [r1]
    orrs r0, r0, r1
    bne .Lar_refuse                         @ logging or the MEM view: short SETUP does not walk either
    ldr r0, =key_window
    ldrh r0, [r0]
    cmp r0, #0
    bne .Lar_refuse                         @ the power-on window is open
    cmp r4, #API_T_PUT
    bne 5f
    bl bfs_put                              @ refuses a page being edited itself (status 3)
    b .Lar_reply
5:  ldr r0, =api_set_edit
    ldrb r0, [r0]
    cmp r0, #0
    bne .Lar_refuse                         @ a page is being edited: its buffers are in use
    bl api_show
    b .Lar_reply
.Lar_refuse:
    movs r0, #API_ST_NOTALLOWED
    bl bfx_status
.Lar_reply:
    bl bfx_reply
    pop {r4, r5, r6, pc}
ENDFUNC api_request

@ -----------------------------------------------------------------------------
@ api_where - the WHERE answer
@ Out      : r0 = 0, r1 = API_VERSION, r2 = API_WHERE_LEN (data at bfx_ans + 9)
@ Clobbers : r0-r3, flags
@ -----------------------------------------------------------------------------
LFUNC api_where
    ldr r3, =bfx_ans
    ldr r0, =dial_latched
    ldrb r0, [r0]
    strb r0, [r3, #9]
    ldr r0, =meter_mode
    ldrb r0, [r0]
    strb r0, [r3, #10]
    ldr r0, =api_set_item
    ldrb r0, [r0]
    strb r0, [r3, #11]
    ldr r0, =api_set_edit
    ldrb r0, [r0]
    strb r0, [r3, #12]
    movs r2, #0                             @ r2 = flags
    ldr r0, =bft_active
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x01                     @ bit 0: the page Ld owns the link
    ldr r0, =key_logging
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x02                     @ bit 1: logging
    ldr r0, =key_mem_view
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x04                     @ bit 2: MEM view
    ldr r0, =api_cal_mode
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x08                     @ bit 3: calibration mode
    ldr r0, =minmax_state
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x10                     @ bit 4: MIN/MAX on
    ldr r0, =key_window
    ldrh r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x20                     @ bit 5: the power-on window is open
    ldr r0, =bft_reset_due
    ldrb r0, [r0]
    cmp r0, #0
    it ne
    orrne r2, r2, #0x40                     @ bit 6: restart due
    strb r2, [r3, #13]
    movs r0, #0
    movs r1, #API_VERSION
    movs r2, #API_WHERE_LEN
    bx lr
ENDFUNC api_where

@ -----------------------------------------------------------------------------
@ api_valid - is the item a page SHOW may look for
@ In       : r0 = item
@ Out      : r0 = 1 yes (0 .. 12 or 20 .. 47), 0 no (13 .. 19, 48 and above: no such page; 100 the MEM view)
@ Clobbers : flags
@ -----------------------------------------------------------------------------
LFUNC api_valid
    cmp r0, #12
    bls 1f
    cmp r0, #20
    blo 2f
    cmp r0, #47
    bhi 2f
1:  movs r0, #1
    bx lr
2:  movs r0, #0
    bx lr
ENDFUNC api_valid

@ -----------------------------------------------------------------------------
@ api_meter_walk - is the item a page of the meter walk (entered from the page SEt by a long SETUP, set/menu.s)
@ In       : r0 = item
@ Out      : r0 = 1 yes (1 .. 8, 20, 21, 25, 39, 40, 44, 47), 0 no
@ Clobbers : r1, flags
@ -----------------------------------------------------------------------------
LFUNC api_meter_walk
    subs r1, r0, #1
    cmp r1, #7
    bls 1f                                  @ 1 .. 8
    cmp r0, #20
    beq 1f
    cmp r0, #21
    beq 1f
    cmp r0, #25
    beq 1f
    cmp r0, #39
    beq 1f
    cmp r0, #40
    beq 1f
    cmp r0, #44
    beq 1f
    cmp r0, #47
    beq 1f
    movs r0, #0
    bx lr
1:  movs r0, #1
    bx lr
ENDFUNC api_meter_walk

@ -----------------------------------------------------------------------------
@ api_walk - take walk steps until set_item is the item or API_STEPS steps are done
@ In       : r0 = item
@ Out      : r0 = 1 reached, 0 not reached
@ Clobbers : r0-r3, r12, flags (r4-r6 saved; fn_08015410 and set_menu_enter clobber the AAPCS scratch registers)
@ -----------------------------------------------------------------------------
LFUNC api_walk
    push {r4, r5, r6, lr}
    mov r4, r0                              @ r4 = item
    bl api_meter_walk
    mov r6, r0                              @ r6 = 1: a page of the meter walk
    movs r5, #API_STEPS                     @ r5 = steps left
1:  ldr r0, =api_set_item
    ldrb r0, [r0]
    cmp r0, r4
    beq 3f                                  @ reached
    cmp r5, #0
    beq 4f                                  @ not within API_STEPS steps
    subs r5, r5, #1
    cmp r0, #API_ITEM_SET
    bne 2f
    cmp r6, #0
    beq 2f
    bl set_menu_enter                       @ on SEt for a meter-walk page: what a long SETUP does there
    b 1b
2:  bl fn_08015410                          @ what a short SETUP does: the next page
    b 1b
3:  movs r0, #1
    pop {r4, r5, r6, pc}
4:  movs r0, #0
    pop {r4, r5, r6, pc}
ENDFUNC api_walk

@ -----------------------------------------------------------------------------
@ api_show - the SHOW request: walk to the page bft_pkt names
@ Out      : r0 = status (0, or 0x22: payload not one byte, not a page, or not reached), r1 = field (the item, 0 on a
@            wrong payload), r2 = 0
@ Clobbers : r0-r3, r12, flags (r4, r5 saved)
@ RAM      : set_item and what the walk's steps write; set_redraw = 1
@ -----------------------------------------------------------------------------
LFUNC api_show
    push {r4, r5, r6, lr}
    ldr r0, =bft_pkt
    ldrb r1, [r0, #5]
    cmp r1, #1
    bne .Lsh_arg
    ldrb r4, [r0, #6]                       @ r4 = item
    mov r0, r4
    bl api_valid
    cmp r0, #0
    beq .Lsh_arg
    ldr r0, =api_set_item
    ldrb r5, [r0]                           @ r5 = the page shown now
    mov r0, r4
    bl api_walk
    cmp r0, #0
    bne 1f
    mov r0, r5
    bl api_walk                             @ not reached: back to the page it showed (on the walk: SHOW needs set_edit 0
    movs r0, #1                             @ and no MEM view, so it is a page of the walk); then 0x22
    ldr r1, =api_set_redraw
    strb r0, [r1]
    movs r0, #API_ST_ARG
    mov r1, r4
    movs r2, #0
    pop {r4, r5, r6, pc}
1:  movs r0, #1
    ldr r1, =api_set_redraw
    strb r0, [r1]                           @ redraw the page (key/short.s .Lsh_setup_next)
    movs r0, #0
    mov r1, r4
    movs r2, #0
    pop {r4, r5, r6, pc}
.Lsh_arg:
    movs r0, #API_ST_ARG
    movs r1, #0
    movs r2, #0
    pop {r4, r5, r6, pc}
ENDFUNC api_show
    .ltorg
