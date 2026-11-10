"""Derived values: Pt100 / Pt1000 (IEC 60751), REL percent, loop percent, limit verdict, option checks."""
import unittest

from support import card  # noqa: F401  (sets the import path)
from meter121 import derived, display


def reading(mode, value, unit, symbols=(), overload=False):
    return {'t': 0.0, 'mode': mode, 'value': None if overload else value, 'unit': unit, 'symbols': list(symbols), 'range': 0}


def frame(mode, rng, mag, symbols16=0, flags6=0):
    f = bytearray(19)
    f[0] = 0xF2
    f[5] = mode | ((mag >> 16) & 3) << 6
    f[6] = rng | flags6
    f[7], f[8] = (mag >> 8) & 0xFF, mag & 0xFF
    f[16] = symbols16
    x = 0
    for b in f[:18]:
        x ^= b
    f[18] = x
    return bytes(f)


class PtMaths(unittest.TestCase):
    def test_iec_60751_table_values(self):
        # IEC 60751 table: Pt100 at 0, 100 and -100 degC
        self.assertEqual(round(derived.pt_resistance(0, 100.0), 2), 100.00)
        self.assertEqual(round(derived.pt_resistance(100, 100.0), 2), 138.51)
        self.assertEqual(round(derived.pt_resistance(-100, 100.0), 2), 60.26)

    def test_inverse_of_the_table_values(self):
        for ohm, t in ((100.00, 0.0), (138.51, 100.0), (60.26, -100.0)):
            self.assertAlmostEqual(derived.pt_temperature(ohm, 100.0), t, delta=0.03)

    def test_round_trip_over_the_whole_range(self):
        for r0 in (100.0, 1000.0):
            t = -200.0
            while t <= 850.0:
                self.assertAlmostEqual(derived.pt_temperature(derived.pt_resistance(t, r0), r0), t, places=6)
                t += 12.5

    def test_pt1000_is_ten_times_pt100(self):
        self.assertAlmostEqual(derived.pt_resistance(37.0, 1000.0), 10 * derived.pt_resistance(37.0, 100.0))

    def test_outside_the_range_is_none(self):
        self.assertIsNone(derived.pt_temperature(18.0, 100.0))         # below -200 degC (18.52 ohm)
        self.assertIsNone(derived.pt_temperature(391.0, 100.0))        # above 850 degC (390.48 ohm)
        self.assertIsNone(derived.pt_temperature(float('nan'), 100.0))
        self.assertAlmostEqual(derived.pt_temperature(390.4811, 100.0), 850.0, places=3)

    def test_snapshot_in_ohm_mode(self):
        d = derived.Derived({'pt_type': 'Pt100'})
        d.feed(reading(9, 138.51, derived.OMEGA))
        self.assertAlmostEqual(d.snapshot()['pt_c'], 100.0, delta=0.03)
        d.feed(reading(9, 0.13851, 'k' + derived.OMEGA))               # the unit prefix is taken into account
        self.assertAlmostEqual(d.snapshot()['pt_c'], 100.0, delta=0.03)
        d.feed(reading(9, 0.0, derived.OMEGA, overload=True))
        self.assertIsNone(d.snapshot()['pt_c'])
        d.feed(reading(1, 138.51, 'V'))                                # another mode
        self.assertIsNone(d.snapshot()['pt_c'])
        d.set_options({'pt_type': None})
        d.feed(reading(9, 138.51, derived.OMEGA))
        self.assertIsNone(d.snapshot()['pt_c'])

    def test_pt_with_rel_uses_the_difference_as_sensor_resistance(self):
        d = derived.Derived({'pt_type': 'Pt100'})
        d.feed(reading(9, 0.2, derived.OMEGA))
        d.feed(reading(9, 138.51, derived.OMEGA, ['REL']))
        self.assertAlmostEqual(d.snapshot()['pt_c'], 100.0, delta=0.03)


class RelLoopLimit(unittest.TestCase):
    def test_rel_percent(self):
        d = derived.Derived()
        d.feed(reading(1, 5.0, 'V'))
        self.assertIsNone(d.snapshot()['rel_pct'])
        d.feed(reading(1, 0.0, 'V', ['REL']))                          # REL just went on: the reference is 5 V
        self.assertEqual(d.snapshot()['rel_pct'], 0.0)
        d.feed(reading(1, 0.25, 'V', ['REL']))
        self.assertAlmostEqual(d.snapshot()['rel_pct'], 5.0)
        d.feed(reading(1, -250.0, 'mV', ['REL']))                      # the unit changed with the range: still -5 %
        self.assertAlmostEqual(d.snapshot()['rel_pct'], -5.0)
        d.feed(reading(1, 5.2, 'V'))                                   # REL off
        self.assertIsNone(d.snapshot()['rel_pct'])
        d.feed(reading(1, 0.0, 'V', ['REL']))                          # REL on again: the new reference is 5.2 V
        d.feed(reading(1, 0.52, 'V', ['REL']))
        self.assertAlmostEqual(d.snapshot()['rel_pct'], 10.0)

    def test_rel_already_on_when_connecting_is_unknown(self):
        d = derived.Derived()
        d.feed(reading(1, 0.1, 'V', ['REL']))
        d.feed(reading(1, 0.2, 'V', ['REL']))
        self.assertIsNone(d.snapshot()['rel_pct'])

    def test_rel_reference_zero_and_mode_change(self):
        d = derived.Derived()
        d.feed(reading(1, 0.0, 'V'))
        d.feed(reading(1, 0.3, 'V', ['REL']))
        self.assertIsNone(d.snapshot()['rel_pct'])                     # reference 0: no percent
        d.feed(reading(1, 2.0, 'V'))
        d.feed(reading(1, 0.1, 'V', ['REL']))
        d.feed(reading(2, 0.1, 'V', ['REL']))                          # mode changed while REL stayed on
        self.assertIsNone(d.snapshot()['rel_pct'])

    def test_loop_percent(self):
        d = derived.Derived()
        for mA, p420, p020 in ((4.0, 0.0, 20.0), (12.0, 50.0, 60.0), (20.0, 100.0, 100.0), (0.0, -25.0, 0.0)):
            d.set_options({'loop_range': '4-20'})
            d.feed(reading(19, mA, 'mA'))
            self.assertAlmostEqual(d.snapshot()['loop_pct'], p420)
            d.set_options({'loop_range': '0-20'})
            self.assertAlmostEqual(d.snapshot()['loop_pct'], p020)
        d.feed(reading(17, 12000.0, derived.MU + 'A'))                 # DCuA, in microampere
        self.assertAlmostEqual(d.snapshot()['loop_pct'], 60.0)
        d.feed(reading(18, 12.0, 'mA'))                                # ACmA: not a loop
        self.assertIsNone(d.snapshot()['loop_pct'])
        d.feed(reading(19, 12.0, 'mA', ['REL']))
        self.assertIsNone(d.snapshot()['loop_pct'])
        self.assertEqual(d.snapshot()['loop_range'], '0-20')

    def test_loop_from_a_real_status_frame(self):
        d = derived.Derived()
        d.feed(display.decode(frame(19, 1, 12000), 0.0))               # DCmA range 1: 12.000 mA
        self.assertAlmostEqual(d.snapshot()['loop_pct'], 50.0)

    def test_rel_from_a_real_status_frame(self):
        d = derived.Derived()
        d.feed(display.decode(frame(9, 0, 100000 - 1), 0.0))           # OHM 99.999 ohm
        d.feed(display.decode(frame(9, 0, 5000, symbols16=0x10), 0.0))  # REL lit: difference 5.000 ohm
        self.assertAlmostEqual(d.snapshot()['rel_pct'], 5.0 / 99.999 * 100, places=3)

    def test_limit_verdict(self):
        d = derived.Derived({'limit': {'lo': 99.0, 'hi': 101.0, 'unit': 'ohm'}})
        verdict = lambda v, u: (d.feed(reading(9, v, u)), d.snapshot()['limit']['verdict'])[1]
        self.assertEqual(verdict(100.0, derived.OMEGA), 'PASS')
        self.assertEqual(verdict(99.0, derived.OMEGA), 'PASS')         # on the limit
        self.assertEqual(verdict(101.0, derived.OMEGA), 'PASS')
        self.assertEqual(verdict(98.99, derived.OMEGA), 'LO')
        self.assertEqual(verdict(101.01, derived.OMEGA), 'HI')
        self.assertEqual(verdict(0.0985, 'k' + derived.OMEGA), 'LO')   # 98.5 ohm in kilohm: unit conversion
        self.assertEqual(verdict(0.1005, 'k' + derived.OMEGA), 'PASS')
        d.feed(reading(9, 0.0, derived.OMEGA, overload=True))
        self.assertIsNone(d.snapshot()['limit']['verdict'])            # the frame does not carry the sign of an overload
        d.feed(reading(1, 100.0, 'V'))                                 # another quantity
        self.assertIsNone(d.snapshot()['limit']['verdict'])
        d.feed(reading(9, 50.0, derived.OMEGA, ['REL']))               # a difference is not the quantity
        self.assertIsNone(d.snapshot()['limit']['verdict'])
        self.assertEqual(d.snapshot()['limit'], {'lo': 99.0, 'hi': 101.0, 'unit': derived.OMEGA, 'verdict': None})

    def test_one_sided_and_cleared_limit(self):
        d = derived.Derived({'limit': {'lo': None, 'hi': 5.0, 'unit': 'V'}})
        d.feed(reading(1, -20.0, 'V'))
        self.assertEqual(d.snapshot()['limit']['verdict'], 'PASS')
        d.feed(reading(1, 5.5, 'V'))
        self.assertEqual(d.snapshot()['limit']['verdict'], 'HI')
        d.set_options({'limit': None})
        self.assertEqual(d.snapshot()['limit'], {'lo': None, 'hi': None, 'unit': None, 'verdict': None})

    def test_limit_unit_defaults_to_the_reading_unit(self):
        d = derived.Derived()
        d.feed(reading(1, 1.0, 'mV'))
        d.set_options({'limit': {'lo': 0, 'hi': 2}})
        self.assertEqual(d.options()['limit']['unit'], 'mV')


class BeepThreshold(unittest.TestCase):
    def sub(self, code, value=0, mode=10):
        f = bytearray(frame(mode, 0, 3000))
        f[9], f[11], f[12] = code, value >> 8, value & 0xFF
        return display.decode(bytes(f), 0.0)

    def test_every_fixed_code(self):
        for code, text in enumerate(display.BEEP_TEXT[:16]):
            d = self.sub(0xAA + code)
            self.assertEqual((d['sub_label'], d['sub_text'], d['sub_unit']), ('threshold', text, ''), code)

    def test_code_10_is_not_the_db_page(self):
        # the threshold code 10 (UP  1) is sent as 0xB4 = 180, the code of the dB page of ACV
        self.assertEqual(self.sub(0xB4)['sub_text'], 'UP  1')
        self.assertEqual(self.sub(180, mode=2)['sub_label'], 'dB')

    def test_user_codes_show_the_threshold(self):
        d = self.sub(0xBA, 123)
        self.assertEqual((d['sub_label'], d['sub_text'], d['sub_unit']), ('threshold', 'DN 123', 'Ω'))
        d = self.sub(0xBB, 500)
        self.assertEqual((d['sub_label'], d['sub_text'], d['sub_unit']), ('threshold', 'UP 500', 'Ω'))


class Options(unittest.TestCase):
    def test_bad_options_are_refused_and_change_nothing(self):
        d = derived.Derived()
        for bad in ({'loop_range': '5-25'}, {'pt_type': 'Pt500'}, {'limit': {'lo': 5, 'hi': 1, 'unit': 'V'}},
                    {'limit': {'lo': 'a', 'hi': 1, 'unit': 'V'}}, {'limit': {'lo': 1, 'hi': 2, 'unit': 'furlong'}},
                    {'limit': {'lo': 1, 'hi': 2}}, {'limit': 5}, {'loop_range': ['4-20']}):
            with self.assertRaises(ValueError, msg=str(bad)):
                d.set_options(bad)
        self.assertEqual(d.options(), derived.DEFAULTS)
        with self.assertRaises(ValueError):
            d.set_options('x')

    def test_options_round_trip_through_json(self):
        import json
        d = derived.Derived({'loop_range': '0-20', 'pt_type': 'Pt1000', 'limit': {'lo': 1, 'hi': 2, 'unit': 'V'}})
        d2 = derived.Derived(json.loads(json.dumps(d.options())))
        self.assertEqual(d2.options(), d.options())


if __name__ == '__main__':
    unittest.main()
