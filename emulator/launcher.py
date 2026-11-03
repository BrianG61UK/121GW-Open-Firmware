"""Entry point of the packaged emulator (PyInstaller, packaging/121gw_emulator.spec).

A double-clicked application: the emulator starts and its front panel opens in a window of its own (pywebview: WebKit on
macOS, Microsoft Edge WebView2 on Windows); closing the window stops the emulator.  Where no such window can be made
(Linux builds, which carry no web view; Windows without the WebView2 runtime; a failure of the window toolkit) the panel
opens in the default browser instead and the page's Quit button stops the emulator.  The original images of a source
checkout are never looked for (--no-inputs) and a busy port 8121 is skipped in favour of the next free one
(--port-tries 20).  Every option of app.py works; in addition --browser always uses the browser and --no-open opens
nothing (for scripted use).  An error before the panel is up is shown in a message box, because a windowed application
has no console to print it to.  The data the application ships with (firmware builds, v2.05 table data, synthetic EEPROM)
is found by emu/bundle.py.
"""
import faulthandler
import os
import subprocess
import sys
import threading
import traceback
import webbrowser

if sys.stderr is not None and hasattr(sys.stderr, 'fileno'):    # windowed apps have no stderr
    try:
        faulthandler.enable()  # a native crash prints its Python stack (a frozen app ignores PYTHONFAULTHANDLER)
    except (RuntimeError, ValueError, OSError):
        pass

TITLE = '121GW Emulator'


def show_error(text):
    """Tell the user about a failure: message box on Windows and macOS, stderr (and zenity when present) on Linux."""
    if sys.stderr is not None:
        print(text, file=sys.stderr, flush=True)
    try:
        if sys.platform == 'win32':
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, text, TITLE, 0x10)          # MB_ICONERROR
        elif sys.platform == 'darwin':
            safe = text.replace('\\', '\\\\').replace('"', '\\"')
            subprocess.run(['osascript', '-e', f'display dialog "{safe}" with title "{TITLE}" buttons {{"OK"}} '
                            'with icon stop'], timeout=600, check=False)
        else:
            subprocess.run(['zenity', '--error', '--title', TITLE, '--text', text], timeout=600, check=False)
    except Exception:       # no way to show it: stderr above is all there is
        pass


def log(text):
    if sys.stdout is not None:
        print(text, flush=True)


def open_window(url):
    """Show the panel in a native window and return when it is closed; False when no window can be made."""
    if sys.platform.startswith('linux'):
        log('121GW emulator window: the browser (the Linux build carries no web view)')
        return False
    try:
        import webview
    except Exception as e:
        log(f'121GW emulator window: the browser (pywebview not available: {e})')
        return False
    try:
        win = webview.create_window(TITLE, url, width=1360, height=980, min_size=(900, 640))
        win.events.shown += lambda: log('121GW emulator window: own window shown')
        webview.start(gui='edgechromium' if sys.platform == 'win32' else None)
        return True
    except Exception as e:
        log(f'121GW emulator window: the browser (no window: {e})')
        return False


def main():
    args = sys.argv[1:]
    mode = 'window'
    if '--no-open' in args:
        args.remove('--no-open')
        mode = 'none'
    elif '--browser' in args or '--open' in args:
        args = [x for x in args if x != '--browser']
        mode = 'browser'
    if '--no-ui' in args:
        mode = 'none'
    for default in (['--no-inputs'], ['--port-tries', '20']):
        if default[0] not in args:
            args[:0] = default
    if mode == 'browser' and '--open' not in args:
        args.insert(0, '--open')
    import app

    ready = threading.Event()
    result = {}

    def on_ready(url):
        result['url'] = url
        ready.set()

    def run():
        try:
            app.main(args, on_ready=on_ready)
        except BaseException as e:   # report, then end the process with the same outcome
            result['exc'] = e
            if not isinstance(e, SystemExit) or e.code not in (0, None):
                result['text'] = (str(e) if isinstance(e, SystemExit) else
                                  ''.join(traceback.format_exception(type(e), e, e.__traceback__)))
        finally:
            ready.set()

    # The emulator runs in a thread with a large stack: Unicorn's code generator runs on the calling thread's stack,
    # and a frozen application's main thread has a smaller stack than python.exe's.  The main thread stays free for the
    # window (macOS requires the GUI on the main thread).
    threading.stack_size(64 * 1024 * 1024)
    t = threading.Thread(target=run, name='emulator', daemon=True)
    t.start()
    ready.wait()
    if 'url' not in result:                             # the emulator ended before its panel was up
        t.join()
        if 'text' in result:
            show_error('The emulator could not start:\n\n' + result['text'])
        e = result.get('exc')
        sys.exit(e.code if isinstance(e, SystemExit) and e.code is not None else (1 if e else 0))
    if mode == 'window':
        if open_window(result['url']):
            os._exit(0)                                 # window closed: stop the emulator
        webbrowser.open(result['url'])                  # no window possible: the browser, Quit button stops it
    t.join()
    if 'text' in result:
        show_error('The emulator stopped:\n\n' + result['text'])
    e = result.get('exc')
    sys.exit(e.code if isinstance(e, SystemExit) and e.code is not None else (1 if e else 0))


if __name__ == '__main__':
    main()
