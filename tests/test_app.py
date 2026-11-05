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
        card.TIMEOUTS.update({card.T_LIST: 15.0, card.T_READ: 30.0, card.T_CHUNK: 5.0, card.T_DELETE: 20.0, card.T_INFO: 30.0})
        self.app.link.state = 'idle'

    def go_desk(self):
        self.assertTrue(wait(lambda: self.app.desk), 'desk mode not detected')

    def card_op(self, command):
        self.assertEqual(self.app.command(command), {'ok': True})
        self.assertTrue(wait(lambda: not self.app.state()['card']['busy']), 'card operation did not end')
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
        self.assertEqual(set(st['card']), {'files', 'free_bytes', 'total_bytes', 'busy', 'op', 'progress', 'sync', 'error',
                                           'result', 'locked_reason'})
        self.assertEqual(set(st['card']['sync']), {'folder', 'last', 'copied'})
        self.assertEqual(set(st['settings']), {'items', 'locked_reason', 'error'})
        self.assertEqual(st['settings']['locked_reason'], 'not connected to a meter')
        json.dumps(st)

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


class Http(AppCase):
    def test_commands_need_the_header(self):
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


if __name__ == '__main__':
    unittest.main()
