# PyInstaller spec of the 121GW emulator for macOS and Linux: one-folder application (macOS: .app bundle around the same
# folder).  Windows ships the embeddable CPython with the sources instead (.github/workflows/emulator.yml).
#
#   cd emulator && EMU_VERSION=<tag> [EMU_ICON=<.ico/.icns>] pyinstaller --noconfirm packaging/121gw_emulator.spec
#
# Needs emulator/data filled by tools/prepare_data.py (firmware builds, v205_tables.json, synthetic_eeprom.bin).
# Bundled: the UI (index.html, assets with the LCD graphics and their MIT licence), the data folder, the project LICENSE.
# unicorn and capstone: their native libraries are collected explicitly (unicorn loads unicorn/lib/ next to the package).
# macOS: pywebview (the application window, launcher.py) with its pyobjc frameworks; Linux builds carry no web view.
import os
import sys

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_submodules

root = os.path.abspath(os.path.join(SPECPATH, '..'))          # emulator/
repo = os.path.abspath(os.path.join(root, '..'))
version = os.environ.get('EMU_VERSION', 'dev')
icon = os.environ.get('EMU_ICON') or None                    # .ico / .icns from packaging/make_icons.py, optional

for need in ('data/synthetic_eeprom.bin', 'data/v205_tables.json', 'ui/assets/lcd/LICENSE'):
    if not os.path.isfile(os.path.join(root, need)):
        raise SystemExit('packaging: %s is missing (run emulator/tools/prepare_data.py)' % need)
# the emulator ships no firmware: the builds are fetched on demand (emu/fetch.py); a data/firmware folder left from an
# older prepare_data.py must not end up in a package
if os.path.exists(os.path.join(root, 'data', 'firmware')):
    raise SystemExit('packaging: emulator/data/firmware exists; the emulator ships no firmware (emu/fetch.py): delete it')

# unicorn keeps its native library in unicorn/lib (libunicorn.so.2 on Linux, a versioned name that
# collect_dynamic_libs does not match); bundle every file of that folder at the same relative place
import glob, unicorn as _uc
_uclib = os.path.join(os.path.dirname(_uc.__file__), 'lib')
unicorn_libs = [(f, os.path.join('unicorn', 'lib')) for f in glob.glob(os.path.join(_uclib, '*')) if os.path.isfile(f) and not f.endswith('.a')]
if not unicorn_libs:
    raise SystemExit('packaging: no unicorn native library found in %s' % _uclib)

a = Analysis(
    [os.path.join(root, 'launcher.py')],
    pathex=[root],
    binaries=unicorn_libs + collect_dynamic_libs('capstone'),   # no stock hook ships unicorn's library
    datas=[(os.path.join(root, 'ui', 'index.html'), 'ui'),
           (os.path.join(root, 'ui', 'assets'), os.path.join('ui', 'assets')),
           (os.path.join(root, 'data'), 'data'),
           (os.path.join(repo, 'LICENSE'), '.')],
    hiddenimports=['ui.server'] + collect_submodules('unicorn')    # unicorn imports its arch modules by name
                  + (['webview', 'webview.platforms.cocoa'] if sys.platform == 'darwin' else []),
    excludes=['tkinter', 'numpy', 'PIL', 'matplotlib'] + ([] if sys.platform == 'darwin' else ['webview']),
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='121gw-emulator', icon=icon,
          console=(sys.platform != 'darwin'))                   # macOS: windowed .app (its own window, launcher.py)
coll = COLLECT(exe, a.binaries, a.datas, name='121gw-emulator')
if sys.platform == 'darwin':
    app = BUNDLE(coll, name='121GW Emulator.app', icon=icon, bundle_identifier='io.github.zombu4.121gw-open-firmware',
                 info_plist={'CFBundleName': '121GW Emulator', 'CFBundleDisplayName': '121GW Emulator',
                             'CFBundleShortVersionString': version, 'CFBundleVersion': version,
                             'NSHighResolutionCapable': True})
