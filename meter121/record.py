"""Readings of a session: statistics, trend history and the CSV recording.

A reading is the dictionary display.decode() makes of a status frame.  Only readings with a numeric value (not overload,
not blank) enter the statistics and the trend; the readings the log trigger (LogTrigger) accepts go into the CSV file
while recording, an overload as "OL".  The statistics restart when the mode, the unit or the range changes, because
values of different scales cannot be combined.
"""
import csv
import math
import os
import threading
import time
from collections import deque

TREND_POINTS = 6000                      # about 10 minutes at the meter's 10 frames per second

LOG_MODES = ('all', 'interval', 'change', 'limit')   # every reading, as the meter's tr-In, tr-Ch, tr-Lt (all: no trigger)
LOG_INTERVAL_MAX, LOG_CHANGE_MAX = 999, 255          # the meter's pages In (seconds) and Ch (counts 1..255), GitHub issue 40
LOG_DEFAULT = ('all', 1, 10)                         # mode, interval, change threshold


def reading_key(reading):
    """What must stay equal for readings to be comparable: mode, unit, range and clamp ratio (a change restarts the
    statistics and counts as a change for the log trigger)."""
    return (reading.get('mode'), reading.get('unit'), reading.get('range'), reading.get('clamp'))


class LogTrigger:
    """Which readings become CSV rows while recording (GitHub issue 40: the log did not follow the meter's trigger).

    The meter's rules (firmware USER_GUIDE "Logging trigger", log/trigger.s), applied to the readings the program gets;
    the live display, statistics and trend are not affected.  The first reading of a recording is always written.
      all       every reading (the program's way before the trigger)
      interval  a row every `interval` seconds; 0: every reading
      change    a row when the displayed digits (an integer, sign included) differ from those of the last row by at
                least `change` counts; tested once per second.  A change of mode, unit, range or clamp ratio, or between
                a number and OFL or blank, is a change.  With an interval above 0 also a row every interval
      limit     a row when the limit verdict (PASS / HI / LO / None) changes; with an interval above 0 also every
                interval while the verdict is not PASS (None, no limit set, counts: the meter does the same with its
                limit test off)
    The interval and the once-per-second test are clocks of their own, as the meter's counters: a row for another reason
    does not restart them.  They run on the reading times and step by whole intervals, so a late reading does not move
    the following rows.  With change and limit an interval of 0 means "the trigger only".
    """

    def __init__(self, mode='all', interval=1, change=10):
        self.configure(mode, interval, change)

    def configure(self, mode, interval, change):
        """Set the rule and forget the last row (a new recording starts)."""
        if mode not in LOG_MODES:
            raise ValueError('log trigger: one of %s' % ', '.join(LOG_MODES))
        for name, v, hi, lo in (('interval', interval, LOG_INTERVAL_MAX, 0), ('change', change, LOG_CHANGE_MAX, 1)):
            if isinstance(v, bool) or not isinstance(v, int) or not lo <= v <= hi:
                raise ValueError('log trigger %s: a whole number %d..%d' % (name, lo, hi))
        self.mode, self.interval, self.change = mode, interval, change
        self.reset()

    def reset(self):
        self._last = None                   # (key, kind, level) of the last row; None: no row yet
        self._next_tick = None              # reading time of the next interval row
        self._next_second = None            # reading time of the next change test
        self._verdict = None                # verdict of the previous reading

    @staticmethod
    def level(reading):
        """(kind, level): 'num' with the displayed digits as an integer, 'ofl' for an overload (its sign is not in the
        frame, so every overload is the same level), 'blank' for a reading without a value."""
        v = reading.get('value')
        if v is None:
            return ('ofl' if reading.get('overload') else 'blank'), 0
        return 'num', int(round(v * 10 ** (reading.get('dp') or 0)))

    @staticmethod
    def _due(t, nxt, step):
        """(due, next time): `nxt` has come at t; the next one is a whole step later, or a step after t after a gap."""
        if t < nxt:
            return False, nxt
        nxt += step
        return True, nxt if nxt > t else t + step

    def accept(self, reading, verdict=None):
        """True when the reading is written as a row.  `verdict`: the limit verdict of this reading (derived.py)."""
        if self.mode == 'all':
            return True
        t = reading['t']
        kind, lev = self.level(reading)
        cur = (reading_key(reading), kind, lev)
        if self._last is None:                          # the first reading of the recording
            take = True
            self._next_tick = t + self.interval if self.interval else None
            self._next_second = t + 1.0
        else:
            tick = False
            if self.interval:
                tick, self._next_tick = self._due(t, self._next_tick, self.interval)
            if self.mode == 'interval':
                take = tick or not self.interval
            elif self.mode == 'change':
                second, self._next_second = self._due(t, self._next_second, 1.0)
                take = tick or (second and self._changed(cur))
            else:
                take = verdict != self._verdict or (tick and verdict != 'PASS')
        self._verdict = verdict
        if take:
            self._last = cur
        return take

    def _changed(self, cur):
        key, kind, lev = self._last
        if (key, kind) != cur[:2]:
            return True
        return kind == 'num' and abs(cur[2] - lev) >= self.change


class Stats:
    def __init__(self):
        self.reset(None)

    def reset(self, key):
        self.key, self.n, self.min, self.max, self._mean, self._m2 = key, 0, None, None, 0.0, 0.0

    def add(self, key, v):
        if key != self.key:
            self.reset(key)
        self.n += 1
        self.min = v if self.min is None else min(self.min, v)
        self.max = v if self.max is None else max(self.max, v)
        d = v - self._mean                              # Welford: numerically stable mean and variance
        self._mean += d / self.n
        self._m2 += d * (v - self._mean)

    def snapshot(self):
        sd = math.sqrt(self._m2 / (self.n - 1)) if self.n > 1 else None
        return {'n': self.n, 'min': self.min, 'max': self.max, 'mean': self._mean if self.n else None, 'sd': sd}


class Session:
    def __init__(self):
        self.lock = threading.Lock()
        self.stats = Stats()
        self.trend = deque(maxlen=TREND_POINTS)        # (t, value, key)
        self.last = None
        self.stats_dp = None                            # decimals of the readings in the statistics
        self.frames = 0
        self._file = None
        self._writer = None
        self._dec = '.'
        self.rec_path = None
        self.rec_rows = 0
        self.rec_start = None
        self.trigger = LogTrigger()                     # which readings become rows (set by start_recording)

    def add(self, reading, verdict=None):
        """`verdict`: the limit verdict of the reading (derived.py), needed by the trigger 'limit' only."""
        with self.lock:
            self.frames += 1
            self.last = reading
            v = reading.get('value')
            key = reading_key(reading)                  # another clamp ratio restarts too
            if v is not None:
                self.stats.add(key, v)
                self.stats_dp = reading.get('dp')
                self.trend.append((reading['t'], v, key))
            else:
                self.trend.append((reading['t'], None, key))   # overload or blank: a gap in the trace
            if self._writer is not None and self.trigger.accept(reading, verdict):
                d = self._dec
                num = (lambda s: s.replace('.', d)) if d != '.' else (lambda s: s)
                self._writer.writerow([time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(reading['t']))
                                       + d + '%03d' % int((reading['t'] % 1) * 1000),
                                       reading.get('mode_name', ''), num(reading.get('text', '')), reading.get('unit', ''),
                                       '' if v is None else num(repr(v)), num(reading.get('sub_text', '')),
                                       reading.get('sub_unit', ''), ' '.join(reading.get('symbols', []))])
                self.rec_rows += 1
                if self.rec_rows % 50 == 0:
                    self._file.flush()

    def reset_stats(self):
        with self.lock:
            self.stats.reset(self.stats.key)

    def start_recording(self, folder, sep=',', dec='.', trigger=LOG_DEFAULT):
        """sep: the field separator, dec: the decimal mark of the numbers (',' / '.' or ';' / ',' for spreadsheets of
        countries that write a decimal comma), trigger: (mode, interval, change) of LogTrigger."""
        with self.lock:
            if self._writer is not None:
                return self.rec_path
            self.trigger.configure(*trigger)            # before the file exists: a bad rule starts nothing
            os.makedirs(folder, exist_ok=True)
            self.rec_path = os.path.join(folder, time.strftime('121GW_%Y-%m-%d_%H-%M-%S.csv'))
            self._file = open(self.rec_path, 'w', newline='', encoding='utf-8')
            self._writer = csv.writer(self._file, delimiter=sep)
            self._dec = dec
            self._writer.writerow(['time', 'mode', 'display', 'unit', 'value', 'sub display', 'sub unit', 'symbols'])
            self.rec_rows, self.rec_start = 0, time.time()
            return self.rec_path

    def stop_recording(self):
        with self.lock:
            if self._file is not None:
                self._file.close()
            path = self.rec_path
            self._file = self._writer = None
            return path

    def snapshot(self, since=None):
        """State for the page; `since`: only trend points newer than this time."""
        with self.lock:
            key = self.stats.key
            pts = [(t, v if k == key else None) for t, v, k in self.trend if since is None or t > since]
            unit = key[1] if key else None              # the unit of the readings in the statistics and the trend
            return {'last': self.last, 'frames': self.frames, 'stats': self.stats.snapshot(), 'stats_unit': unit,
                    'stats_key': '%s/%s/%s/%s' % key if key else None, 'stats_dp': self.stats_dp, 'trend': pts,
                    'recording': self._writer is not None, 'rec_path': self.rec_path, 'rec_rows': self.rec_rows,
                    'rec_start': self.rec_start}
