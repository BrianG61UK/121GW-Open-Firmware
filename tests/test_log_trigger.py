"""The log trigger (GitHub issue 40): which readings become CSV rows while recording.

record.LogTrigger applies the meter's own rules (firmware USER_GUIDE "Logging trigger", log/trigger.s) to the readings
the program receives: every reading, an interval, a change of the displayed digits (tested once per second), a change of
the limit verdict.  The statistics and the trend still get every reading.  The reading times below are binary fractions,
so the sums the trigger makes are exact.
"""
import os
import shutil
import tempfile
import unittest

from support import card  # noqa: F401  (sets the import path)
from meter121 import derived, record
from meter121.record import LogTrigger


def rd(t, value=1.0, dp=3, mode=1, unit='V', rng=0, clamp=0, overload=False):
    """A reading as display.decode makes it; value None is an overload (overload=True) or a blank display."""
    return {'t': t, 'mode': mode, 'mode_name': 'DCV', 'range': rng, 'clamp': clamp, 'unit': unit, 'dp': dp,
            'value': None if overload else value, 'overload': overload,
            'text': 'OFL' if overload else '-----' if value is None else '%.*f' % (dp or 0, value),
            'sub_text': '', 'sub_unit': '', 'symbols': []}


def taken(trigger, readings, verdicts=None):
    """The times of the readings the trigger accepts."""
    return [r['t'] for i, r in enumerate(readings) if trigger.accept(r, verdicts[i] if verdicts else None)]


class Modes(unittest.TestCase):
    def test_every_reading_is_the_default(self):
        t = LogTrigger()
        self.assertEqual((t.mode, t.interval, t.change), ('all', 1, 10))
        self.assertEqual(taken(t, [rd(i * 0.25) for i in range(8)]), [i * 0.25 for i in range(8)])

    def test_interval_rows_every_interval_seconds(self):
        t = LogTrigger('interval', 2, 10)
        self.assertEqual(taken(t, [rd(i * 0.5) for i in range(14)]), [0.0, 2.0, 4.0, 6.0])      # the first reading, then every 2 s

    def test_interval_zero_is_every_reading(self):
        t = LogTrigger('interval', 0, 10)
        self.assertEqual(len(taken(t, [rd(i * 0.1) for i in range(20)])), 20)

    def test_interval_rows_do_not_drift_and_a_gap_restarts_the_count(self):
        t = LogTrigger('interval', 1, 10)
        times = [0.0, 0.4, 0.8, 1.2, 1.6, 2.0, 2.4, 2.8, 3.2]
        self.assertEqual(taken(t, [rd(x) for x in times]), [0.0, 1.2, 2.0, 3.2])       # 2.0 is not 2.2: the steps are whole intervals
        t = LogTrigger('interval', 2, 10)
        self.assertEqual(taken(t, [rd(x) for x in (0.0, 10.5, 12.0, 12.5, 13.0)]), [0.0, 10.5, 12.5])   # after the gap 2 s from 10.5

    def test_change_needs_the_threshold_and_is_tested_once_per_second(self):
        t = LogTrigger('change', 0, 10)
        seq = [(0.0, 1.00),      # first reading: a row (level 100: two digits after the point)
               (0.5, 1.50),      # +50 but the test is not due yet
               (1.0, 1.50),      # the test: +50 since the last row -> row (level 150)
               (1.5, 1.55),
               (2.0, 1.59),      # +9: below the threshold
               (3.0, 1.60),      # +10: the threshold counts ("at least")
               (3.5, 5.00),      # a big step between two tests
               (3.75, 5.00),
               (4.0, 5.00)]      # the test sees it
        self.assertEqual(taken(t, [rd(x, v, dp=2) for x, v in seq]), [0.0, 1.0, 3.0, 4.0])

    def test_change_counts_the_displayed_digits_with_their_sign(self):
        t = LogTrigger('change', 0, 100)
        # dp 0: a plain integer; -50 to +50 is 100 counts
        self.assertEqual(taken(t, [rd(0.0, -50.0, dp=0), rd(1.0, 49.0, dp=0), rd(2.0, 50.0, dp=0), rd(3.0, 51.0, dp=0)]), [0.0, 2.0])
        self.assertEqual(LogTrigger.level(rd(0, -1.5, dp=2)), ('num', -150))
        self.assertEqual(LogTrigger.level(rd(0, 0.30000000000000004, dp=3)), ('num', 300))      # float noise does not move a digit
        self.assertEqual(LogTrigger.level(rd(0, 12.0, dp=None)), ('num', 12))

    def test_change_with_an_interval_adds_interval_rows_on_its_own_clock(self):
        t = LogTrigger('change', 5, 255)
        seq = [(float(k), 1.0 if k < 3 else 9.0) for k in range(8)]
        # t=3: 8000 counts, row.  The interval row at 5 s is not moved by it (the meter's counters are separate)
        self.assertEqual(taken(t, [rd(x, v) for x, v in seq]), [0.0, 3.0, 5.0])
        t = LogTrigger('change', 0, 255)
        self.assertEqual(taken(t, [rd(float(k), 1.0) for k in range(8)]), [0.0])               # interval 0: the trigger only

    def test_a_change_of_mode_unit_range_or_clamp_is_a_change(self):
        for other in (dict(mode=2), dict(unit='mV'), dict(rng=1), dict(clamp=2)):
            with self.subTest(other=other):
                t = LogTrigger('change', 0, 255)                # the threshold cannot be reached by the digits
                self.assertEqual(taken(t, [rd(0.0), rd(0.5, **other), rd(1.0, **other), rd(2.0, **other)]), [0.0, 1.0])
                self.assertEqual(taken(t, [rd(3.0, **other), rd(4.0)]), [4.0])      # the same key again: none; back to the first: a change

    def test_overload_and_blank_against_a_number(self):
        t = LogTrigger('change', 0, 255)
        seq = [rd(0.0), rd(1.0, overload=True), rd(2.0, overload=True),      # number -> OFL: row; OFL again: none
               rd(3.0),                                                      # OFL -> number: row
               rd(4.0, None),                                                # number -> blank: row
               rd(5.0, None),
               rd(6.0, overload=True)]                                       # blank -> OFL: another kind, row
        self.assertEqual(taken(t, seq), [0.0, 1.0, 3.0, 4.0, 6.0])

    def test_limit_verdict_changes(self):
        t = LogTrigger('limit', 0, 10)
        verdicts = ['PASS', 'PASS', 'HI', 'HI', 'PASS', 'LO', None, None]
        seq = [rd(i * 0.25) for i in range(len(verdicts))]
        self.assertEqual(taken(t, seq, verdicts), [0.0, 0.5, 1.0, 1.25, 1.5])          # first, PASS->HI, HI->PASS, PASS->LO, LO->None

    def test_limit_with_an_interval_writes_while_outside_the_limits(self):
        for verdict, rows in (('HI', [0.0, 2.0, 4.0, 6.0]), ('LO', [0.0, 2.0, 4.0, 6.0]), ('PASS', [0.0]),
                              (None, [0.0, 2.0, 4.0, 6.0])):         # None: no limit set; the meter's limit test off does the same
            with self.subTest(verdict=verdict):
                t = LogTrigger('limit', 2, 10)
                self.assertEqual(taken(t, [rd(float(k)) for k in range(7)], [verdict] * 7), rows)

    def test_limit_without_a_limit_and_without_an_interval_writes_the_first_reading_only(self):
        t = LogTrigger('limit', 0, 10)
        self.assertEqual(taken(t, [rd(float(k)) for k in range(5)], [None] * 5), [0.0])

    def test_a_new_recording_starts_with_a_row_again(self):
        t = LogTrigger('interval', 5, 10)
        self.assertEqual(taken(t, [rd(0.0), rd(1.0)]), [0.0])
        t.reset()
        self.assertEqual(taken(t, [rd(1.5), rd(2.0)]), [1.5])
        t.configure('change', 5, 10)
        self.assertEqual(taken(t, [rd(2.5)]), [2.5])

    def test_bad_rules_are_refused(self):
        t = LogTrigger('interval', 3, 4)
        for args in (('sometimes', 1, 10), (None, 1, 10), ('interval', -1, 10), ('interval', 1000, 10), ('interval', True, 10),
                     ('interval', 1.5, 10), ('interval', '2', 10), ('change', 1, 0), ('change', 1, 256), ('change', 1, True)):
            with self.assertRaises(ValueError, msg=str(args)):
                t.configure(*args)
        self.assertEqual((t.mode, t.interval, t.change), ('interval', 3, 4))      # a refused rule changes nothing
        LogTrigger('limit', 999, 255)
        LogTrigger('change', 0, 1)


class Verdict(unittest.TestCase):
    def test_derived_verdict_of_the_last_reading(self):
        d = derived.Derived()
        self.assertIsNone(d.verdict())                                  # no reading yet
        d.feed(rd(0.0, 1.5))
        self.assertIsNone(d.verdict())                                  # no limit set
        d.set_options({'limit': {'lo': 1, 'hi': 2, 'unit': 'V'}})
        for value, verdict in ((0.5, 'LO'), (1.5, 'PASS'), (3.0, 'HI')):
            d.feed(rd(0.0, value))
            self.assertEqual(d.verdict(), verdict)
            self.assertEqual(d.snapshot()['limit']['verdict'], verdict)
        d.feed(dict(rd(0.0, 1.5), symbols=['REL']))
        self.assertIsNone(d.verdict())                                  # REL: a difference, no verdict
        d.feed(rd(0.0, 1.5, unit='Hz'))
        self.assertIsNone(d.verdict())                                  # another quantity
        d.feed(rd(0.0, overload=True))
        self.assertIsNone(d.verdict())


class SessionRows(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.s = record.Session()

    def rows(self, path):
        with open(path, encoding='utf-8') as f:
            return f.read().splitlines()[1:]

    def test_the_trigger_limits_the_rows_only(self):
        path = self.s.start_recording(self.tmp, trigger=('interval', 2, 10))
        for i in range(8):
            self.s.add(rd(1000.0 + i * 0.5, 1.0 + i))
        self.s.stop_recording()
        self.assertEqual(len(self.rows(path)), 2)                       # 1000.0 and 1002.0
        self.assertEqual(self.s.rec_rows, 2)
        self.assertEqual(self.s.stats.n, 8)                             # the statistics, the trend and the last reading: all of them
        self.assertEqual(len(self.s.trend), 8)
        self.assertEqual(self.s.frames, 8)
        self.assertEqual(self.s.last['value'], 8.0)

    def test_every_reading_by_default_and_the_overload_is_a_row_as_before(self):
        path = self.s.start_recording(self.tmp)
        self.s.add(rd(1000.0, 1.0))
        self.s.add(rd(1000.5, overload=True))
        self.s.stop_recording()
        rows = self.rows(path)
        self.assertEqual(len(rows), 2)
        self.assertIn('OFL', rows[1])

    def test_limit_trigger_takes_the_verdict_given_with_the_reading(self):
        path = self.s.start_recording(self.tmp, trigger=('limit', 0, 10))
        for i, v in enumerate(('PASS', 'PASS', 'HI', 'PASS')):
            self.s.add(rd(1000.0 + i, 1.0 + i), v)
        self.s.stop_recording()
        self.assertEqual([r.split(',')[4] for r in self.rows(path)], ['1.0', '3.0', '4.0'])

    def test_a_bad_rule_starts_no_recording(self):
        folder = os.path.join(self.tmp, 'new')
        with self.assertRaises(ValueError):
            self.s.start_recording(folder, trigger=('sometimes', 1, 10))
        self.assertFalse(os.path.exists(folder))
        self.assertIsNone(self.s.rec_path)
        self.assertFalse(self.s.snapshot()['recording'])

    def test_each_recording_starts_with_a_row(self):
        for _ in range(2):
            path = self.s.start_recording(self.tmp, trigger=('interval', 999, 10))
            self.s.add(rd(1000.0))
            self.s.add(rd(1001.0))
            self.s.stop_recording()
            self.assertEqual(len(self.rows(path)), 1)


if __name__ == '__main__':
    unittest.main()
