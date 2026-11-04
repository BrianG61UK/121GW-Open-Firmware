"""check_fw_version.py - a release tag vA.B.C must match the version the production firmware shows at power-on.

    python3 -I .github/scripts/check_fw_version.py TAG [firmware/src/inc/config.inc]

The firmware shows "F-A.BC" (FW_VER_C0..C4 of config.inc: 'F', '-', A, B, C, the decimal point after the third
character).  Exit status 1 with the reason when the tag and the characters differ, or when
the tag cannot be shown in that form (A, B and C must be single digits).  Standard library only.
"""
import re
import sys


def main(argv):
    tag = argv[0]
    path = argv[1] if len(argv) > 1 else 'firmware/src/inc/config.inc'
    m = re.fullmatch(r'v(\d)\.(\d)\.(\d)', tag)
    if not m:
        print(f'check_fw_version: tag {tag!r} is not vA.B.C with single digits, the form the meter can show (F-A.BC)')
        return 1
    text = open(path).read()
    chars = dict(re.findall(r"\.equ FW_VER_C(\d), '(.)'", text))
    shown = ''.join(chars.get(str(i), '?') for i in range(5))
    want = 'F-' + ''.join(m.groups())
    if shown != want:
        print(f'check_fw_version: tag {tag} needs the production firmware to show "{want[:3]}.{want[3:]}", '
              f'{path} has "{shown[:3]}.{shown[3:]}": change FW_VER_C2..C4 and tag again')
        return 1
    print(f'check_fw_version: tag {tag} = firmware "{shown[:3]}.{shown[3:]}"')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
