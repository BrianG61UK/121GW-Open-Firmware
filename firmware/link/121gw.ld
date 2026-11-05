/* =============================================================================
 * 121gw.ld - linker script of the 121GW replacement firmware (DESIGN.md 2.2, 2.3, 5.1, 9.2)
 *
 * Image: loaded by the unchanged bootloader at 0x08006000; the bootloader checks only vector word 0
 * ((SP & 0x2FFE0000) == 0x20000000, bootloader 0x08004994) and jumps to vector word 1 (DESIGN.md 2.1).
 * RAM: every v2.05 variable keeps its v2.05 address (the symbols are absolute, firmware/src/inc/ram_v205.inc);
 * this script only reserves the v2.05 regions and places the port's own state above 0x20008100.
 * ============================================================================= */

OUTPUT_FORMAT("elf32-littlearm")
OUTPUT_ARCH(arm)
ENTRY(sys_reset)

MEMORY
{
    FLASH    (rx)  : ORIGIN = 0x08006000, LENGTH = 0x4C000   /* 0x08006000..0x08051FFF; above: bootloader slots (bootloader/DESIGN.md 6.1) */
    RAM_V205 (rwx) : ORIGIN = 0x20000000, LENGTH = 0x80FC    /* 0x20000000..0x200080FB, v2.05 layout */
    RAM_PORT (rw)  : ORIGIN = 0x20008100, LENGTH = 0x3F00    /* 0x20008100..0x2000BFFF, port-only state */
}

SECTIONS
{
    /* 73-word vector table at the load address (DESIGN.md 2.2) */
    .vectors 0x08006000 :
    {
        KEEP(*(.vectors))
    } > FLASH

    .text :
    {
        *(SORT_BY_NAME(.text*))
    } > FLASH

    .rodata :
    {
        . = ALIGN(4);
        *(SORT_BY_NAME(.rodata*))
        . = ALIGN(4);
    } > FLASH

    /* v2.05 initialised variables 0x20000000..0x2000023D (574 bytes = analysis/decompile/ram_init.txt),
       copied from flash by sys_reset (DESIGN.md 3.2 step 4, 6.27) */
    .data_v205 0x20000000 :
    {
        __data_v205_start = .;
        KEEP(*(.data_v205))
        __data_v205_end = .;
    } > RAM_V205 AT> FLASH
    __data_v205_load = LOADADDR(.data_v205);
    __image_end = LOADADDR(.data_v205) + SIZEOF(.data_v205);

    /* main stack 0x2000023E..0x2000123F, initial SP 0x20001240 as v2.05 (DESIGN.md 5.1, 5.3) */
    .stack 0x2000023E (NOLOAD) :
    {
        __stack_bottom = .;
        . = . + (0x20001240 - 0x2000023E);  /* 4098 bytes (inside a section, . counts from the section start) */
        __stack_top = .;
    } > RAM_V205

    /* v2.05 zero-initialised variables and buffers 0x20001240..0x200080FB, zeroed by sys_reset */
    .bss_v205 0x20001240 (NOLOAD) :
    {
        __bss_v205_start = .;
        . = . + (0x200080FC - 0x20001240);  /* 0x6EBC bytes */
        __bss_v205_end = .;
    } > RAM_V205

    /* port-only state, zeroed by sys_reset (DESIGN.md 5.1) */
    .bss_port 0x20008100 (NOLOAD) :
    {
        __bss_port_start = .;
        *(SORT_BY_NAME(.bss_port*))
        . = ALIGN(4);
        __bss_port_end = .;
    } > RAM_PORT

    /* sections the conventions forbid (DESIGN.md 8.2: no initialised or zeroed data outside the two regions
       above); collected here so that the assertion below names the violation */
    .forbidden (NOLOAD) :
    {
        *(.data .data.* .bss .bss.* COMMON)
    } > RAM_PORT

    /* TABLE_V205 records (macros.inc): not loaded, read by the build check */
    .v205tab 0 (INFO) :
    {
        KEEP(*(.v205tab))
    }

    /DISCARD/ :
    {
        *(.ARM.exidx*) *(.ARM.extab*) *(.ARM.attributes) *(.comment) *(.note*)
    }
}

/* Build-time assertions (DESIGN.md 9.2) */
ASSERT(SIZEOF(.vectors) == 73 * 4, "vector table must be 73 words (16 system + 57 IRQ)")
ASSERT(__image_end <= 0x08052000, "image exceeds 0x4C000 bytes")
ASSERT(blinst_hp_code_end - (blinst_hp_code & ~1) <= 96, "blinst_hp_code does not fit blinst_ram (nvm/blinst.s)")
ASSERT(SIZEOF(.data_v205) == 574, ".data_v205 must be exactly 574 bytes (ram_init.txt)")
ASSERT(__data_v205_start == 0x20000000, ".data_v205 must start at 0x20000000")
ASSERT(__stack_top == 0x20001240, "initial SP must be 0x20001240")
ASSERT(__bss_v205_start == 0x20001240, ".bss_v205 must start at 0x20001240")
ASSERT(__bss_v205_end == 0x200080FC, ".bss_v205 must end at 0x200080FC")
ASSERT(__bss_port_start >= 0x20008100 && __bss_port_end <= 0x2000C000, ".bss_port outside RAM_PORT")
ASSERT(SIZEOF(.forbidden) == 0, "a module defines .data/.bss outside .data_v205 / .bss_port")
