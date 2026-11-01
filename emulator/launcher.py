"""Entry point of the packaged emulator (PyInstaller, packaging/121gw_emulator.spec).

Starts app.py's main() with the defaults of a double-clicked application: the browser is opened on the UI, the original
images of a source checkout are never looked for (--no-inputs), and a busy port 8121 is skipped in favour of the next free
one (--port-tries 20).  Every option of app.py works; --no-open keeps the browser closed.  The data the application
ships with (firmware builds, v2.05 table data, synthetic EEPROM) is found by emu/bundle.py.
"""
import faulthandler
import sys
import threading
import traceback

if sys.stderr is not None and hasattr(sys.stderr, 'fileno'):    # windowed apps (macOS .app) have no stderr
    try:
        faulthandler.enable()  # a native crash prints its Python stack (a frozen app ignores PYTHONFAULTHANDLER)
    except (RuntimeError, ValueError, OSError):
        pass

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
    # The emulator runs in a thread with a large stack: Unicorn's code generator runs on the calling thread's stack,
    # and a frozen application's main thread has a smaller stack than python.exe's.
    result = {}

    def run():
        try:
            app.main(args)
        except BaseException as e:   # report, then end the process with the same outcome
            result['exc'] = e
            if sys.stderr is not None:
                traceback.print_exc()
                sys.stderr.flush()

    threading.stack_size(64 * 1024 * 1024)
    t = threading.Thread(target=run, name='emulator')
    t.start()
    t.join()
    if 'exc' in result:
        e = result['exc']
        sys.exit(e.code if isinstance(e, SystemExit) else 1)
