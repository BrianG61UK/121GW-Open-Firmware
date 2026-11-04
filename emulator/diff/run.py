"""Differential test of a candidate firmware image against the original v2.05 image in the emulator.

    python -I emulator/diff/run.py --ref EEVBlog2_05.bin --cand <image> --eeprom <file> [--scenario name|all]
                                   [--build baseline|production] [--report out.md]
    python -I emulator/diff/run.py --self-test --ref EEVBlog2_05.bin --eeprom <file>
    python -I emulator/diff/run.py --mutation-check --ref EEVBlog2_05.bin --eeprom <file>
    python -I emulator/diff/run.py --make-whitelist --ref EEVBlog2_05.bin --eeprom <file>
    python -I emulator/diff/run.py --safety-check --ref EEVBlog2_05.bin --eeprom <file>

Every scenario is run once per image, each run in its own process with a private copy of the EEPROM image, a freshly
formatted SD card image (scenarios with flag sd), the same noise seed and the same clock-chip calendar; the recorded
streams are compared (compare.py) and the first divergence of each scenario is reported.  Emulation is not paced:
runs go as fast as the emulator executes.  Before the runs the emulated length of each scenario, its usual wall time (1 to 4 s per emulated s
and image) and its wall-clock limit are printed; a run still going after its limit (300 s + 20 x the emulated length,
--timeout-scale X >= 1 multiplies it, it cannot be switched off) is terminated by the parent process and reported as a
run timeout naming the scenario and the image, so a hang ends the run with a failure instead of blocking it.

--self-test     runs the reference image against itself: every scenario must give zero divergences (determinism) and
                every assertion must pass on the reference image.
--mutation-check  copies the reference image, changes the immediate of `movs r4, #0xCD` at 0x0801A856 (FUN_0801A854,
                which draws the power-on version splash "V-2.05" from the number 0xCD = 205; analysis/keys_setup.md
                section 3) to 0xCE, and shows that the comparison detects the changed splash.
--make-whitelist  runs every scenario (long ones included) on the reference image with the hardware-safety monitor
                (emu/safety.py) in learning mode and writes emulator/diff/hy3131_whitelist.
--safety-check  runs boot_v on the reference image (no violation allowed) and on one-change copies of it
                (SAFETY_MUTATIONS), each of which must trip its hardware-safety check.
--build         the build mode of the candidate (baseline = the like-v2.05 build of the branch like-v2.05, LOOP_V205=1; production = the fast build of main; firmware/DESIGN.md 3.5):
                allowlist entries tagged "build == ..." (emu/allowlist.py) are used only for the same build; without
                the option they are not used, so a candidate is compared as strictly as possible.
Hardware safety: every run is watched by emu/safety.py (attached by app.Emulator.build); a violation stops that run
and fails the comparison, and the power stream (supply / enable outputs) is compared with the reference run.
Image arguments that are not an existing path are looked up in --inputs (default inputs/binaries of the project).
Exit status: 0 when nothing diverged and every assertion passed, 1 otherwise, 2 on usage errors.
"""
import argparse
import hashlib
import multiprocessing
import os
import shutil
import sys
import tempfile
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
EMU = os.path.normpath(os.path.join(HERE, '..'))
ROOT = os.path.normpath(os.path.join(EMU, '..'))
if EMU not in sys.path:
    sys.path.insert(0, EMU)

from diff import scenario as scen          # noqa: E402
from diff import compare as cmpm           # noqa: E402
from emu import allowlist                  # noqa: E402

# OF-53 (firmware/ORIGINAL_FIRMWARE_ISSUES.md, owner decision): after an event service the port writes to INTF (register
# 0x1E, one-byte frame as v2.05 0x0800616C) a 0 for every flag it has read as set and a 1 for the others, where v2.05 writes
# 0x00 and so also clears a flag raised after its read.  INTF is a flag register, not a configuration register: a written 0
# clears a flag, a written 1 has no effect ("INTF register can be written as 0 by SPI Interface, but not 1", HY3131 data
# sheet p19 10.2 (7)); bits 6:5 carry no flag ("-", data sheet p19) and are written 0 as in v2.05's value.  These pairs are
# added to the whitelist (make_whitelist); the frame shape (0x1E, 1) and the configuration states are unchanged.
INTF_ACK_PAIRS = {(0x1E, v) for v in range(256) if not v & 0x60}

MUTATION_ADDR = 0x0801A856                 # movs r4, #0xCD in FUN_0801A854 (version splash)
MUTATION_ORIG = bytes([0xCD, 0x24])        # Thumb encoding of movs r4, #0xCD
APP_BASE = 0x08006000


def sha256(path):
    return hashlib.sha256(open(path, 'rb').read()).hexdigest()


WALL_BASE_S, WALL_PER_EMULATED_S = 300.0, 20.0   # wall-clock limit of one run: 300 s + 20 x the emulated length


def wall_limit(sc, scale=1.0):
    """Wall-clock limit (s) of one run of scenario sc.  Normal runs take 1 to 4 wall seconds per emulated second (the
    reports' wall column); the limit leaves a factor of 5 or more and 300 s for the start-up, so only a run that has
    stopped making progress (a firmware or emulator hang) reaches it.  scale: --timeout-scale."""
    return scale * (WALL_BASE_S + WALL_PER_EMULATED_S * sc.emulated_s())


def _worker(job):
    """Run one scenario on one image in this process.  job: dict (picklable).  The wall-clock limit job['wall_limit'] is
    enforced from outside by run_jobs (an exception raised inside the emulator's callbacks would be swallowed by them)."""
    learner = None
    name = os.path.splitext(os.path.basename(job['scenario_path']))[0]
    try:
        from emu import safety
        if job.get('learn'):
            learner = safety.Safety.LEARN = safety.Learner()
        if job.get('deviations'):
            safety.Safety.deviations_path = job['deviations']
        sc = scen.load(job['scenario_path'])
        r = scen.Runner(sc, job['image'], job['inputs'], job['eeprom'], seed=job['seed'], gpio_all=job['gpio_all'],
                        workdir=job['workdir'], keep=job['keep'], noise=job.get('noise', True)).run()
    except Exception:
        return {'scenario': name, 'image': job['image'], 'role': job['role'], 'error': traceback.format_exc()}
    r['role'] = job['role']
    if learner is not None:
        r['learned'] = learner
    if job.get('trace_dir'):
        write_trace(r, os.path.join(job['trace_dir'], f'{r["scenario"]}.{job["role"]}.trace.txt'))
        r['trace_file'] = os.path.join(job['trace_dir'], f'{r["scenario"]}.{job["role"]}.trace.txt')
    return r


def _child(job, q):
    q.put(_worker(job))


def run_jobs(jobs, n):
    """Run the jobs on at most n processes (one fresh process per job, as the pool with maxtasksperchild=1 did) and yield
    each result when it arrives.  A run still going after its job['wall_limit'] wall-clock seconds is terminated and
    yields an error result with 'timeout': True that names the scenario, the image and the limit; a process that ends
    without a result yields an error with its exit code.  The limit cannot be missed: it is checked here, outside the
    emulator, every 0.2 s."""
    import queue
    ctx = multiprocessing.get_context('spawn')
    pending, running = list(jobs), {}
    while pending or running:
        while pending and len(running) < n:
            job = pending.pop(0)
            q = ctx.Queue()
            p = ctx.Process(target=_child, args=(job, q), daemon=True)
            p.start()
            running[p] = (job, q, time.time())
        time.sleep(0.2)
        for p, (job, q, t0) in list(running.items()):
            name = os.path.splitext(os.path.basename(job['scenario_path']))[0]
            try:
                r = q.get(timeout=1.0) if not p.is_alive() else q.get_nowait()
            except queue.Empty:
                r = None
            if r is not None:
                p.join()
                del running[p]
                yield r
            elif not p.is_alive():
                del running[p]
                yield {'scenario': name, 'image': job['image'], 'role': job['role'],
                       'error': f'the process of scenario {name} on {os.path.basename(job["image"])} ended without a '
                                f'result (exit code {p.exitcode})'}
            elif time.time() - t0 > job['wall_limit']:
                p.terminate()
                p.join()
                del running[p]
                yield {'scenario': name, 'image': job['image'], 'role': job['role'], 'timeout': True,
                       'error': f'run timeout: scenario {name} on {os.path.basename(job["image"])} did not finish within '
                                f'{job["wall_limit"]:.0f} s wall clock (limit {WALL_BASE_S:.0f} s + '
                                f'{WALL_PER_EMULATED_S:.0f} x the emulated length): the run was stopped'}


def write_trace(r, path):
    with open(path, 'w') as f:
        f.write(f'# scenario {r["scenario"]} image {r["image"]}\n')
        for ev in r['events']:
            f.write(cmpm.fmt_event(ev) + '\n')


def resolve_image(arg, inputs):
    if arg is None:
        return None
    if os.path.exists(arg):
        return os.path.abspath(arg)
    p = os.path.join(inputs, arg)
    if os.path.exists(p):
        return os.path.abspath(p)
    raise SystemExit(f'image {arg} not found (also looked in {inputs})')


def select(names, lib, include_long):
    if names == 'all':
        return [s for s in lib.values() if include_long or 'long' not in s.flags]
    out = []
    for n in names.split(','):
        if n not in lib:
            raise SystemExit(f'unknown scenario {n}; known: {", ".join(lib)}')
        out.append(lib[n])
    return out


def run_pairs(scenarios, ref, cand, args, workdir):
    jobs = []
    for sc in scenarios:
        for role, img in (('ref', ref), ('cand', cand)):
            jobs.append({'scenario_path': sc.path, 'image': img, 'inputs': args.inputs, 'eeprom': args.eeprom,
                         'seed': args.seed, 'gpio_all': args.gpio_all, 'workdir': workdir, 'keep': args.keep,
                         'role': role, 'trace_dir': args.trace_dir, 'deviations': args.deviations,
                         'noise': not args.no_noise, 'wall_limit': wall_limit(sc, args.timeout_scale)})
    # longest scenarios first so that the pool is not left waiting on one long run at the end
    order = {sc.path: (('long' not in sc.flags), sc.name) for sc in scenarios}
    jobs.sort(key=lambda j: order[j['scenario_path']])
    results = {}
    ctx = multiprocessing.get_context('spawn')
    n = max(1, min(args.jobs, len(jobs)))
    # what to expect: the emulated length of each scenario, the usual wall time (1 to 4 s per emulated s, per image) and the
    # hard limit after which a run is stopped as a timeout
    total = 0.0
    for sc in scenarios:
        em = sc.emulated_s()
        total += 2 * em
        print(f'  {sc.name:32s} {em:8.1f} s emulated{" (long)" if "long" in sc.flags else ""}: usually '
              f'{em / 60:.1f}..{4 * em / 60:.1f} min wall per image, limit {wall_limit(sc, args.timeout_scale) / 60:.0f} min',
              flush=True)
    print(f'  {len(jobs)} runs on {n} processes: usually {total / n / 60:.1f}..{4 * total / n / 60:.1f} min in all', flush=True)
    for r in run_jobs(jobs, n):
        results[(r['scenario'], r['role'])] = r
        status = (('TIMEOUT ' + r['error']) if r.get('timeout') else 'ERROR') if r.get('error') else \
            f'{r["end_ns"] / 1e9:.1f} s emulated in {r["wall_s"]:.1f} s'
        print(f'  {r["scenario"]:32s} {r["role"]:4s} {status}', flush=True)
    return results


def assertion_failures(r):
    return [ev for ev in r.get('events', ()) if ev[1] == 'assert' and not ev[2][1]]


def make_report(scenarios, results, comparisons, args, ref, cand, devs, title):
    L = [f'# {title}', '']
    L.append(f'- reference image: `{os.path.basename(ref)}` sha256 `{sha256(ref)}`')
    L.append(f'- candidate image: `{os.path.basename(cand)}` sha256 `{sha256(cand)}`')
    L.append(f'- EEPROM image: `{os.path.basename(args.eeprom)}` sha256 `{sha256(args.eeprom)}` (each run used a private copy)')
    L.append(f'- noise {"off" if args.no_noise else f"on, seed {args.seed}"}; front end: calibrated; compared streams: {", ".join(cmpm.COMPARED)} and the final state')
    tol = ', '.join(f'{s} {t}' for s, t in sorted(args.tol.items())) or 'defaults (compare.py)'
    L.append(f'- time tolerances: {tol}')
    L.append(f'- deviation allowlist: {args.deviations or "none"} ({len(devs)} entries; candidate build: {args.build or "not given, build-tagged entries not used"})')
    L.append('')
    L.append('| scenario | flags | emulated s | wall s ref / cand | result | first divergence | assertions failed ref / cand (allowlist not applied) |')
    L.append('|---|---|---|---|---|---|---|')
    total_div = 0
    for sc in scenarios:
        ra, rb = results.get((sc.name, 'ref')), results.get((sc.name, 'cand'))
        flags = ','.join(sorted(sc.flags)) or '-'
        if ra.get('error') or rb.get('error'):
            L.append(f'| {sc.name} | {flags} | - | - | **run {"timeout" if ra.get("timeout") or rb.get("timeout") else "error"}** | - | - |')
            total_div += 1
            continue
        c = comparisons[sc.name]
        nd = len(c['per_stream']) + len(c['final'])
        total_div += nd
        first = '-'
        if c['first']:
            first = f'{c["first"]["stream"]} {c["first"]["kind"]} at {c["first"]["t"] / 1e9:.4f} s'
        elif c['final']:
            first = f'final {c["final"][0][0]} {c["final"][0][1]}'
        res = 'identical' if nd == 0 else f'**{nd} diverging**'
        L.append(f'| {sc.name} | {flags} | {ra["end_ns"] / 1e9:.2f} | {ra["wall_s"]:.1f} / {rb["wall_s"]:.1f} | {res} | '
                 f'{first} | {len(assertion_failures(ra))} / {len(assertion_failures(rb))} |')
    L.append('')
    for sc in scenarios:
        ra, rb = results[(sc.name, 'ref')], results[(sc.name, 'cand')]
        if ra.get('error') or rb.get('error'):
            L.append(f'## {sc.name}: run error')
            for r in (ra, rb):
                if r.get('error'):
                    L += ['```', r['error'].rstrip(), '```']
            continue
        c = comparisons[sc.name]
        if not c['per_stream'] and not c['final']:
            continue
        L.append(f'## {sc.name}')
        L.append('')
        L += cmpm.describe(c, ra, rb)
        L.append('')
        if len(c['per_stream']) > 1:
            L.append('First divergence of the other streams:')
            for s, d in sorted(c['per_stream'].items(), key=lambda kv: kv[1]['t']):
                if d is c['first']:
                    continue
                L.append(f'- `{s}` #{d["index"]} {d["kind"]} at {cmpm.fmt_t(d["t"])}: ref {cmpm.fmt_event(d["ref"])} / '
                         f'cand {cmpm.fmt_event(d["cand"])}')
            L.append('')
        if c['final']:
            L.append('Final state differences (first 40):')
            for kind, where, x, y in c['final'][:40]:
                if kind == 'lcd_final':
                    L.append(f'- lcd_final: ref {cmpm.fmt_event((0, "lcd", x, None))} / cand {cmpm.fmt_event((0, "lcd", y, None))}')
                else:
                    L.append(f'- {kind} {where}: ref {x} / cand {y}')
            L.append('')
    L.append('## Hardware safety')
    L.append('')
    L.append('Checks of emu/safety.py (HY3131 writes against the v2.05 whitelist, pin contention, power sequencing) in '
             'every run, and the power stream (PE9, PF15, PD1, PF6, PE12) compared with the reference run.')
    L.append('')
    nsafe = 0
    for sc in scenarios:
        for role in ('ref', 'cand'):
            r = results[(sc.name, role)]
            for v in (r.get('final') or {}).get('safety', ()):
                nsafe += 1
                L.append(f'- {sc.name} ({role}): {v}')
        c = comparisons.get(sc.name)
        if c and 'power' in c['per_stream']:
            d = c['per_stream']['power']
            nsafe += 1
            L.append(f'- {sc.name}: power sequencing differs from the reference: #{d["index"]} {d["kind"]} at '
                     f'{cmpm.fmt_t(d["t"])}: ref {cmpm.fmt_event(d["ref"])} / cand {cmpm.fmt_event(d["cand"])}')
    if not nsafe:
        L.append('No hardware-safety violation and no power-sequencing difference in any run.')
    L.append('')
    def allowed(name, ev):          # an assertion failure covered by an 'assert' entry of the allowlist
        return any(d.stream == 'assert' and d.applies(name) and d.match(cmpm.fields('assert', ev[2], ev[0]))
                   for d in devs)
    fails = [(sc.name, role, ev) for sc in scenarios for role in ('ref', 'cand')
             for ev in assertion_failures(results[(sc.name, role)]) if not allowed(sc.name, ev)]
    L.append('## Assertions')
    L.append('')
    if not fails:
        L.append('Every assertion passed on both images.')
    for name, role, ev in fails:
        L.append(f'- {name} ({role}) line {ev[2][0]} `{ev[2][2]}` failed at {cmpm.fmt_t(ev[0])}: {ev[3]["detail"]}')
    L.append('')
    if devs:
        L.append('## Deviation allowlist use')
        L.append('')
        for d in devs:
            L.append(f'- line {d.lineno} `{d.text}`: {d.removed} events removed')
        L.append('')
    um = {}
    for (name, role), r in results.items():
        for k, v in (r.get('final') or {}).get('unmodelled', {}).items():
            um.setdefault(k, (v[0], set()))[1].add(f'{name}/{role}')
    L.append('## Emulator information')
    L.append('')
    L.append(f'Unmodelled register accesses seen: {len(um)}')
    for k, (pc, where) in sorted(um.items()):
        L.append(f'- {k} first pc {pc} ({", ".join(sorted(where)[:4])}{" ..." if len(where) > 4 else ""})')
    L.append('')
    L.append('## Scenario sources')
    L.append('')
    for sc in scenarios:
        L.append(f'- {sc.name}: ' + '; '.join(sc.sources))
    return '\n'.join(L) + '\n', total_div + nsafe, len(fails)


def do_compare(scenarios, ref, cand, args, title):
    devs = cmpm.load_allowlist(args.deviations, args.build) if args.deviations else []
    ee_hash = sha256(args.eeprom)
    workdir = tempfile.mkdtemp(prefix='eev-diff-', dir=args.workdir)
    t0 = time.time()
    try:
        results = run_pairs(scenarios, ref, cand, args, workdir)
    finally:
        if not args.keep:
            shutil.rmtree(workdir, ignore_errors=True)
    if sha256(args.eeprom) != ee_hash:
        raise SystemExit(f'the EEPROM image {args.eeprom} changed during the runs')
    comparisons = {}
    for sc in scenarios:
        ra, rb = results[(sc.name, 'ref')], results[(sc.name, 'cand')]
        if not ra.get('error') and not rb.get('error'):
            comparisons[sc.name] = cmpm.compare(ra, rb, devs, args.tol)
    report, ndiv, nfail = make_report(scenarios, results, comparisons, args, ref, cand, devs, title)
    print(f'{len(scenarios)} scenarios, {ndiv} diverging items, {nfail} failed assertions, '
          f'{time.time() - t0:.1f} s wall', flush=True)
    return report, ndiv, nfail, results, comparisons


def mutation_check(args, ref, lib):
    data = bytearray(open(ref, 'rb').read())
    off = MUTATION_ADDR - APP_BASE
    if bytes(data[off:off + 2]) != MUTATION_ORIG:
        raise SystemExit(f'reference image has {data[off:off + 2].hex()} at 0x{MUTATION_ADDR:08X}, '
                         f'expected {MUTATION_ORIG.hex()} (movs r4, #0xCD); not the v2.05 image')
    data[off] = 0xCE
    tmp = tempfile.mkdtemp(prefix='eev-mut-', dir=args.workdir)
    mut = os.path.join(tmp, 'mutant_V206.bin')
    open(mut, 'wb').write(data)
    names = args.scenario if args.scenario != 'all' else 'boot_v'
    scenarios = select(names, lib, args.long)
    try:
        report, ndiv, nfail, results, comps = do_compare(
            scenarios, ref, mut, args, f'Mutation check: byte 0x{MUTATION_ADDR:08X} 0xCD -> 0xCE (splash V-2.05 -> V-2.06)')
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    detected = all(comps.get(sc.name) and (comps[sc.name]['first'] or comps[sc.name]['final']) for sc in scenarios)
    print('mutation ' + ('DETECTED in every scenario run' if detected else 'NOT detected in every scenario'), flush=True)
    return report, 0 if detected else 1


def make_whitelist(args, ref, lib):
    """Run every scenario (including the long ones) on the reference image with emu/safety.py in learning mode and
    write the union of what it did to emulator/diff/hy3131_whitelist."""
    from emu import safety
    if args.scenario != 'all' and not args.merge:
        raise SystemExit('--make-whitelist without --merge runs every scenario (a subset would drop entries)')
    scenarios = list(lib.values()) if args.scenario == 'all' else select(args.scenario, lib, True)
    workdir = tempfile.mkdtemp(prefix='eev-wl-', dir=args.workdir)
    jobs = [{'scenario_path': sc.path, 'image': ref, 'inputs': args.inputs, 'eeprom': args.eeprom, 'seed': args.seed,
             'gpio_all': False, 'workdir': workdir, 'keep': False, 'role': 'ref', 'trace_dir': None, 'learn': True,
             'wall_limit': wall_limit(sc, args.timeout_scale)}
            for sc in sorted(scenarios, key=lambda sc: ('long' not in sc.flags, sc.name))]
    total = safety.Learner()
    merged_from = None
    if args.merge:                               # add these runs to the whitelist in the tree
        old = safety.Whitelist(safety.WHITELIST)
        total.pairs, total.frames, total.states = set(old.pairs), set(old.frames), set(old.states)
        total.power = {k: set(old.power_pcs.get(k, ())) for k in old.power}
        merged_from = [ln[2:].rstrip('\n') for ln in open(safety.WHITELIST) if ln.startswith('# ')]
    errors, stops = [], []
    t0 = time.time()
    try:
        for r in run_jobs(jobs, max(1, min(args.jobs, len(jobs)))):
            if r.get('error'):
                errors.append((r['scenario'], r['error']))
                print(f'  {r["scenario"]:32s} ERROR', flush=True)
                continue
            total.merge(r['learned'])
            stops += [(r['scenario'], v) for v in r['final']['safety']]
            fails = ', '.join(f'line {ev[2][0]}' for ev in assertion_failures(r))
            print(f'  {r["scenario"]:32s} {r["end_ns"] / 1e9:.1f} s emulated in {r["wall_s"]:.1f} s'
                  + (f'; assertions failed: {fails}' if fails else ''), flush=True)
    finally:
        shutil.rmtree(workdir, ignore_errors=True)
    if errors or stops:
        for name, e in errors:
            print(f'{name}: {e}')
        for name, v in stops:
            print(f'{name}: {v}')
        raise SystemExit('whitelist not written: runs failed or stopped (see above)')
    from diff import hy3131_rows
    pairs, shapes, states = hy3131_rows.write_sets(ref)
    n_dyn = (len(total.pairs), len(total.frames), len(total.states))
    static_only = (len(pairs - total.pairs), len(shapes - total.frames), len(states - total.states))
    dyn_only = (len(total.pairs - pairs), len(total.frames - shapes), len(total.states - states))
    total.pairs |= pairs
    total.frames |= shapes
    total.states |= states
    total.pairs |= INTF_ACK_PAIRS                # the port's IRQ acknowledge values (OF-53, see INTF_ACK_PAIRS)
    header = ['Whitelist of the hardware-safety monitor (emu/safety.py): HY3131 writes and supply/enable output steps of',
              f'the original firmware (image sha256 {sha256(ref)}).',
              'Sources, united:',
              '  1. execution of the v2.05 configuration code under Unicorn for every mode, range and RAM flag it reads',
              '     (emulator/diff/hy3131_rows.py, exhaustive by construction; with the IRQ and peak-routine writes);',
              f'  2. {len(scenarios)} scenarios of emulator/diff/scenarios (all, long ones included) run on the image with',
              f'     EEPROM image sha256 {sha256(args.eeprom)}, noise seed {args.seed}; the power steps come only from here, each',
              '     with the program counters at which v2.05 made it.',
              f'Scenario runs alone: {n_dyn[0]} pairs, {n_dyn[1]} frame shapes, {n_dyn[2]} states; present only in the static sweep:',
              f'{static_only[0]} / {static_only[1]} / {static_only[2]}; present only in the scenario runs: {dyn_only[0]} / {dyn_only[1]} / '
              f'{dyn_only[2]}.',
              'Regenerate (after changing scenarios or the emulator):',
              '  python -I emulator/diff/run.py --make-whitelist --ref EEVBlog2_05.bin --eeprom <calibration EEPROM image>',
              'Lines: write <reg> <value> | frame <start reg> <byte count> | state <registers 0x20..0x33, -- = not written>',
              '       | power <changed pins> <old levels> <new levels> <PE9/PD1 before>   (levels 0, 1, Z = not driven)',
              'Added to the v2.05 set (emulator/diff/run.py INTF_ACK_PAIRS): the IRQ acknowledge values "write 1E v" with bits',
              '6:5 of v clear (OF-53, firmware/ORIGINAL_FIRMWARE_ISSUES.md: the port writes 0 only for the INTF flags it read as',
              'set).  INTF is a flag register, not configuration: a written 0 clears a flag, a written 1 has no effect (HY3131',
              'data sheet p19 10.2 (7)); bits 6:5 carry no flag and stay 0 as in the v2.05 write of 0x00 (0x0800616C).', '']
    if merged_from is not None:
        header = merged_from + [f'Merged on top of the lines above: runs of {", ".join(sc.name for sc in scenarios)} '
                                f'(emulator/diff/run.py --make-whitelist --merge --scenario ...).', '']
    with open(safety.WHITELIST, 'w') as f:
        f.write(total.text(header))
    print(f'{safety.WHITELIST}: {len(total.pairs)} write pairs, {len(total.frames)} frame shapes, {len(total.states)} '
          f'states, {len(total.power)} power steps ({time.time() - t0:.0f} s); scenario runs alone {n_dyn}, static only '
          f'{static_only}, scenario only {dyn_only}')
    return 0


# One-instruction or one-byte changes of a copy of v2.05, each of which must trip one hardware-safety check
# (emu/safety.py) in the boot_v scenario: (name, address, original bytes, new bytes, expected violation kind, meaning)
SAFETY_MUTATIONS = (
    ('hy3131_value', 0x080288AA, '22', '23', 'HY3131 write',
     'DCV range 0 configuration row (table at 0x080288A0, hy3131_model.md section 3): R2A 0x22 -> 0x23, a switch '
     'setting v2.05 never writes'),
    ('hy3131_state', 0x080288AC, '0090', '9000', 'HY3131 configuration',
     'same row, R2C/R2D swapped: each byte is a value v2.05 writes to that register, the combination is not'),
    ('hy3131_order', 0x0800BE8E, '1422', '1322', 'HY3131 write order',
     'hy3131_load_config_regs: movs r2, #0x14 -> #0x13 before the SPI write at 0x0800BE94: the 20-byte row goes '
     'out as a 19-byte frame'),
    ('pin_contention', 0x0801C372, '0020', '0120', 'pin contention',
     'gpio_init_pe10_pe11_inputs: GPIO mode byte 0 (input) -> 1 (output): PE10/PE11 drive against the U5 '
     'comparator outputs FUSE_mA / FUSE_A'),
    ('power_sequence', 0x0801C08E, '0220', '0020', 'power sequencing',
     'board GPIO set-up: movs r0, #2 -> #0 before the GPIOD BSRRL store at 0x0801C094: PD1 (PWR_CTL2, +4.0 V '
     'regulator control) is not switched on'),
)


def safety_check(args, ref, lib):
    """Run boot_v on v2.05 and on one mutant per SAFETY_MUTATIONS entry: v2.05 must not trip any check, every mutant
    must trip the expected one."""
    from emu import safety
    if not os.path.exists(safety.WHITELIST):
        raise SystemExit(f'{safety.WHITELIST} missing: run --make-whitelist first')
    data = open(ref, 'rb').read()
    tmp = tempfile.mkdtemp(prefix='eev-safety-', dir=args.workdir)
    allow = os.path.join(tmp, 'deviations.txt')
    with open(allow, 'w') as f:                  # approves exactly the step the power_sequence mutant makes
        f.write('HW-99 safety_power * pins == PF15 and old == Z and new == 0 and ctx == PE9=1,PD1=0\n')
    p = next(m for m in SAFETY_MUTATIONS if m[0] == 'power_sequence')
    cases = (('unmodified', None, '', '', None, 'v2.05 as supplied'),) + SAFETY_MUTATIONS + \
        (('power_sequence_allowed', p[1], p[2], p[3], 'ALLOWED',
          p[5] + '; with an allowlist entry (HW-99, scenario *) approving that step: the run must not stop'),)
    jobs = []
    try:
        for name, addr, orig, new, kind, why in cases:
            img = ref
            if addr is not None:
                off = addr - APP_BASE
                o, n = bytes.fromhex(orig), bytes.fromhex(new)
                if data[off:off + len(o)] != o:
                    raise SystemExit(f'{name}: image has {data[off:off + len(o)].hex()} at 0x{addr:08X}, expected {orig}')
                img = os.path.join(tmp, f'mutant_{name}.bin')
                open(img, 'wb').write(data[:off] + n + data[off + len(o):])
            jobs.append({'scenario_path': lib['boot_v'].path, 'image': img, 'inputs': args.inputs, 'eeprom': args.eeprom,
                         'seed': args.seed, 'gpio_all': False, 'workdir': tmp, 'keep': False, 'role': name,
                         'trace_dir': None, 'meta': (name, addr, orig, new, kind, why),
                         'wall_limit': wall_limit(lib['boot_v'], args.timeout_scale),
                         'deviations': allow if kind == 'ALLOWED' else args.deviations})
        by_role = {r['role']: r for r in run_jobs(jobs, max(1, min(args.jobs, len(jobs))))}
        results = [by_role[j['role']] for j in jobs]            # in the order of the jobs, as Pool.map returned them
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    L = ['# Hardware-safety check proof', '',
         f'Scenario boot_v on the reference image (sha256 `{sha256(ref)}`) and on one-change copies of it; whitelist '
         f'`emulator/diff/hy3131_whitelist`.', '',
         '| image | change | expected | result | first violation |', '|---|---|---|---|---|']
    ok = True
    for job, r in zip(jobs, results):
        name, addr, orig, new, kind, why = job['meta']
        if r.get('error'):
            L.append(f'| {name} | {why} | {kind or "none"} | **run error** | {r["error"].splitlines()[-1]} |')
            ok = False
            continue
        v = r['final']['safety']
        if kind == 'ALLOWED':
            notes = [ev[2][0] for ev in r['events'] if ev[1] == 'log' and ev[2][0].startswith('HARDWARE SAFETY ALLOWED')]
            good = not v and bool(notes)
            v = v or notes
        else:
            good = (not v) if kind is None else any(x.startswith(f'HARDWARE SAFETY: {kind}:') for x in v)
        ok &= good
        where = f'0x{addr:08X} {orig} -> {new}: ' if addr else ''
        L.append(f'| {name} | {where}{why} | {kind or "no violation"} | {"pass" if good else "**FAIL**"} | '
                 f'{v[0] if v else "-"} |')
    print('\n'.join(L[4:]), flush=True)
    print('safety check ' + ('PASSED' if ok else 'FAILED'), flush=True)
    return '\n'.join(L) + '\n', 0 if ok else 1


def parse_tol(items):
    out = {}
    for it in items or ():
        s, _, v = it.partition('=')
        if s not in cmpm.COMPARED or not v:
            raise SystemExit(f'--tol {it}: expected <stream>=<seconds> with a compared stream')
        out[s] = float(v)
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('--ref', required=True, help='reference image (original v2.05)')
    ap.add_argument('--cand', help='candidate image')
    ap.add_argument('--eeprom', required=True, help='EEPROM image (raw bytes from offset 0), copied for every run')
    ap.add_argument('--scenario', default='all', help='scenario name, comma-separated names, or all (default)')
    ap.add_argument('--long', action='store_true', help='include scenarios flagged long in "all"')
    ap.add_argument('--report', help='write the markdown report to this file')
    ap.add_argument('--inputs', default=os.path.join(ROOT, 'inputs', 'binaries'),
                    help='directory with bootloader.bin and option.bytes (and images given by name)')
    ap.add_argument('--deviations', help='deviation allowlist (default firmware/deviations.txt when it exists)')
    ap.add_argument('--build', choices=allowlist.BUILDS,
                    help='build mode of the candidate (baseline = the like-v2.05 build of its branch, production = the fast build): selects the '
                         'allowlist entries tagged "build == ..." (none are used when not given)')
    ap.add_argument('--tol', action='append', metavar='STREAM=SECONDS', help='time tolerance of a stream')
    ap.add_argument('--seed', type=int, default=1, help='HY3131 noise seed used for every run (default 1)')
    ap.add_argument('--no-noise', action='store_true',
                    help='HY3131 noise off (for images whose timing differs: a shift below 1 us changes the noise drawn)')
    ap.add_argument('--jobs', type=int, default=2, help='parallel emulator processes (default 2: the machine is shared)')
    ap.add_argument('--timeout-scale', type=float, default=1.0, metavar='X',
                    help='multiply the wall-clock limit of each run (300 s + 20 x its emulated length) by X >= 1, for a slow '
                         'or busy host; the limit cannot be switched off')
    ap.add_argument('--gpio-all', action='store_true', help='also record the bus pins decoded by spi / rtc')
    ap.add_argument('--trace-dir', help='write the full event trace of every run to this directory')
    ap.add_argument('--workdir', default=None, help='parent directory for temporary run files (default system temp)')
    ap.add_argument('--keep', action='store_true', help='keep temporary run files (EEPROM copies, card images)')
    ap.add_argument('--self-test', action='store_true', help='reference against itself: must be identical')
    ap.add_argument('--mutation-check', action='store_true', help='detect a one-byte change of the splash constant')
    ap.add_argument('--make-whitelist', action='store_true',
                    help='regenerate emulator/diff/hy3131_whitelist from all scenarios run on the reference image')
    ap.add_argument('--merge', action='store_true',
                    help='with --make-whitelist and --scenario: add the runs of those scenarios to the existing whitelist')
    ap.add_argument('--safety-check', action='store_true',
                    help='show that each hardware-safety check fires on a mutated copy of the reference image')
    ap.add_argument('--list', action='store_true', help='list the scenarios and exit')
    args = ap.parse_args(argv)
    if args.timeout_scale < 1:
        ap.error('--timeout-scale must be at least 1 (the limit can be raised, not lowered or switched off)')
    lib = scen.library()
    if args.list:
        for sc in lib.values():
            print(f'{sc.name:32s} {",".join(sorted(sc.flags)) or "-":16s} {"; ".join(sc.sources)}')
        return 0
    args.inputs = os.path.abspath(args.inputs)
    args.eeprom = os.path.abspath(args.eeprom)
    if not os.path.exists(args.eeprom):
        raise SystemExit(f'EEPROM image {args.eeprom} not found')
    if args.deviations is None:
        default = os.path.join(ROOT, 'firmware', 'deviations.txt')
        args.deviations = default if os.path.exists(default) else None
    args.tol = parse_tol(args.tol)
    if args.trace_dir:
        os.makedirs(args.trace_dir, exist_ok=True)
        args.trace_dir = os.path.abspath(args.trace_dir)
    ref = resolve_image(args.ref, args.inputs)
    if args.make_whitelist:
        return make_whitelist(args, ref, lib)
    if args.safety_check:
        report, status = safety_check(args, ref, lib)
    elif args.mutation_check:
        report, status = mutation_check(args, ref, lib)
    else:
        scenarios = select(args.scenario, lib, args.long)
        if args.self_test:
            cand, title = ref, 'Self-test: reference against itself'
        else:
            if not args.cand:
                ap.error('--cand is required (or use --self-test / --mutation-check)')
            cand, title = resolve_image(args.cand, args.inputs), 'Differential test'
        report, ndiv, nfail, _, _ = do_compare(scenarios, ref, cand, args, title)
        status = 0 if ndiv == 0 and nfail == 0 else 1
    if args.report:
        with open(args.report, 'w') as f:
            f.write(report)
        print(f'report written to {args.report}')
    return status


if __name__ == '__main__':
    sys.exit(main())
