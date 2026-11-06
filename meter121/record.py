"""Readings of a session: statistics, trend history and the CSV recording.

A reading is the dictionary display.decode() makes of a status frame.  Only readings with a numeric value (not overload,
not blank) enter the statistics and the trend; every reading goes into the CSV file while recording, an overload as
"OL".  The statistics restart when the mode, the unit or the range changes, because values of different scales cannot
be combined.
"""
import csv
import math
import os
import threading
import time
from collections import deque

TREND_POINTS = 6000                      # about 10 minutes at the meter's 10 frames per second


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

    def add(self, reading):
        with self.lock:
            self.frames += 1
            self.last = reading
            v = reading.get('value')
            key = (reading.get('mode'), reading.get('unit'), reading.get('range'))
            if v is not None:
                self.stats.add(key, v)
                self.stats_dp = reading.get('dp')
                self.trend.append((reading['t'], v, key))
            else:
                self.trend.append((reading['t'], None, key))   # overload or blank: a gap in the trace
            if self._writer is not None:
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

    def start_recording(self, folder, sep=',', dec='.'):
        """sep: the field separator, dec: the decimal mark of the numbers (',' / '.' or ';' / ',' for spreadsheets of
        countries that write a decimal comma)."""
        with self.lock:
            if self._writer is not None:
                return self.rec_path
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
                    'stats_key': '%s/%s/%s' % key if key else None, 'stats_dp': self.stats_dp, 'trend': pts,
                    'recording': self._writer is not None, 'rec_path': self.rec_path, 'rec_rows': self.rec_rows,
                    'rec_start': self.rec_start}
