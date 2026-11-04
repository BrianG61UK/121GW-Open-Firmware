/* bootloader.ld - link script of the bootloader (bootloader/DESIGN.md 6.1)
   Flash 0x08000400..0x08005EFF (the mark page 0x08005F00 is written by the starter); vector table first, at the
   512-byte boundary 0x08000400.  RAM: the bootloader's objects from 0x20008100 (below it the fixed addresses of the
   firmware's SD driver), stack below 0x2000C000.  The RAM code (flash operations, USART2 handler) is copied at start. */
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000400, LENGTH = 0x5B00
    RAM   (rwx) : ORIGIN = 0x20008100, LENGTH = 0x3F00
}
ENTRY(bl_reset)
SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        *(.text*)
        *(.rodata*)
        . = ALIGN(4);
    } > FLASH
    .ramcode : {
        __ram_vma = .;
        *(.ramcode*)
        . = ALIGN(4);
    } > RAM AT > FLASH
    __ram_lma = LOADADDR(.ramcode);
    __ram_lma_end = LOADADDR(.ramcode) + SIZEOF(.ramcode);
    __image_end = __ram_lma_end;
    .ramvec (NOLOAD) : { *(.ramvec*) } > RAM
    .bss (NOLOAD) : {
        *(.bss*)
        *(.bss_port*)
        *(COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM
    .data : { *(.data*) } > RAM AT > FLASH
    /DISCARD/ : { *(.ARM.attributes*) *(.comment*) }
}
ASSERT(__bss_end <= 0x2000B800, "bootloader RAM reaches the 2 KiB stack below 0x2000C000")
ASSERT(SIZEOF(.data) == 0, "initialised data is not copied by bl_reset: none allowed")
