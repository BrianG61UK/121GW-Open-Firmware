"""Entry point of the packaged emulator (PyInstaller, packaging/121gw_emulator.spec).

Starts app.py's main() with the defaults of a double-clicked application: the browser is opened on the UI, the original
images of a source checkout are never looked for (--no-inputs), and a busy port 8121 is skipped in favour of the next free
one (--port-tries 20).  Every option of app.py works; --no-open keeps the browser closed.  The data the application
ships with (firmware builds, v2.05 table data, synthetic EEPROM) is found by emu/bundle.py.
"""
import faulthandler
import sys
import traceback

faulthandler.enable()          # a native crash prints its Python stack (a frozen app ignores PYTHONFAULTHANDLER)

import app  # noqa: E402

if __name__ == '__main__':
    args = sys.argv[1:]
    if '--no-open' in args:
        args.remove('--no-open')
    elif '--open' not in args and '--no-ui' not in args:
        args.insert(0, '--open')
    for default in (['--no-inputs'], ['--port-tries', '20']):
        if default[0] not in args:
            args[:0] = default
    try:
        app.main(args)
    except BaseException:
        traceback.print_exc()
        sys.stderr.flush()
        raise
