"""Induced emulator test of the DCV averaging of the production image (DESIGN.md 10 IMP-23, src/mdc/dcvavg.s).

    python -I emulator/scripts/test_dcv_fast.py [image] [--ref OTHER_IMAGE]      default firmware/build/EEVBlog.bin

Checks on DCV (dial V), each also run on --ref (for example the previous release) for comparison:
  T1 update rate: display changes per second on a slow ramp 1.0 -> 1.6 V over 6 s (HY3131 noise off).
  T2 steps 1 -> 3 V and 0 -> 9 V at 18 positions, one per sample, across a window (noise off): every value shown after the step
     is either the old or within 0.2 % of the new level (no straddled mean).
  T3 noise: standard deviation of the displayed counts over 8 s at a steady 4.5 V with the HY3131 noise model raised to 8
     counts per sample (the default model averages to nothing); the image under test must not exceed the reference by more
     than 10 % (the 16-sample window keeps v2.05's noise; an 8-sample window would show about 1.4 x).
  T4 range change: 1 V -> 40 V (range 0 -> 1): the first value in the new range and every later one are within 0.2 % of
     40 V, and the first comes no earlier than on the reference minus 5 ms (the settle time after a range change is v2.05's).
  T5 steep ramps (GitHub issue 3): 0.5 -> 4.5 V at 0.6 V/s and at 1.2 V/s (about 75 and 150 counts per 80 sps sample, below
     and above MDC_DCV_STEP = about 98 counts), the input set from the emulated time every 5 ms (noise off): the display
     never shows one value for longer than 0.3 s while the input moves, and every shown value is within 0.25 s of the slope
     of the input (LAG_S: the 16-sample window of 0.2 s at 80 sps plus one display refresh).  The first form of the step
     test held one value for seconds here.
  T6 a steep sine across a range change: 0 -> 40 V (cosine, 16 s period) for 7 s, the input set every 5 ms, so the
     change per sample alternates around MDC_DCV_STEP in the 50 V range (2 or 3 input steps per 12.5 ms sample): the main
     display is never without a value for longer than 0.6 s (the settle time after the range change).  Without the rule
     "no second restart before a mean was published" every few samples restarted the window, no mean was published, the
     settle count of the range change never ran out and the display stayed blank for 4.5 s.
The helpers are those of test_backlight_timer.py.
"""
import os
import statistics
import sys

sys.dont_write_bytecode = True                       # keep the tree free of __pycache__
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import test_backlight_timer as T  # noqa: E402
from app import Emulator  # noqa: E402


def meter(image, v, noise=False):
    Emulator.hy_noise, Emulator.hy_seed = noise, 1    # fixed seed: the same noise draws for both images
    e = T.make(image)
    e.command({'dial': 2})
    volts(e, v)
    e.advance(3.0)
    return e


def volts(e, v):
    e.command({'input': {'kind': 'V', 'value': v, 'ac': False}})


def shown(e):
    t = T.DEC.text(e.snapshot()['lcd'])[0].replace(' ', '')
    try:
        return float(t)
    except ValueError:
        return None


def trace(e, seconds, step=0.005):
    out, last = [], None
    for i in range(int(seconds / step)):
        e.advance(step)
        v = shown(e)
        if v != last:
            out.append(((i + 1) * step, v))
            last = v
    return out


def t1(image):
    e = meter(image, 1.0)
    changes = 0
    last = shown(e)
    for i in range(1200):                            # 6 s in 5 ms steps, 0.1 V per second
        volts(e, 1.0 + 0.1 * (i + 1) * 0.005)
        e.advance(0.005)
        v = shown(e)
        if v != last:
            changes += 1
            last = v
    return changes / 6.0


def t2(image):
    bad = []
    for a, b in ((1.0, 3.0), (0.0, 9.0)):
        for k in range(18):
            e = meter(image, a)
            e.advance(0.0025 * k)                    # every sample position of a window (the emulator's DCV rows give
                                                     # about 400 samples per second: 2.5 ms per sample)
            volts(e, b)
            for t, v in trace(e, 1.5):
                if v is None:
                    continue
                if not (abs(v - a) <= max(0.002 * abs(a), 0.0005) or abs(v - b) <= 0.002 * abs(b)):
                    bad.append((a, b, k, round(t, 3), v))
    return bad


def t3(image):
    e = meter(image, 4.5, noise=True)
    e.frontend.noise_counts = 8.0                    # 8 counts per sample: a 16-sample window shows about 2, an 8-sample one 2.8
    vals = []
    for i in range(800):
        e.advance(0.01)
        v = shown(e)
        if v is not None:
            vals.append(v)
    return statistics.pstdev(vals) * 10000             # in counts (range 0: 4 decimals)


def t4(image):
    """(time of the first value in the new range, that value, every later value not within 0.2 % of 40 V)"""
    e = meter(image, 1.0)
    volts(e, 40.0)
    first, off = None, []
    for t, v in trace(e, 3.0, 0.002):
        if v is None or v <= 9.9999:
            continue
        if first is None:
            first = (t, v)
        elif abs(v - 40.0) > 0.08:
            off.append((round(t, 3), v))
    return (first or (None, None)) + (off,)


LAG_S = 0.25          # T5 tolerance in seconds of the slope: the 16-sample window (0.2 s at 80 sps) plus one display refresh


def t5(image, rate):
    """(longest time one value is shown, largest distance of a shown value from the input) on a ramp of `rate` V/s."""
    e = meter(image, 0.5)
    t0 = T.now(e)
    last, since, hold, dist = shown(e), t0, 0.0, 0.0
    while True:
        t = T.now(e)
        u = 0.5 + rate * (t - t0)
        if u >= 4.5:
            break
        volts(e, u)
        e.advance(0.005)
        v = shown(e)
        if v != last:
            last, since = v, T.now(e)
        hold = max(hold, T.now(e) - since)
        if v is not None and T.now(e) - t0 > 0.5:
            dist = max(dist, abs(v - u))
    return hold, dist


def t6(image):
    """Longest time without a numeric value on the main display during a 0 -> 40 V cosine across the range change."""
    import math
    e = meter(image, 0.0)
    t0 = T.now(e)
    blank_since, longest = None, 0.0
    while T.now(e) - t0 < 7.0:
        t = T.now(e) - t0
        volts(e, 20.0 * (1 - math.cos(2 * math.pi * t / 16.0)))
        e.advance(0.005)
        if shown(e) is None:
            blank_since = T.now(e) if blank_since is None else blank_since
            longest = max(longest, T.now(e) - blank_since)
        else:
            blank_since = None
    return longest


def main(argv):
    ref = None
    if '--ref' in argv:
        i = argv.index('--ref')
        ref = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    image = argv[0] if argv else os.path.join(T.ROOT, 'firmware', 'build', 'EEVBlog.bin')
    imgs = [('test', image)] + ([('ref', ref)] if ref else [])
    res = {name: {} for name, _ in imgs}
    for name, img in imgs:
        res[name]['rate'] = t1(img)
        res[name]['bad'] = t2(img)
        res[name]['noise'] = t3(img)
        res[name]['range'] = t4(img)
        res[name]['ramp'] = [t5(img, 0.6), t5(img, 1.2)]
        res[name]['blank'] = t6(img)
        print('%-4s rate %.1f/s, straddled values %d %s, noise %.2f counts, range change first value %r'
              % (name, res[name]['rate'], len(res[name]['bad']), res[name]['bad'][:3], res[name]['noise'], res[name]['range']),
              flush=True)
        print('     ramps: 0.6 V/s longest hold %.2f s, largest distance %.3f V; 1.2 V/s %.2f s, %.3f V'
              % (res[name]['ramp'][0] + res[name]['ramp'][1]), flush=True)
        print('     0 -> 40 V across the range change: longest blank %.2f s' % res[name]['blank'], flush=True)
    r = res['test']
    T.check('T6 0 -> 40 V across the range change: never blank longer than 0.6 s', r['blank'] <= 0.6,
            '%.2f s' % r['blank'])
    for rate, (hold, dist) in zip((0.6, 1.2), r['ramp']):
        T.check('T5 ramp %.1f V/s: no value shown longer than 0.3 s' % rate, hold <= 0.3, '%.2f s' % hold)
        T.check('T5 ramp %.1f V/s: every value within %.2f V of the input' % (rate, LAG_S * rate), dist <= LAG_S * rate,
                '%.3f V' % dist)
    T.check('T2 no straddled value after a step', not r['bad'], repr(r['bad'][:4]))
    t, v, off = r['range']
    T.check('T4 first value after the range change within 0.2 %% of 40 V', v is not None and abs(v - 40.0) <= 0.08, 'value %r' % v)
    T.check('T4 every later value within 0.2 %% of 40 V', not off, repr(off[:4]))
    if ref:
        T.check('T1 update rate at least 1.8 x the reference', r['rate'] >= 1.8 * res['ref']['rate'],
                '%.1f against %.1f' % (r['rate'], res['ref']['rate']))
        T.check('T3 noise not above the reference + 10 %%', r['noise'] <= 1.10 * res['ref']['noise'] + 0.05,
                '%.2f against %.2f counts' % (r['noise'], res['ref']['noise']))
        rt = res['ref']['range'][0]
        T.check('T4 the first value after the range change not earlier than the reference - 5 ms',
                t is not None and rt is not None and t >= rt - 0.005, 'at %r s against %r s' % (t, rt))
    print('RESULT', ('FAIL: ' + ', '.join(T.fails)) if T.fails else 'ALL PASS', flush=True)
    return 1 if T.fails else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
