#!/usr/bin/env python3
"""plan_emulator_tests.py - the emulator test scripts a push has to run (owner 2026-11-09: "you wasting resources and my
time": every push ran all 27 scripts, about 26 minutes, whatever had changed).

    python3 -I .github/scripts/plan_emulator_tests.py BEFORE AFTER      prints the JSON list for the workflow's matrix

A script runs when a file changed under one of its paths (SCRIPTS: the firmware sources it exercises and checks, its
own file and the helper scripts it imports; from its docstring, its imports and the map symbols it reads, collected
2026-11-09), or under a path every script depends on (ALL: the emulator core, the shared helper, the boot, clock,
main loop and display code every run passes through, the build and the table generators, the workflow).  A change of
this file runs the scripts whose entry is new or changed.  An uncertain entry is kept broad: one script too many is wasted minutes, one too few is a missed bug.
Every script runs when BEFORE is empty, all zeros (a new branch) or not in the history (a force push).
"""
import json
import subprocess
import sys

CARD = ['firmware/src/sd/', 'firmware/src/ff16/', 'firmware/src/log/', 'emulator/tools/btft.py']
BT = ['firmware/src/ble/', 'firmware/src/set/', 'emulator/scripts/test_bt_upload.py', 'emulator/tools/btft.py']
FILES = ['emulator/scripts/test_bft_files.py'] + BT + CARD
CAREFUL = ['emulator/scripts/test_careful.py'] + FILES
VERSION = ['emulator/scripts/test_ble_version.py', 'firmware/src/ble/']

ALL = ['emulator/app.py', 'emulator/emu/', 'emulator/data/', 'emulator/tools/prepare_data.py',
       'emulator/tools/gen_synthetic_eeprom.py', 'emulator/scripts/test_backlight_timer.py',
       'firmware/src/sys/reset.s', 'firmware/src/sys/vectors.s', 'firmware/src/sys/clock.s',
       'firmware/src/sys/msical.s', 'firmware/src/sys/isr_tim2.s', 'firmware/src/sys/main.s', 'firmware/src/sys/fault.s',
       'firmware/src/sys/data_v205.s', 'firmware/src/inc/', 'firmware/src/brd/', 'firmware/src/lcd/', 'firmware/src/key/',
       'firmware/src/nvm/', 'firmware/src/cal/records.s', 'firmware/src/cal/cache.s', 'firmware/link/',
       'firmware/Makefile', 'firmware/tools/', '.github/actions/', '.github/workflows/emulator.yml', 'tables_v205.s']
PLANNER = '.github/scripts/plan_emulator_tests.py'   # a change here runs the scripts whose entry is new or changed

SCRIPTS = {
    'test_sd_scr.py': CARD,
    'test_sd_errors.py --cases write,read,burst20': CARD,
    'test_sd_errors.py --cases forced,burst_all': CARD,
    'test_dcv_fast.py': ['firmware/src/mdc/', 'firmware/src/hy/', 'firmware/src/func/', 'firmware/src/mode/'],
    'test_bft_files.py': FILES,
    'test_bft_settings.py': FILES + ['emulator/scripts/test_bft_settings.py', 'firmware/src/mtmp/', 'firmware/src/func/',
                                     'firmware/src/pwr/', 'firmware/src/mres/', 'firmware/src/mva/'],
    'test_calbin_ident.py': FILES + ['firmware/src/cal/'],
    'test_sd_capacity.py': CARD,
    'test_sd_slow.py': CARD,
    'test_sd_clock.py': CARD,
    'test_cap_timeout.py': ['firmware/src/mres/', 'firmware/src/ar/'],
    'test_cap_antihunt.py': ['firmware/src/mres/', 'firmware/src/ar/', 'firmware/src/ui/', 'firmware/src/set/'],
    'test_ble_overrun.py': VERSION,
    'test_xdiag.py': VERSION + BT + ['emulator/scripts/test_ble_overrun.py', 'firmware/src/pwr/'],
    'test_msical.py': VERSION + BT + ['firmware/src/pwr/'],
    'test_apo_wake.py': ['firmware/src/pwr/', 'firmware/src/bzb/', 'firmware/src/ble/'],
    'test_apo_time.py': ['firmware/src/pwr/', 'firmware/src/set/'],
    'test_careful.py': CAREFUL,
    'test_bargraph.py': ['firmware/src/mva/', 'firmware/src/mres/', 'firmware/src/ui/', 'firmware/src/mode/',
                         'firmware/src/func/'],
    'test_diode_chirp.py': ['firmware/src/mres/', 'firmware/src/set/', 'firmware/src/bzb/'],
    # continuity decision, the user threshold pages and their remote settings (page Ld on a card: FILES)
    'test_cont_user.py': FILES + ['firmware/src/mres/', 'firmware/src/bzb/'],
    'test_meter_api.py': FILES + ['emulator/scripts/test_meter_api.py', 'firmware/src/set/', 'firmware/src/key/',
                                  'firmware/src/mres/'],
    'test_setup_walks.py': ['firmware/src/set/', 'firmware/src/log/', 'firmware/src/func/'],
    'test_buzzer_off.py': ['firmware/src/bzb/', 'firmware/src/mres/', 'firmware/src/pwr/', 'firmware/src/set/'],
    'test_heartbeat.py': CAREFUL,
    'test_power_pairs.py': ['firmware/src/cal/', 'firmware/src/pwr/', 'firmware/src/ui/'],
    'test_link2.py': CAREFUL,
    'test_packed.py': FILES + ['emulator/tools/zdyn.py', 'firmware/src/sys/zdef.s', 'firmware/src/sys/zinf.s'],
    # the firmware update over page Ld (first install of the two-part bootloader, meters on EEVblog's bootloader):
    # ble/bft.s writes the file to the card (sd, ff16), the helper btft.py and the card image tools
    'test_bt_upload.py': ['firmware/src/ble/', 'firmware/src/sd/', 'firmware/src/ff16/', 'emulator/tools/btft.py',
                          'emulator/scripts/test_bt_upload.py', 'firmware/src/sys/zinf.s'],
}


def run_all(before, after):
    if not before or set(before) == {'0'}:
        return True
    return subprocess.run(['git', 'cat-file', '-e', before + '^{commit}'], capture_output=True).returncode != 0


def plan(changed):
    if any(any(p in f if p == 'tables_v205.s' else f.startswith(p) for p in ALL) for f in changed):
        return list(SCRIPTS)
    out = []
    for entry, paths in SCRIPTS.items():
        own = 'emulator/scripts/' + entry.split()[0]
        if any(f == own or any(f.startswith(p) for p in paths) for f in changed):
            out.append(entry)
    return out


def entries_changed(before):
    """The scripts whose entry in SCRIPTS differs from that of this file at BEFORE (new ones included)."""
    old = subprocess.run(['git', 'show', '%s:%s' % (before, PLANNER)], capture_output=True, text=True)
    if old.returncode:
        return list(SCRIPTS)
    space = {'__name__': 'old_planner'}
    exec(compile(old.stdout, PLANNER, 'exec'), space)
    prev = space.get('SCRIPTS', {})
    return [s for s, paths in SCRIPTS.items() if prev.get(s) != paths]


def main(argv):
    before, after = (argv + ['', ''])[:2]
    if run_all(before, after):
        scripts = list(SCRIPTS)
    else:
        changed = subprocess.run(['git', 'diff', '--name-only', before, after], capture_output=True, text=True,
                                 check=True).stdout.split()
        scripts = plan(changed)
        if PLANNER in changed:
            scripts += [s for s in entries_changed(before) if s not in scripts]
    print(json.dumps(scripts))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
