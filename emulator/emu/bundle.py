"""Data that ships with the emulator: firmware builds, v2.05 table data and the synthetic EEPROM image.

Layout of the data directory (written by emulator/tools/prepare_data.py, packaged by the release workflow):
    data/firmware/2_fast/EEVBlog.bin           production build  (firmware/Makefile default)
    data/firmware/1_like_v2.05/EEVBlog.bin     strict build      (firmware/Makefile LOOP_V205=1)
    data/v205_tables.json                      v2.05 constant tables of the firmware sources (emu/v205tables.py)
    data/synthetic_eeprom.bin                  SYNTHETIC EEPROM, not a meter's calibration (tools/gen_synthetic_eeprom.py)
The folder names are those of the release archive firmware-<tag>.zip.

The data directory is, in this order: the environment variable EEV121GW_DATA, emulator/data next to this package, and
(in a frozen application) the data folder inside the bundle.  Nothing here reads an original EEVblog image.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIRMWARES = (('2_fast', 'fast (production build)'), ('1_like_v2.05', 'like v2.05 (strict build)'))
DEFAULT_FIRMWARE = '2_fast'


def data_dirs():
    out = []
    if os.environ.get('EEV121GW_DATA'):
        out.append(os.environ['EEV121GW_DATA'])
    out.append(os.path.join(HERE, '..', 'data'))
    if getattr(sys, 'frozen', False):
        out.append(os.path.join(getattr(sys, '_MEIPASS', os.path.dirname(sys.executable)), 'data'))
    return [os.path.normpath(d) for d in out]


def find(*parts):
    """Path of a file in the first data directory that has it, or None."""
    for d in data_dirs():
        p = os.path.join(d, *parts)
        if os.path.isfile(p):
            return p
    return None


def firmware_path(name):
    p = find('firmware', name, 'EEVBlog.bin')
    if p is None:
        raise FileNotFoundError(f'bundled firmware {name!r} not found in {data_dirs()}; run emulator/tools/prepare_data.py '
                                'or give an image with --app')
    return p


def firmware_choices():
    """[(name, label)] of the bundled firmware builds that are present."""
    return [(n, label) for n, label in FIRMWARES if find('firmware', n, 'EEVBlog.bin')]


def tables_path():
    p = find('v205_tables.json')
    if p is None:
        raise FileNotFoundError(f'v2.05 table data v205_tables.json not found in {data_dirs()}; run '
                                'emulator/tools/prepare_data.py or give the original image with --v205-image')
    return p


def eeprom_path():
    p = find('synthetic_eeprom.bin')
    if p is None:
        raise FileNotFoundError(f'synthetic_eeprom.bin not found in {data_dirs()}; run emulator/tools/prepare_data.py '
                                'or give an EEPROM image with --eeprom')
    return p
