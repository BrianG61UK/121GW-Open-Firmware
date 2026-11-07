"""The program's commands and state with a fake meter on the link: desk mode, keys, diagnosis, card, settings, options,
and the server's header rule.  No Bluetooth: the link's send is replaced; its thread only idles."""
import http.client
import json
import os
import shutil
import tempfile
import time
import unittest

from support import FakeMeter, card, frames, sample_files
from meter121 import app as app_mod, server


def wait(cond, seconds=5.0):
    end = time.time() + seconds
    while time.time() < end:
        if cond():
            return True
        time.sleep(0.01)
    return False


def status_frame():
    f = bytearray(19)
    f[0] = 0xF2
    f[5] = 1                                           # DCV
    x = 0
    for b in f[:18]:
        x ^= b
    f[18] = x
    return bytes(f)


class AppCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self._cfg = app_mod.config_path
        app_mod.config_path = lambda: os.path.join(self.tmp, 'cfg', 'settings.json')
        self.addCleanup(setattr, app_mod, 'config_path', self._cfg)
        self._period = app_mod.DESK_PERIOD
        app_mod.DESK_PERIOD = 0.05
        self.addCleanup(setattr, app_mod, 'DESK_PERIOD', self._period)
        self.app = app_mod.Companion(os.path.join(self.tmp, 'docs'))
        self.meter = FakeMeter(sample_files(), eeprom={0x00F: 0, 0x017: 3, 0x020: 0b0101, 0x022: 1, 0x02A: 100})
        self.meter.deliver = self.app._frame
        self.meter.notify = 11
        self.app.link.send = self.meter.send
        self.app.link.state = 'connected'
        self.app.fw_kind, self.app.mode = 'fast', 'firmware'
        for k in card.TIMEOUTS:
            card.TIMEOUTS[k] = 2.0                      # the default is long; nothing here waits for a lost answer

    def tearDown(self):
        card.TIMEOUTS.update({card.T_LIST: 15.0, card.T_READ: 30.0, card.T_CHUNK: 5.0, card.T_DELETE: 20.0, card.T_INFO: 30.0,
                              card.T_FORMAT: 180.0})
        self.app.link.state = 'idle'

    def go_desk(self):
        self.assertTrue(wait(lambda: self.app.desk), 'desk mode not detected')

    def card_op(self, command):
        r = self.app.command(command)
        self.assertEqual(set(r), {'ok', 'job'})
        self.assertTrue(wait(lambda: self.app.state()['card']['done_job'] >= r['job']), 'card operation did not end')
        return self.app.state()['card']


class State(AppCase):
    def test_state_contract_keys(self):
        self.app.link.state = 'idle'
        st = self.app.state()
        for k in ('now', 'link', 'meter', 'update', 'clock', 'session', 'folder'):          # the keys that existed before
            self.assertIn(k, st)
        self.assertEqual(set(st['derived']), {'rel_pct', 'loop_pct', 'loop_range', 'pt_c', 'pt_type', 'limit'})
        self.assertEqual(set(st['derived']['limit']), {'lo', 'hi', 'unit', 'verdict'})
        self.assertIs(st['desk'], False)
        self.assertEqual(st['diag'], {'values': [], 'text': ''})
        self.assertEqual(set(st['card']), {'files', 'listed', 'free_bytes', 'total_bytes', 'busy', 'op', 'progress', 'sync', 'error',
                                           'result', 'job', 'done_job', 'locked_reason'})
        self.assertEqual(set(st['card']['sync']), {'folder', 'last', 'copied'})
        self.assertEqual(set(st['settings']), {'items', 'locked_reason', 'error'})
        self.assertEqual(st['settings']['locked_reason'], 'not connected to a meter')
        json.dumps(st)

    def test_recordings_list_the_folder_newest_first(self):
        import tempfile
        with tempfile.TemporaryDirectory() as d:
            self.app.folder, self.app._rec_cache = d, None
            self.assertEqual(self.app.state()['recordings'], [])
            for i, n in enumerate(('121GW_a.csv', '121GW_b.csv', 'notes.txt')):
                with open(os.path.join(d, n), 'w') as f:
                    f.write('x' * (10 + i))
                os.utime(os.path.join(d, n), (1000000000 + i, 1000000000 + i))
            self.app._rec_cache = None
            rec = self.app.state()['recordings']
            self.assertEqual([r['name'] for r in rec], ['121GW_b.csv', '121GW_a.csv'])        # newest first, CSV only
            self.assertEqual([r['size'] for r in rec], [11, 10])
            self.assertEqual(rec[0]['date'], time.strftime('%Y-%m-%d', time.localtime(1000000001)))
        self.app.folder, self.app._rec_cache = os.path.join(d, 'gone'), None
        self.assertEqual(self.app.state()['recordings'], [])                                 # folder missing

    def test_derived_follows_the_frames(self):
        self.app.derived.set_options({'limit': {'lo': 1, 'hi': 2, 'unit': 'V'}})
        self.app._frame(frames.STATUS, status_frame(), time.time())
        self.assertEqual(self.app.state()['derived']['limit']['verdict'], 'LO')            # 0.0000 V < 1 V


class Desk(AppCase):
    def test_desk_is_detected_and_left_with_the_first_status_frame(self):
        self.go_desk()
        self.assertIsNone(self.app.state()['settings']['locked_reason'])
        self.app._frame(frames.STATUS, status_frame(), time.time())
        self.assertFalse(self.app.state()['desk'])

    def test_no_desk_on_a_measuring_page_without_frames(self):
        self.meter.on_ld = False                        # no status frames (digits blank) and no answer to the probe
        time.sleep(0.4)
        self.assertFalse(self.app.desk)

    def test_no_desk_without_connection_or_with_v205(self):
        self.app.link.state = 'idle'
        time.sleep(0.3)
        self.assertFalse(self.app.desk)
        self.app.link.state, self.app.fw_kind = 'connected', 'other'
        time.sleep(0.3)
        self.assertFalse(self.app.desk)
        self.assertEqual(self.meter.sent, [])           # v2.05 is not sent transfer packets

    def test_fresh_frames_keep_desk_off(self):
        self.app._frame_t = time.time() + 3600
        time.sleep(0.3)
        self.assertFalse(self.app.desk)
        self.assertEqual(self.meter.sent, [])


class Keys(AppCase):
    def test_key_is_sent_and_echoed(self):
        r = self.app.command({'key': 'REL'})
        self.assertEqual(r, {'ok': True, 'key': 'REL', 'long': False})
        self.assertEqual(self.app.command({'key': 'setup', 'long': True})['long'], True)
        self.assertEqual(self.meter.keys, [b'\xF4' + b'0303', b'\xF4' + b'8888'])

    def test_refused_on_page_ld(self):
        self.go_desk()
        with self.assertRaises(RuntimeError) as e:
            self.app.command({'key': 'REL'})
        self.assertIn('Ld', str(e.exception))
        self.assertEqual(self.meter.keys, [])

    def test_refused_while_busy_or_updating_or_in_update_mode(self):
        self.app.update['state'] = 'sending'
        with self.assertRaises(RuntimeError):
            self.app.command({'key': 'MODE'})
        self.app.update['state'] = 'none'
        self.app.card_st['busy'] = True
        with self.assertRaises(RuntimeError):
            self.app.command({'key': 'MODE'})
        self.app.card_st['busy'] = False
        self.app.mode = 'bootloader'
        with self.assertRaises(RuntimeError):
            self.app.command({'key': 'MODE'})
        self.assertEqual(self.meter.keys, [])

    def test_unknown_key_and_no_echo(self):
        with self.assertRaises(ValueError):
            self.app.command({'key': 'POWER'})
        app_mod.KEY_ECHO_WAIT, old = 0.1, app_mod.KEY_ECHO_WAIT
        self.addCleanup(setattr, app_mod, 'KEY_ECHO_WAIT', old)
        self.meter.echo_keys = False
        with self.assertRaises(RuntimeError) as e:
            self.app.command({'key': 'HOLD'})
        self.assertIn('did not confirm', str(e.exception))


class Diag(AppCase):
    def test_read_while_on_ld(self):
        with self.assertRaises(RuntimeError):
            self.app.command({'diag_read': True})       # not on Ld yet
        self.go_desk()
        r = self.app.command({'diag_read': True})
        self.assertEqual(r['diag']['values'], list(range(100, 121)))
        st = self.app.state()['diag']
        self.assertEqual(st['values'], list(range(100, 121)))
        self.assertIn('failed card sessions', st['text'])


class CardCommands(AppCase):
    def test_format(self):
        self.go_desk()
        with self.assertRaises(ValueError):                              # the typed word is required
            self.app.command({'card_format': True, 'confirm': 'format'})
        self.assertEqual(len(self.meter.files), len(sample_files()))      # nothing sent, nothing erased
        self.meter.two_part = False
        st = self.card_op({'card_format': True, 'confirm': 'FORMAT'})
        self.assertIn('two-part bootloader', st['error'] or '')         # the meter's refusal reaches the page
        self.assertEqual(len(self.meter.files), len(sample_files()))
        self.meter.two_part = True
        self.meter.logging = True                                         # the fake answers 3, as a firmware before F-1.09
        st = self.card_op({'card_format': True, 'confirm': 'FORMAT'})
        self.assertIn('older than F-1.09', st['error'] or '')
        self.meter.logging = False
        st = self.card_op({'card_format': {'confirm': 'FORMAT'}})
        self.assertIsNone(st['error'])
        self.assertEqual((st['files'], st['result']), ([], 'the card is formatted'))
        self.assertEqual(st['free_bytes'], st['total_bytes'])
        self.assertEqual([p for t, p in self.meter.sent if t == card.T_FORMAT][-1], b'FORMAT')

    def test_refused_until_desk(self):
        with self.assertRaises(RuntimeError):
            self.app.command({'card_list': True})

    def test_list_info_download_delete_sync(self):
        self.go_desk()
        st = self.card_op({'card_list': True})
        self.assertEqual([f['name'] for f in st['files']], sorted(sample_files()))
        self.assertIsNone(st['error'])
        st = self.card_op({'card_info': True})
        self.assertEqual((st['free_bytes'], st['total_bytes']), (1_000_000 * 64 * 512, 100_000_000 * 64 * 512))
        self.app.card_st.update(files=[], listed=False, free_bytes=None, total_bytes=None)
        st = self.card_op({'card_refresh': True})                  # what the page sends: list and space in one job
        self.assertTrue(st['listed'])                               # the page may now say "no files" for an empty list
        self.assertEqual([f['name'] for f in st['files']], sorted(sample_files()))
        self.assertEqual((st['free_bytes'], st['total_bytes']), (1_000_000 * 64 * 512, 100_000_000 * 64 * 512))
        self.assertIsNone(st['error'])
        dest = os.path.join(self.tmp, 'dl')
        st = self.card_op({'card_download': True, 'name': 'LOG0002.CSV', 'dest': dest})
        self.assertIsNone(st['error'])
        self.assertEqual(st['progress'], 1.0)
        self.assertEqual(st['result'], os.path.join(dest, 'LOG0002.CSV'))
        self.assertEqual(os.path.getsize(os.path.join(dest, 'LOG0002.CSV')), 20000)
        st = self.card_op({'card_delete': {'name': 'LOG0001.CSV'}})                       # the object form
        self.assertNotIn('LOG0001.CSV', [f['name'] for f in st['files']])
        folder = os.path.join(self.tmp, 'sync')
        st = self.card_op({'card_sync': True, 'folder': folder})
        self.assertEqual((st['sync']['folder'], st['sync']['copied']), (folder, 4))
        self.assertTrue(st['sync']['last'])
        st = self.card_op({'card_sync': True})                                            # the folder is remembered
        self.assertEqual(st['sync']['copied'], 0)
        with open(app_mod.config_path()) as f:
            self.assertEqual(json.load(f)['card_sync_folder'], folder)

    def test_protected_delete_is_refused_before_any_packet(self):
        self.go_desk()
        n = len(self.meter.sent)
        with self.assertRaises(RuntimeError):
            self.app.command({'card_delete': True, 'name': 'cal.bin'})
        self.assertFalse(self.app.state()['card']['busy'])
        self.assertNotIn(card.T_DELETE, [t for t, _ in self.meter.sent[n:]])

    def test_one_operation_at_a_time_and_errors_are_reported(self):
        self.go_desk()
        self.app.card_st['busy'], self.app.card_st['op'] = True, 'sync'
        with self.assertRaises(RuntimeError) as e:
            self.app.command({'card_list': True})
        self.assertIn('sync', str(e.exception))
        self.app.card_st['busy'] = False
        self.meter.logging = True
        st = self.card_op({'card_list': True})
        self.assertIn('not allowed', st['error'])

    def test_bad_parameters(self):
        self.go_desk()
        for cmd in ({'card_download': True, 'name': '../x', 'dest': ''}, {'card_download': True, 'name': 5},
                    {'card_download': True, 'name': 'a', 'dest': 5}, {'card_sync': True, 'folder': ['x']},
                    {'card_delete': True}):
            with self.assertRaises((RuntimeError, ValueError), msg=str(cmd)):
                self.app.command(cmd)


class SettingsCommands(AppCase):
    def test_anti_hunting_row_needs_firmware_f116(self):
        self.go_desk()
        self.app.version = 'F-1.15'
        codes = [i['code'] for i in self.app.command({'settings_get': True})['items']]
        self.assertNotIn('HUnt', codes)
        with self.assertRaises(ValueError):
            self.app.command({'settings_put': {'id': 0x420, 'value': 1}})
        self.assertEqual(self.meter.eeprom[0x020], 0b0101)
        self.app.version = 'F-1.16'
        items = self.app.command({'settings_get': True})['items']
        self.assertEqual(next(i for i in items if i['code'] == 'HUnt')['text'], 'off')
        self.app.command({'settings_put': {'id': 0x420, 'value': 1}})
        self.assertEqual(self.meter.eeprom[0x020], 0b10101)

    def test_get_put_and_ranges(self):
        with self.assertRaises(RuntimeError):
            self.app.command({'settings_get': True})
        self.go_desk()
        r = self.app.command({'settings_get': True})
        self.assertEqual(len(r['items']), 7)                    # the fake reports tc, bL, the three rows of the one id 0x020, Ch, BAT
        self.assertEqual([i['code'] for i in self.app.state()['settings']['items']], ['tc', 'bL', 'rEL', 'tr', 'CL', 'Ch', 'BAT'])
        r = self.app.command({'settings_put': True, 'id': 0x00F, 'value': 3})
        self.assertEqual(self.meter.eeprom[0x00F], 3)
        self.app.command({'settings_put': {'id': 0x320, 'value': 1}})
        self.assertEqual(self.meter.eeprom[0x020], 0b1101)
        self.assertEqual(self.meter.eeprom[0x017], 3)
        before = len(self.meter.sent)
        for bad in ({'id': 0x00F, 'value': 6}, {'id': 0x018, 'value': 0}, {'id': 'tc', 'value': 0}, {'id': 0x00F, 'value': True}):
            with self.assertRaises(ValueError):
                self.app.command(dict(bad, settings_put=True))
        self.assertEqual(len(self.meter.sent), before)

    def test_meter_error_lands_in_state(self):
        self.go_desk()
        self.meter.refuse_put = card.ST_NOT_NOW
        with self.assertRaises(RuntimeError):
            self.app.command({'settings_put': True, 'id': 0x00F, 'value': 1})
        self.assertIn('not allowed', self.app.state()['settings']['error'])


class Options(AppCase):
    def test_set_derived_persists(self):
        r = self.app.command({'set_derived': {'loop_range': '0-20', 'pt_type': 'Pt100',
                                              'limit': {'lo': 99, 'hi': 101, 'unit': 'ohm'}}})
        self.assertEqual(r['derived']['loop_range'], '0-20')
        with open(app_mod.config_path()) as f:
            saved = json.load(f)['derived']
        self.assertEqual(saved['pt_type'], 'Pt100')
        again = app_mod.Companion(os.path.join(self.tmp, 'docs'))
        self.assertEqual(again.state()['derived']['limit']['hi'], 101.0)
        self.assertEqual(again.state()['derived']['pt_type'], 'Pt100')

    def test_top_level_form_and_bad_values(self):
        self.app.command({'set_derived': True, 'loop_range': '0-20'})
        self.assertEqual(self.app.state()['derived']['loop_range'], '0-20')
        with self.assertRaises(ValueError):
            self.app.command({'set_derived': True, 'pt_type': 'Pt7'})
        self.assertEqual(self.app.state()['derived']['pt_type'], None)

    def test_damaged_saved_options_fall_back_to_defaults(self):
        os.makedirs(os.path.dirname(app_mod.config_path()))
        with open(app_mod.config_path(), 'w') as f:
            json.dump({'derived': {'loop_range': 'nonsense'}}, f)
        self.assertEqual(app_mod.Companion(self.tmp).state()['derived']['loop_range'], '4-20')


class BootloaderQuestion(AppCase):
    """Key code 0x92 (bootloader version) is asked again when an answer is lost (GitHub issue 10)."""
    def answering(self, lost):
        """The meter answers 0x92 with F7 'B-113', the first `lost` answers do not arrive."""
        body = b'\xF7B-113'
        x = 0
        for b in body:
            x ^= b
        f7 = body + bytes([x])
        asked = []
        send = self.meter.send

        def meter_send(pkt):
            if bytes(pkt) == bytes(frames.BL_VERSION_REQUEST):
                asked.append(1)
                if len(asked) > lost:
                    self.meter._out(f7)
                return
            send(pkt)
        self.app.link.send = meter_send
        wait_ = app_mod.VERSION_WAIT
        app_mod.VERSION_WAIT = 0.1
        self.addCleanup(setattr, app_mod, 'VERSION_WAIT', wait_)
        return asked

    def test_a_lost_answer_is_asked_again(self):
        asked = self.answering(lost=1)
        self.assertEqual(self.app._ask_bootloader(), 'B-1.13')
        self.assertEqual(len(asked), 2)

    def test_no_answer_after_all_tries(self):
        asked = self.answering(lost=99)
        self.assertIsNone(self.app._ask_bootloader())
        self.assertEqual(len(asked), app_mod.BL_ASK_TRIES)


class VersionQuestion(AppCase):
    """Key code 0x90: the fast firmware answers with the echo and a version frame F6; v2.05 only with the echo.  A lost
    version frame must not make F-1.12 look like v2.05 (GitHub issue 9)."""
    def answering(self, lost):
        body = b'\xF6F-112'
        x = 0
        for b in body:
            x ^= b
        f6 = body + bytes([x])
        asked = []

        def meter_send(pkt):
            pkt = bytes(pkt)
            if pkt == bytes(frames.VERSION_REQUEST):
                asked.append(1)
                self.meter._out(pkt)                       # the echo always arrives
                if len(asked) > lost:
                    self.meter._out(f6)
            elif pkt[:1] == b'\xF4':
                self.meter._out(pkt)                       # other key frames (0x92): echo only, no bootloader answer
        self.app.link.send = meter_send
        for name, value in (('VERSION_WAIT', 0.1), ('VERSION_RETRY', 0.1)):
            old = getattr(app_mod, name)
            setattr(app_mod, name, value)
            self.addCleanup(setattr, app_mod, name, old)
        self.app._check_release = lambda: None              # no release lookup on the internet in a test
        self.app.fw_kind, self.app.version, self.app.mode = 'unknown', None, 'unknown'
        self.app._asked.set()
        self.assertTrue(wait(lambda: self.app.mode == 'firmware', 10), 'no decision')
        return asked

    def test_lost_version_frames_are_asked_again(self):
        asked = self.answering(lost=app_mod.VERSION_TRIES - 1)
        self.assertEqual((self.app.fw_kind, self.app.version), ('fast', 'F-1.12'))
        self.assertEqual(len(asked), app_mod.VERSION_TRIES)

    def test_echo_only_every_time_is_v205(self):
        asked = self.answering(lost=99)
        self.assertEqual(self.app.fw_kind, 'other')
        self.assertEqual(len(asked), app_mod.VERSION_TRIES)


class Report(AppCase):
    """The diagnosis report (report.py): its sections, the event log, and nothing that identifies the user."""
    def test_report_is_written_and_anonymised(self):
        import getpass
        import socket
        from meter121 import report
        self.app.link.device = ('6C6DCEDE-1C8B-ECC5-EA3B-4067CF1EB479', '121GW')
        self.app.version, self.app.bl = 'F-1.12', 'EEV'
        self.app.event('link connected: 121GW AA:BB:CC:DD:EE:FF')
        self.app.event('card download failed: cannot write %s' % os.path.join(os.path.expanduser('~'), 'Documents', 'x.csv'))
        self.app.event('bootloader question: no answer')
        r = self.app.command({'save_report': True})
        self.assertEqual(os.path.dirname(r['path']), self.app.folder)
        with open(r['path'], encoding='utf-8') as f:
            text = f.read()
        for part in ('[meter]', 'F-1.12', 'bootloader  EEV', '[link]', '[update]', '[diagnosis of the firmware]',
                     '[events, oldest first]', 'bootloader question: no answer', 'companion   source'):
            self.assertIn(part, text)
        for secret in ('6C6DCEDE-1C8B-ECC5-EA3B-4067CF1EB479', 'AA:BB:CC:DD:EE:FF', os.path.expanduser('~'), self.tmp):
            self.assertNotIn(secret, text)
        for name in (socket.gethostname(), getpass.getuser()):
            if len(name) >= 3:
                self.assertNotRegex(text, r'(?i)(?<![A-Za-z0-9])%s(?![A-Za-z0-9])' % __import__('re').escape(name))
        self.assertIn('<address>', text)
        self.assertIn('<path>', text)
        self.assertEqual(report.anonymise('random dom', ['dom']), 'random <name>')

    def test_linux_distribution(self):
        from unittest import mock
        from meter121 import report
        with mock.patch('platform.freedesktop_os_release', create=True,
                        return_value={'NAME': 'Ubuntu', 'PRETTY_NAME': 'Ubuntu 24.04.1 LTS'}):
            self.assertEqual(report.linux_distribution(), 'Ubuntu 24.04.1 LTS, ')
        with mock.patch('platform.freedesktop_os_release', create=True, side_effect=OSError('no os-release')):
            self.assertEqual(report.linux_distribution(), '')
        with mock.patch('platform.freedesktop_os_release', create=True, return_value={'NAME': 'Linux'}):
            self.assertEqual(report.linux_distribution(), '')
        with mock.patch('sys.platform', 'linux'), mock.patch('platform.system', return_value='Linux'), \
                mock.patch('platform.release', return_value='6.8.0'), mock.patch('platform.machine', return_value='x86_64'), \
                mock.patch('platform.freedesktop_os_release', create=True, return_value={'PRETTY_NAME': 'Fedora Linux 41'}):
            self.assertEqual(report.system_text(), 'Fedora Linux 41, Linux 6.8.0 (x86_64)')
        # a computer named like its distribution: the distribution stays, the computer's name elsewhere is hidden
        self.assertEqual(report.anonymise('system Ubuntu 24.04.1 LTS, Linux; host ubuntu', ['ubuntu'],
                                          keep='Ubuntu 24.04.1 LTS'), 'system Ubuntu 24.04.1 LTS, Linux; host <name>')
        self.assertEqual(report.anonymise('host ubuntu', ['ubuntu'], keep=''), 'host <name>')

    def test_version_events(self):
        self.app.event('version question: echo only')
        self.assertEqual(self.app.events[-1][1], 'version question: echo only')
        self.assertLessEqual(len(self.app.events), app_mod.EVENTS_KEEP)


class Prefs(AppCase):
    """The program's own settings (SETTINGS view): prefs_set / prefs_reset, stored in settings.json."""
    def unforced(self):
        """A program started without --folder: its recordings folder comes from the setting or <Documents>/121GW."""
        docs = app_mod.documents_folder
        app_mod.documents_folder = lambda: os.path.join(self.tmp, 'Documents', '121GW')
        self.addCleanup(setattr, app_mod, 'documents_folder', docs)
        a = app_mod.Companion()
        a.link.state = 'idle'
        return a

    def set(self, key, value, app=None):
        return (app or self.app).command({'prefs_set': {'key': key, 'value': value}})

    def test_state_and_defaults(self):
        p = self.app.state()['prefs']
        self.assertEqual({k: p[k] for k in ('clock_on_connect', 'update_check', 'csv_format', 'theme', 'diag_log')},
                         {'clock_on_connect': False, 'update_check': 'connect', 'csv_format': 'comma', 'theme': 'system',
                          'diag_log': False})
        self.assertEqual(p['recordings_folder'], os.path.join(self.tmp, 'docs'))
        self.assertTrue(p['folder_forced'])
        self.assertEqual(p['card_sync_folder'], os.path.join(self.tmp, 'docs', 'card'))
        self.assertEqual(p['file'], app_mod.config_path())

    def test_set_persists_and_applies(self):
        self.set('csv_format', 'semicolon')
        self.set('theme', 'light')
        self.set('clock_on_connect', True)
        self.set('ntp_server', ' time.example.org ')
        self.set('card_sync_folder', os.path.join(self.tmp, 'sync'))
        self.assertEqual(self.app.clock['server'], 'time.example.org')
        self.assertEqual(self.app.card_st['sync']['folder'], os.path.join(self.tmp, 'sync'))
        again = app_mod.Companion(os.path.join(self.tmp, 'docs'))
        p = again.prefs()
        self.assertEqual((p['csv_format'], p['theme'], p['clock_on_connect'], p['ntp_server'], p['card_sync_folder']),
                         ('semicolon', 'light', True, 'time.example.org', os.path.join(self.tmp, 'sync')))

    def test_bad_values_are_refused_and_not_stored(self):
        for key, value in (('nonsense', 1), ('clock_on_connect', 'yes'), ('diag_log', 1), ('update_check', 'hourly'),
                           ('csv_format', 'tab'), ('theme', 'blue'), ('theme', None), ('theme', True), ('theme', 'Light'),
                           ('ntp_server', 'a b'), ('ntp_server', ''), ('card_sync_folder', '  ')):
            with self.assertRaises(ValueError, msg=key):
                self.set(key, value)
        self.assertFalse(os.path.exists(app_mod.config_path()))

    def test_theme_values(self):
        for v in app_mod.THEMES:                               # all three are accepted and reported back
            self.assertEqual(self.set('theme', v)['prefs']['theme'], v)
        self.assertEqual(app_mod.THEMES, ('dark', 'light', 'system'))
        with open(app_mod.config_path()) as f:
            self.assertEqual(json.load(f)['theme'], 'system')

    def test_theme_from_a_hand_edited_file_is_the_default(self):
        os.makedirs(os.path.dirname(app_mod.config_path()), exist_ok=True)
        with open(app_mod.config_path(), 'w') as f:
            json.dump({'theme': 'purple'}, f)
        self.assertEqual(app_mod.Companion(os.path.join(self.tmp, 'docs')).prefs()['theme'], 'system')

    def test_recordings_folder(self):
        with self.assertRaises(ValueError):                   # --folder given: the setting cannot override it
            self.set('recordings_folder', os.path.join(self.tmp, 'x'))
        a = self.unforced()
        self.assertEqual(a.folder, os.path.join(self.tmp, 'Documents', '121GW'))
        new = os.path.join(self.tmp, 'rec')
        self.set('recordings_folder', new, a)
        path = a.command({'record': True})['path']
        self.assertEqual(os.path.dirname(path), new)
        with self.assertRaises(RuntimeError):                 # not while recording
            self.set('recordings_folder', os.path.join(self.tmp, 'y'), a)
        a.command({'record': False})
        self.assertEqual(self.unforced().folder, new)         # the next start uses the setting

    def test_csv_format_semicolon(self):
        self.set('csv_format', 'semicolon')
        path = self.app.command({'record': True})['path']
        self.app.session.add({'t': 1000.25, 'value': 1.5, 'text': '1.500', 'unit': 'V', 'mode_name': 'DCV',
                              'sub_text': '0.25', 'sub_unit': 'Hz', 'symbols': ['DC']})
        self.app.command({'record': False})
        with open(path, encoding='utf-8') as f:
            head, row = f.read().splitlines()[:2]
        self.assertEqual(head.split(';')[0], 'time')
        cols = row.split(';')
        self.assertTrue(cols[0].endswith(',250'), cols[0])
        self.assertEqual(cols[1:8], ['DCV', '1,500', 'V', '1,5', '0,25', 'Hz', 'DC'])

    def test_update_check_never_and_daily(self):
        calls = []
        latest = app_mod.releases.latest
        app_mod.releases.latest = lambda: calls.append(1) or (_ for _ in ()).throw(app_mod.releases.ReleaseError('offline'))
        self.addCleanup(setattr, app_mod.releases, 'latest', latest)
        self.app.settings['update_check'] = 'never'
        self.app._check_release()
        self.assertEqual(calls, [])
        self.assertEqual(self.app.update['check_error'], 'update check off (SETTINGS)')
        self.app.settings.update(update_check='daily', release_checked_at=time.time() - 60)
        self.app._check_release()
        self.assertEqual(calls, [])                           # checked a minute ago: not again today
        self.app.settings['release_checked_at'] = time.time() - app_mod.DAILY - 1
        self.app._check_release()
        self.assertEqual(calls, [1])

    def test_reset(self):
        a = self.unforced()
        self.set('csv_format', 'semicolon', a)
        self.set('theme', 'light', a)
        self.set('recordings_folder', os.path.join(self.tmp, 'rec'), a)
        a.command({'set_derived': {'loop_range': '0-20'}})
        r = a.command({'prefs_reset': True})
        self.assertEqual(r['prefs']['csv_format'], 'comma')
        self.assertEqual(r['prefs']['theme'], 'system')
        self.assertEqual(a.folder, os.path.join(self.tmp, 'Documents', '121GW'))
        self.assertEqual(a.state()['derived']['loop_range'], '4-20')
        with open(app_mod.config_path()) as f:
            self.assertEqual(json.load(f), {})


class Http(AppCase):
    def test_commands_need_the_header(self):
        self.app._frame_t = time.time() + 3600         # the desk watcher probes after DESK_STALE s without a status frame:
                                                       # keep it quiet, so that every packet sent here comes from a command
        httpd = server.serve(self.app, 0)
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        port = httpd.server_address[1]

        def post(body, headers):
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            c.request('POST', '/api', json.dumps(body), headers)
            r = c.getresponse()
            try:
                return r.status, json.loads(r.read())
            finally:
                c.close()
        for cmd in ({'key': 'REL'}, {'card_list': True}, {'card_delete': True, 'name': 'x'}, {'settings_put': True, 'id': 15, 'value': 1},
                    {'diag_read': True}, {'set_derived': True, 'loop_range': '0-20'}, {'card_sync': True, 'folder': self.tmp}):
            self.assertEqual(post(cmd, {})[0], 403, cmd)
        self.assertEqual(self.app.state()['derived']['loop_range'], '4-20')
        self.assertEqual(self.meter.sent, [])
        self.assertEqual(self.meter.keys, [])
        code, body = post({'key': 'REL'}, {server.HEADER: '1'})
        self.assertEqual((code, body['key']), (200, 'REL'))
        code, body = post({'key': 'POWER'}, {server.HEADER: '1'})
        self.assertEqual(code, 400)                                   # a bad key name is an error answer, not a crash
        code, body = post({'settings_put': True, 'id': [1], 'value': 1}, {server.HEADER: '1'})
        self.assertEqual(code, 400)
        c = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        c.request('GET', '/state')
        r = c.getresponse()
        st = json.loads(r.read())
        c.close()
        self.assertIn('derived', st)
        self.assertIn('card', st)
        for length in ('-1', 'abc'):                                  # answered at once, the thread does not hang
            c = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
            c.putrequest('POST', '/api')
            c.putheader(server.HEADER, '1')
            c.putheader('Content-Length', length)
            c.endheaders()
            r = c.getresponse()
            self.assertEqual((r.status, json.loads(r.read())['error']), (400, 'bad Content-Length'), length)
            c.close()


if __name__ == '__main__':
    unittest.main()
