# PyInstaller spec of the 121GW Companion: one-folder application with everything it needs (Python, bleak with the
# backend of the system it is built on, pywebview, the page).  Build on each system:
#   APP_VERSION=1.2.3 APP_ICON=<icon> pyinstaller --noconfirm packaging/companion.spec
# macOS: "121GW Companion.app" with the Bluetooth usage text the system shows before the first scan.
import os
import sys

from PyInstaller.utils.hooks import collect_submodules

root = os.path.abspath(os.path.join(SPECPATH, '..'))
version = os.environ.get('APP_VERSION', 'dev')
icon = os.environ.get('APP_ICON') or None
# the version for the program itself (meter121/report.py app_version: the diagnosis report names it)
version_file = os.path.join(root, 'build', 'app_version.txt')
os.makedirs(os.path.dirname(version_file), exist_ok=True)
with open(version_file, 'w', encoding='utf-8') as f:
    f.write(version)

if sys.platform == 'darwin':
    backend = ['bleak.backends.corebluetooth'] + collect_submodules('bleak.backends.corebluetooth')
elif sys.platform == 'win32':
    backend = ['bleak.backends.winrt'] + collect_submodules('bleak.backends.winrt') + collect_submodules('winrt')
else:
    backend = ['bleak.backends.bluezdbus'] + collect_submodules('bleak.backends.bluezdbus') + collect_submodules('dbus_fast')

a = Analysis(
    [os.path.join(root, 'packaging', 'entry.py')],
    pathex=[root],
    datas=[(os.path.join(root, 'ui'), 'ui'), (os.path.join(root, 'LICENSE'), '.'), (version_file, '.')],
    hiddenimports=['meter121', 'meter121.app'] + backend
                  + (['webview', 'webview.platforms.cocoa'] if sys.platform == 'darwin' else [])
                  + (['webview', 'webview.platforms.edgechromium', 'webview.platforms.winforms'] if sys.platform == 'win32' else []),
    excludes=['tkinter', 'numpy', 'PIL', 'matplotlib'] + (['webview'] if sys.platform.startswith('linux') else []),
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name='121gw-companion', icon=icon, console=False)
coll = COLLECT(exe, a.binaries, a.datas, name='121gw-companion')
if sys.platform == 'darwin':
    app = BUNDLE(coll, name='121GW Companion.app', icon=icon, bundle_identifier='io.github.zombu4.121gw-companion',
                 info_plist={'CFBundleName': '121GW Companion', 'CFBundleDisplayName': '121GW Companion',
                             'CFBundleShortVersionString': version, 'CFBundleVersion': version,
                             'NSHighResolutionCapable': True,
                             'NSBluetoothAlwaysUsageDescription': 'The 121GW Companion connects to your EEVblog 121GW '
                                                                  'multimeter over Bluetooth to show and record its readings.'})
