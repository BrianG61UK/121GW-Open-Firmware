"""STM32L152ZD system configuration controller, SYSCFG (RM0038 8.5), block at 0x4001 0000.

Registers (RM0038 8.5.7, register map table 46, page 223):
    0x00 SYSCFG_MEMRMP   0x04 SYSCFG_PMC   0x08 SYSCFG_EXTICR1   0x0C EXTICR2   0x10 EXTICR3   0x14 EXTICR4
Offsets 0x18 and above are not described in RM0038 and are routed to unmodelled().

The routing interface (RI, RM0038 chapter 8.4) is NOT part of this block: RM0038 table 5 (memory map) places it at
0x4000 7C04 - 0x4000 7C5B, so it needs its own model.

Memory remap: the machine core has no address-0 remap, so a change of MEM_MODE is reported through
on_remap(mem_mode) when board code registers that callback, otherwise it is routed to unmodelled().
"""
from .base import Periph

SYSCFG_BASE = 0x40010000
SYSCFG_SIZE = 0x400

# Offsets (RM0038 table 46).
MEMRMP, PMC, EXTICR1, EXTICR2, EXTICR3, EXTICR4 = 0x00, 0x04, 0x08, 0x0C, 0x10, 0x14

# EXTICRx port selection codes (RM0038 8.5.3 - 8.5.6): 0 A, 1 B, 2 C, 3 D, 4 E, 5 H, 6 F, 7 G.
# Codes 8..15 are not listed in RM0038 and select no port.
PORT_CODE_MAX = 7


class SYSCFG(Periph):
    name = "SYSCFG"
    base = SYSCFG_BASE

    def __init__(self, boot1=0, boot0=0):
        """boot1/boot0 are the BOOT pin levels latched after reset (RM0038 2.7, table 6)."""
        super().__init__()
        self._boot_mode = ((1 if boot1 else 0) << 1) | (1 if boot0 else 0)   # BOOT_MODE[1:0], RM0038 8.5.1
        self.exti = None                         # set by EXTI(), notified when a port selection changes
        self.on_remap = None                     # on_remap(mem_mode) for address-0 remapping
        self.memrmp_mem_mode = 0
        self.pmc = 0
        self.exticr = [0, 0, 0, 0]
        self.reset(full=True)

    def reset(self, full=False):
        """Reset.  MEMRMP is not reset by SYSCFGRST in RCC_APB2RSTR (RM0038 8.5.1), only by a system reset: full=True."""
        if full:
            # MEM_MODE after reset takes the mapping selected by the BOOT pins (RM0038 8.5.1, 2.7 table 6):
            # BOOT0=0 main Flash (00); BOOT1=0,BOOT0=1 system memory (01); BOOT1=1,BOOT0=1 embedded SRAM (11).
            b1, b0 = (self._boot_mode >> 1) & 1, self._boot_mode & 1
            self.memrmp_mem_mode = 0 if not b0 else (3 if b1 else 1)
        self.pmc = 0                             # RM0038 8.5.2: reset value 0
        self.exticr = [0, 0, 0, 0]               # RM0038 8.5.3 - 8.5.6: reset value 0 (port A)
        if self.exti is not None:
            self.exti.resync()

    def source_port(self, line):
        """Port code (0..7, see PORT_CODE_MAX) feeding EXTI line 0..15, or None if no GPIO pin is connected.

        Port H (code 5) only has PH[2:0] connected (RM0038 8.5.3: "only PH[2:0]"; 8.5.4 - 8.5.6: PH[15:4] are not
        available); codes above 7 are not defined in RM0038 and select nothing."""
        code = (self.exticr[line >> 2] >> (4 * (line & 3))) & 0xF
        if code > PORT_CODE_MAX or (code == 5 and line > 2):
            return None
        return code

    def read(self, off, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'R')
            return 0
        if reg == MEMRMP:
            # RM0038 8.5.1: BOOT_MODE[1:0] at bits 9:8 (read-only), MEM_MODE[1:0] at bits 1:0, others reserved
            w = (self._boot_mode << 8) | self.memrmp_mem_mode
        elif reg == PMC:
            w = self.pmc                         # RM0038 8.5.2
        elif EXTICR1 <= reg <= EXTICR4:
            w = self.exticr[(reg - EXTICR1) >> 2]    # RM0038 8.5.3 - 8.5.6
        else:
            self.unmodelled(off, 'R')
            return 0
        return self.extract(w, off, size)

    def write(self, off, value, size):
        reg = off & ~3
        if (off & 3) + size > 4:
            self.unmodelled(off, 'W')
            return
        if reg == MEMRMP:
            old = self.memrmp_mem_mode
            new = self.merge(old, off, value, size) & 3          # only MEM_MODE is writable (RM0038 8.5.1)
            self.memrmp_mem_mode = new
            if new != old:
                if self.on_remap is not None:
                    self.on_remap(new)
                else:
                    self.unmodelled(off, 'W')                    # remap not implemented by the core
        elif reg == PMC:
            # RM0038 8.5.2: LCD_CAPA[5:1] and USB_PU[0] are the only defined bits; neither has an effect on the
            # modelled machine (LCD decoupling capacitor connection, USB DP pull-up)
            self.pmc = self.merge(self.pmc, off, value, size) & 0x3F
        elif EXTICR1 <= reg <= EXTICR4:
            i = (reg - EXTICR1) >> 2                             # RM0038 8.5.3 - 8.5.6, bits 31:16 reserved
            old = self.exticr[i]
            self.exticr[i] = self.merge(old, off, value, size) & 0xFFFF
            if self.exticr[i] != old and self.exti is not None:
                self.exti.resync()
        else:
            self.unmodelled(off, 'W')
