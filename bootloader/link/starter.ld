/* starter.ld - link script of the starter (bootloader/DESIGN.md 6.1, 6.2)
   Flash 0x08000000..0x080003FF (four pages); ram_flash runs from RAM at 0x20000000, its copy is part of the 1024 bytes.
   Overflowing the 1024 bytes is a link error. */
MEMORY
{
    FLASH (rx)  : ORIGIN = 0x08000000, LENGTH = 0x400
    RAM   (rwx) : ORIGIN = 0x20000000, LENGTH = 0x2000
}
ENTRY(st_reset)
SECTIONS
{
    .text : {
        KEEP(*(.vectors))
        *(.text*)
        . = ALIGN(4);
    } > FLASH
    .ramcode : {
        __ram_vma = .;
        *(.ramcode*)
        . = ALIGN(4);
    } > RAM AT > FLASH
    __ram_lma = LOADADDR(.ramcode);
    __ram_lma_end = LOADADDR(.ramcode) + SIZEOF(.ramcode);
    /DISCARD/ : { *(.ARM.attributes*) *(.comment*) }
}
