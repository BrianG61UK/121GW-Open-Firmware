# PyInstaller spec of the 121GW emulator: one-folder application (macOS: .app bundle around the same folder).
#
#   cd emulator && EMU_VERSION=<tag> [EMU_ICON=<.ico/.icns>] pyinstaller --noconfirm packaging/121gw_emulator.spec
#
# Needs emulator/data filled by tools/prepare_data.py (firmware builds, v205_tables.json, synthetic_eeprom.bin).
# Bundled: the UI (index.html, assets with the LCD graphics and their MIT licence), the data folder, the project LICENSE.
# unicorn and capstone: their native libraries are collected explicitly (unicorn loads unicorn/lib/ next to the package).
import os
import sys

from PyInstaller.utils.hooks import collect_dynamic_libs, collect_submodules

root = os.path.abspath(os.path.join(SPECPATH, '..'))          # emulator/
repo = os.path.abspath(os.path.join(root, '..'))
version = os.environ.get('EMU_VERSION', 'dev')
icon = os.environ.get('EMU_ICON') or None                    # .ico / .icns from packaging/make_icons.py, optional

for need in ('data/synthetic_eeprom.bin', 'data/v205_tables.json', 'data/firmware/2_fast/EEVBlog.bin',
             'data/firmware/1_like_v2.05/EEVBlog.bin', 'ui/assets/lcd/LICENSE'):
    if not os.path.isfile(os.path.join(root, need)):
        raise SystemExit('packaging: %s is missing (run emulator/tools/prepare_data.py)' % need)

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
    hiddenimports=['ui.server'] + collect_submodules('unicorn'),   # unicorn imports its arch modules by name
    excludes=['tkinter', 'numpy', 'PIL', 'matplotlib'],
)
# Windows: the Microsoft C runtime DLLs PyInstaller takes from the Python installation can be older than the ones the
# unicorn DLL was built against; loaded from the application folder they win over the system copies and the process
# ends with 0xC0000409 (fail-fast) as soon as emulation starts, while the same code runs under python.exe, which uses
# the system copies.  Bundle the system's (current) runtime DLLs instead; they are redistributable.
if sys.platform == 'win32':
    _sys32 = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32')
    _crt = ('vcruntime140.dll', 'vcruntime140_1.dll', 'msvcp140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll', 'concrt140.dll')
    a.binaries = [b for b in a.binaries if os.path.basename(b[0]).lower() not in _crt]
    for _n in _crt:
        _f = os.path.join(_sys32, _n)
        if os.path.isfile(_f):
            a.binaries.append((_n, _f, 'BINARY'))
            print('packaging: C runtime from the system:', _f)

pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='121gw-emulator', icon=icon,
          console=(sys.platform != 'darwin'))                   # macOS: windowed .app; the UI has a Quit button
coll = COLLECT(exe, a.binaries, a.datas, name='121gw-emulator')
if sys.platform == 'darwin':
    app = BUNDLE(coll, name='121GW Emulator.app', icon=icon, bundle_identifier='io.github.zombu4.121gw-open-firmware',
                 info_plist={'CFBundleName': '121GW Emulator', 'CFBundleDisplayName': '121GW Emulator',
                             'CFBundleShortVersionString': version, 'CFBundleVersion': version,
                             'NSHighResolutionCapable': True})
