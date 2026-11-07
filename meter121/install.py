"""What may be installed on the meter, and what the user is told first: any release of the project (also one older than
the meter has) or a file of the user's own, as firmware or as bootloader.

make_plan() decides from the facts of the connected meter (firmware version, bootloader, mode) and the chosen release or
file: a refusal with its reason (nothing is sent), or the warnings and whether the user must confirm.  A downgrade and
every file of the user's own need the confirmation; an upgrade or the same version does not.  The transfer itself is the
update's (app.py _run_update): no other protocol.

Sources of the facts in the warnings (the project's repository, branches main and bootloader):
  firmware features and the first version with them: firmware/FEATURES.md 2.10a (F-1.03 / F-1.04), 2.15 .. 2.26;
  settings stored in bytes an older firmware does not use: firmware/EEPROM_MAP.md 4.1;
  the bootloader: bootloader/README.md (starter written once, previous bootloader put back, never touches the data
  EEPROM, card update), bootloader/DESIGN.md 6.1 .. 6.3 (limits, trial start), bootloader/src/bl_ble.s (size limits,
  what END checks) and the commits of the bootloader branch for what each bootloader version added.
"""
from . import releases

FIRST_INSTALL_MIN = (1, 0, 3)          # firmware F-1.03: the firmware writes the first install (app.py, FEATURES.md 2.10a)
BL_FW_MAX = 0x4C000                    # largest firmware the two-part bootloader takes (bootloader/DESIGN.md 6.1, bl_ble.s)
CONFIRM_WORD = 'INSTALL'               # what the user types to confirm

# the first firmware version with each feature; a downgrade lists those between the target and the meter's version
FW_FEATURES = (
    ((1, 0, 3), 'F-1.03: the meter answers the bootloader question and the Bluetooth request to restart into the '
                'bootloader\'s update mode. Older firmware does not: the program cannot tell which bootloader the meter '
                'has, and the next update goes through the SD card (page Ld-bt, then MEM + HOLD at power-on and SETUP).'),
    ((1, 0, 4), 'F-1.04: exFAT cards, long file names and the card format page Fr. Older firmware does not list them: a '
                'card formatted as exFAT may not be readable.'),
    ((1, 1, 2), 'F-1.12: card sessions run on the PLL clock. Before, block writes to some cards stopped with a transmit '
                'underrun (GitHub issue 5).'),
    ((1, 1, 5), 'F-1.15: the extended diagnosis (the meter counts the errors of its Bluetooth line); the report loses '
                'that section.'),
    ((1, 1, 6), 'F-1.16: the setting HUnt (capacitance anti-hunting). An older firmware ignores the stored value and '
                'the METER view does not show the row.'),
    ((1, 1, 7), 'F-1.17: the meter-clock measurement in the report and the button Leave Ld-bt (without it a key press on '
                'the meter is needed to leave the page Ld-bt).'),
    ((1, 1, 8), 'F-1.18: the setting auto power-off time and waking from power-off with a key with Bluetooth kept. An '
                'older firmware ignores the stored time (v2.05 always uses 30 minutes); with F-1.17 and v2.05 only '
                'the dial off and on restarted the meter after -oFF-.'),
    ((1, 1, 9), 'F-1.19: careful mode for meters with the old BLE112 Bluetooth module (every reading sent twice, card '
                'lists and downloads in small pieces). Without it such a meter shows damaged readings and card lists '
                'or downloads can fail (GitHub issues 9 and 14).'),
    ((1, 2, 0), 'F-1.20: bar-graph fixes (no full-bar flash and the label 50 in the DIODE 15 V range, the labels of the VA '
                'ranges; GitHub issues 19 and 17). An older firmware has those faults again.'),
    ((1, 2, 1), 'F-1.21: the setting CHIrP (diode contact chirp). An older firmware ignores the stored value and the '
                'METER view does not show the row.'),
    ((1, 2, 2), 'F-1.22: the two SETUP walks (the meter pages come after the page SEt), and Bluetooth on after an update '
                'over Bluetooth with bootloader 1.1.4 (GitHub issues 24 and 23). Older firmware walks all pages in one long '
                'walk and starts with Bluetooth off after an update: hold PEAK so the program can reconnect.'),
)

# what each bootloader version added (commits of the bootloader branch)
BL_FEATURES = (
    ((1, 1, 0), 'B-1.10: reads exFAT cards for the card update. An older bootloader reads FAT12/16/32 only, so a card '
                'formatted as exFAT (page Fr) cannot be used for a card update.'),
    ((1, 1, 1), 'B-1.11: SD driver with the card start-up fixes (IMP-34).'),
    ((1, 1, 2), 'B-1.12: SD driver with the fix OF-66 (sector reads into buffers that are not a multiple of 4 landed 1 to '
                '3 bytes off).'),
    ((1, 1, 3), 'B-1.13: the card update reads the card at the card-session clock (PLL 32 MHz, IMP-41).'),
)

EEPROM_NOTE = ('The transfer and the bootloader do not write the meter\'s data EEPROM (calibration, serial number, '
               'options).')


def _between(table, low, high):
    """Texts of the features whose first version is above `low` and, when `high` is known, not above it."""
    return [t for v, t in table if (low is None or v > low) and (high is None or v <= high)]


def _fmt(kind, v):
    return releases.meter_text(v) if kind == 'firmware' else releases.bootloader_text(v)


def route(meter):
    """'bluetooth' (through the two-part bootloader's update mode) or 'card' (page Ld-bt, then the keys of EEVblog's
    bootloader), as app.py _update_firmware chooses."""
    return 'bluetooth' if meter.get('mode') == 'bootloader' or releases.version_of_bootloader(meter.get('bl')) else 'card'


def make_plan(kind, meter, release=None, custom=None, newest=None):
    """The plan to install `release` (an entry of releases.list_releases()) or the file `custom` ({'name', 'size',
    'sha256'}) as `kind` ('firmware' or 'bootloader') on the meter described by `meter` ({'fw': (A, B, C) or None,
    'bl': 'EEV' / 'B-A.BC' / None, 'mode': 'firmware' / 'bootloader' / 'unknown'}).  `newest` is the version of the
    newest release of that kind (None when not known).

    Returns {'kind', 'label', 'tag', 'custom', 'relation' ('newer', 'same', 'older', 'unknown', 'custom'), 'refusal'
    (the reason, or None), 'needs_confirm', 'warnings' (list of texts), 'word' (what the user types)}."""
    if kind not in ('firmware', 'bootloader'):
        raise ValueError('kind: firmware or bootloader')
    if (release is None) == (custom is None):
        raise ValueError('a release or a file')
    have_fw = meter.get('fw')
    bl = meter.get('bl')
    have_bl = releases.version_of_bootloader(bl)
    two_part = have_bl is not None
    label = custom['name'] if custom else release['text']
    plan = {'kind': kind, 'label': label, 'tag': release['tag'] if release else None, 'custom': bool(custom),
            'relation': 'custom', 'refusal': None, 'needs_confirm': False, 'warnings': [], 'word': CONFIRM_WORD}
    w = plan['warnings']
    current = have_fw if kind == 'firmware' else have_bl
    if release:
        target = release['version']
        if current is None:
            plan['relation'] = 'unknown'
        else:
            plan['relation'] = 'newer' if target > current else 'same' if target == current else 'older'

    # ---- what is refused, whatever the user says
    if kind == 'firmware':
        if custom and route(meter) == 'bluetooth' and custom['size'] > BL_FW_MAX:
            plan['refusal'] = ('the file has %d bytes; the two-part bootloader takes firmware images of at most %d bytes '
                               '(bootloader/DESIGN.md 6.1)' % (custom['size'], BL_FW_MAX))
    else:
        if bl == 'EEV':
            if custom:
                plan['refusal'] = ('a bootloader file of your own is not sent to a meter that still has EEVblog\'s '
                                   'bootloader: the first install writes the starter at the start of flash once and '
                                   'never again (bootloader README), and a starter cannot be checked here and cannot '
                                   'be put back without a programming probe. Install a release of the project first.')
            elif have_fw is None or have_fw < FIRST_INSTALL_MIN:
                plan['refusal'] = ('the first bootloader install needs firmware %s or newer on the meter: update the '
                                   'firmware first' % releases.meter_text(FIRST_INSTALL_MIN))
        elif not two_part:
            plan['refusal'] = ('the meter does not say which bootloader it has (firmware older than %s does not answer '
                               'the question): a bootloader is not sent' % releases.meter_text(FIRST_INSTALL_MIN))
    if plan['refusal']:
        return plan

    # ---- what needs the user's confirmation, and what he is told
    if custom:
        plan['needs_confirm'] = True
        if kind == 'firmware':
            w.append('This is a file of your own, not a release of the project. The program checked what the meter '
                     'checks as well (size, initial stack pointer, reset vector); it cannot tell which firmware this '
                     'is, which version, or that it works on this meter.')
            w.append('Firmware without the project\'s Bluetooth functions (page Ld-bt, the restart into update mode; for '
                     'example EEVblog\'s own v2.05) cannot be updated again over Bluetooth. The SD card route stays: '
                     'EEVBlog.bin in the card\'s root, MEM + HOLD at power-on, then SETUP.')
            w.append('Firmware of another origin need not follow the project\'s rules for the data EEPROM '
                     '(EEPROM_MAP.md 9): it can change the calibration, the serial number and the options. Keep the '
                     'backup of the calibration (cal.bin on the card) first.')
        else:
            w.append('This is a file of your own, not a release of the project. The program checked that it has the '
                     'vector table of the two-part bootloader and a size it accepts; the bootloader itself checks only '
                     'length and CRC-32 of this kind of file (bl_ble.s), and the starter installs and starts what it '
                     'finds. The program cannot tell that this bootloader works on this meter.')
            w.append('If the new bootloader never confirms its start, the starter puts the previous one back at the '
                     'next start (take the batteries out and put them back). A bootloader that starts but cannot '
                     'receive over Bluetooth stays: then only the card update (MEM + HOLD at power-on, then SETUP) '
                     'works, and the starter cannot help.')
        w.append(EEPROM_NOTE)
        return plan

    target = release['version']
    older = plan['relation'] == 'older'
    unsure = plan['relation'] == 'unknown' and newest is not None and target != newest
    if not (older or unsure):
        return plan
    plan['needs_confirm'] = True
    if kind == 'firmware':
        if older:
            w.append('%s is older than the %s on the meter. Going back to an older firmware can break things the newer '
                     'one set up or relies on:' % (label, _fmt(kind, current)))
        else:
            w.append('The program does not know which firmware the meter has (EEVblog\'s v2.05, a firmware older than '
                     'F-1.02, or the meter is in its update mode), so it cannot tell whether %s is older. An older '
                     'firmware can break things a newer one set up or relies on:' % label)
        feats = _between(FW_FEATURES, target, current)
        w.extend('  ' + t for t in feats)
        if not feats:
            w.append('  (no feature of the list in the program lies between the two versions)')
        w.append('Settings that a newer firmware keeps in bytes an older one does not use are ignored by the older '
                 'firmware (EEPROM_MAP.md 4.1).')
    else:
        if older:
            w.append('%s is older than the %s on the meter. An older bootloader lacks what the newer ones added to the '
                     'card update (MEM + HOLD at power-on, then SETUP):' % (label, _fmt(kind, current)))
        else:
            w.append('The meter still has EEVblog\'s bootloader, so this installs the two-part bootloader for the first '
                     'time, and %s is not the newest release (%s). An older bootloader lacks what the newer ones added '
                     'to the card update (MEM + HOLD at power-on, then SETUP):' % (label, _fmt(kind, newest)))
        w.extend('  ' + t for t in _between(BL_FEATURES, target, current))
        if bl == 'EEV':
            w.append('The first install writes the starter at the start of flash, once and never again (bootloader '
                     'README).')
        w.append('The older bootloader is installed like a new one: the starter copies it at the next start (the display '
                 'stays blank for about a second). If it does not start, the starter puts the previous bootloader back '
                 'at the next start (take the batteries out and put them back).')
    w.append(EEPROM_NOTE)
    return plan


def text_of(plan):
    """The plan's warnings as one text (the dialog and the log)."""
    return '\n'.join(plan['warnings'])
