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

a = Analysis(
    [os.path.join(root, 'launcher.py')],
    pathex=[root],
    binaries=collect_dynamic_libs('unicorn') + collect_dynamic_libs('capstone'),   # no stock hook ships unicorn's library
    datas=[(os.path.join(root, 'ui', 'index.html'), 'ui'),
           (os.path.join(root, 'ui', 'assets'), os.path.join('ui', 'assets')),
           (os.path.join(root, 'data'), 'data'),
           (os.path.join(repo, 'LICENSE'), '.')],
    hiddenimports=['ui.server'] + collect_submodules('unicorn'),   # unicorn imports its arch modules by name
    excludes=['tkinter', 'numpy', 'PIL', 'matplotlib'],
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='121gw-emulator', icon=icon,
          console=(sys.platform != 'darwin'))                   # macOS: windowed .app; the UI has a Quit button
coll = COLLECT(exe, a.binaries, a.datas, name='121gw-emulator')
if sys.platform == 'darwin':
    app = BUNDLE(coll, name='121GW Emulator.app', icon=icon, bundle_identifier='io.github.zombu4.121gw-open-firmware',
                 info_plist={'CFBundleName': '121GW Emulator', 'CFBundleDisplayName': '121GW Emulator',
                             'CFBundleShortVersionString': version, 'CFBundleVersion': version,
                             'NSHighResolutionCapable': True})
