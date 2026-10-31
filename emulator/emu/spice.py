"""Circuit-level simulation of the meter's analog electronics through the ngspice shared library.

The front end (jacks -> dividers/shunts/protection -> HY3131 pins) is described by a SPICE netlist with
the schematic's reference designators.  This module loads that netlist into libngspice, sets the
test-lead stimulus, and returns node voltages (operating point) and integrated output noise (noise
analysis), which the HY3131 model turns into conversion results.

libngspice is loaded from the path given to Spice() or the NGSPICE_LIB environment variable; KiCad
ships one (Contents/PlugIns/sim/libngspice.dylib inside the KiCad application bundle).
Note: ngspice lower-cases element names, so source names are passed in lower case.
"""
import ctypes, os, threading

_CB_PRINT = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p)
_CB_EXIT = ctypes.CFUNCTYPE(ctypes.c_int, ctypes.c_int, ctypes.c_bool, ctypes.c_bool, ctypes.c_int,
                            ctypes.c_void_p)


class SpiceError(RuntimeError):
    pass


class Spice:
    """One ngspice instance (the shared library is a process-wide singleton, so calls are serialised)."""
    _lock = threading.Lock()

    def __init__(self, lib_path=None):
        path = lib_path or os.environ.get('NGSPICE_LIB')
        if not path:
            raise SpiceError('no libngspice path: pass lib_path or set NGSPICE_LIB')
        self.lib = ctypes.CDLL(path)
        self.out = []
        # keep the callback objects alive for the lifetime of the library
        self._pr = _CB_PRINT(self._on_print)
        self._ex = _CB_EXIT(lambda *a: 0)
        self.lib.ngSpice_Init(self._pr, None, self._ex, None, None, None, None)
        self.lib.ngGet_Vec_Info.restype = ctypes.POINTER(_VecInfo)

    def _on_print(self, text, ident, user):
        self.out.append(text.decode(errors='replace'))
        return 0

    def cmd(self, line):
        """Run one ngspice command; raise on reported errors."""
        n = len(self.out)
        if self.lib.ngSpice_Command(line.encode()) != 0:
            raise SpiceError(f'command failed: {line}')
        # ngspice reports a failed analysis as 'stderr ... aborted' without the word 'error'
        # (e.g. a noise input source without an AC value: "noise simulation(s) aborted")
        errs = [l for l in self.out[n:] if l.startswith('stderr') and ('rror' in l or 'aborted' in l)]
        if errs:
            raise SpiceError(f'{line}: ' + '; '.join(self.out[n:][-3:]))

    def load(self, lines):
        """Load a netlist given as a list of lines (first line is the title, last '.end')."""
        with self._lock:
            arr = (ctypes.c_char_p * (len(lines) + 1))(*[l.encode() for l in lines], None)
            n = len(self.out)
            if self.lib.ngSpice_Circ(arr) != 0:
                raise SpiceError('netlist rejected: ' + '; '.join(self.out[n:]))
            errs = [l for l in self.out[n:] if 'rror' in l]
            if errs:
                raise SpiceError('netlist errors: ' + '; '.join(errs))

    def load_file(self, path):
        with open(path) as f:
            self.load([l.rstrip('\n') for l in f])

    def vec(self, name):
        """Real values of a vector in the current plot."""
        p = self.lib.ngGet_Vec_Info(name.encode())
        if not p:
            raise SpiceError(f'no vector {name}')
        v = p.contents
        if not v.v_realdata:
            raise SpiceError(f'vector {name} has no real data')
        return [v.v_realdata[i] for i in range(v.v_length)]

    def op(self, alters=()):
        """DC operating point after applying 'alter' commands (e.g. ('vin', 'dc', 1.0)).
        Returns {node_or_branch: value}."""
        with self._lock:
            for el, par, val in alters:
                self.cmd(f'alter {el.lower()} {par} = {val!r}' if par else f'alter {el.lower()} = {val!r}')
            self.cmd('op')
            return self._all_vectors()

    def noise(self, out_node, src, f_lo, f_hi, ref_node='0', points=20):
        """Total output noise (V rms) at out_node, integrated f_lo..f_hi, input source src (src must have an
        AC value in the netlist, otherwise ngspice aborts the analysis)."""
        with self._lock:
            ref = '' if ref_node == '0' else f',{ref_node}'
            self.cmd(f'noise v({out_node}{ref}) {src.lower()} dec {points} {f_lo!r} {f_hi!r}')
            return self.vec('onoise_total')[0]

    def _all_vectors(self):
        cur = self.lib.ngSpice_CurPlot
        cur.restype = ctypes.c_char_p
        allv = self.lib.ngSpice_AllVecs
        allv.restype = ctypes.POINTER(ctypes.c_char_p)
        plot = cur()
        names, i, res = allv(plot), 0, {}
        while names[i]:
            n = names[i].decode()
            res[n] = self.vec(n)[0]
            i += 1
        return res


class _VecInfo(ctypes.Structure):
    # struct vector_info from sharedspice.h
    _fields_ = [('v_name', ctypes.c_char_p), ('v_type', ctypes.c_int), ('v_flags', ctypes.c_short),
                ('v_realdata', ctypes.POINTER(ctypes.c_double)), ('v_compdata', ctypes.c_void_p),
                ('v_length', ctypes.c_int)]
