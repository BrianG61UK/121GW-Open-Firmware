"""Install a release of your choice (also an older one) or a file of your own (GitHub issue 25), and the notice about a
newer release of this program (GitHub issue 23): release list parsing, downgrade detection and the refusal without the
typed confirmation, the checks of files of the user's own, the bootloader safety rule, the upload endpoint and the notice.
No network (the release list is replaced), no Bluetooth (the transfer steps are recorded, not run)."""
import http.client
import json
import struct
import unittest

from support import transfer
from test_app import AppCase, wait
from meter121 import app as app_mod, install, releases, server

# an API release list as GitHub returns it (newest first); entries that must not be offered are in it too
API = [
    {'tag_name': 'companion-v1.2.25', 'published_at': '2026-11-07T10:00:00Z'},
    {'tag_name': 'companion-v1.2.9', 'published_at': '2026-11-01T10:00:00Z'},
    {'tag_name': 'v1.2.2', 'published_at': '2026-11-07T09:00:00Z'},
    {'tag_name': 'v1.2.1', 'published_at': '2026-11-07T08:00:00Z'},
    {'tag_name': 'v9.9.9', 'draft': True},
    {'tag_name': 'v8.8.8', 'prerelease': True},
    {'tag_name': 'bl-v1.1.3', 'published_at': '2026-11-05T08:00:00Z'},
    {'tag_name': 'bl-v1.1.1', 'published_at': '2026-11-04T08:00:00Z'},
    {'tag_name': 'bl-v1.1.2', 'published_at': '2026-11-04T09:00:00Z'},
    {'tag_name': 'like205-v1.0.0', 'published_at': '2026-11-02T08:00:00Z'},
    {'tag_name': 'v1.1.9', 'published_at': '2026-11-06T08:00:00Z'},
    {'tag_name': 'v1.1.5', 'published_at': '2026-11-06T07:00:00Z'},
    {'tag_name': 'v1.0.2', 'published_at': '2026-11-04T07:00:00Z'},
    {'tag_name': 'v0.9.9'},
    {'tag_name': None},
    'not a release',
]


def fw_image(size=1000, sp=0x20010000, reset=0x08006101):
    """A firmware image the meter's checks accept (releases.check_image)."""
    return struct.pack('<II', sp, reset) + bytes(size - 8)


def bl_image(size=2000, sp=0x2000C000, vec=0x08000501, n=73):
    """A bootloader image with the vector table of the two-part bootloader (bl_main.s)."""
    return struct.pack('<%dI' % n, sp, *([vec] * (n - 1))) + bytes(size - 4 * n)


def entry(kind, text):
    """An entry of releases.list_releases() for the plan tests."""
    return [e for e in releases.parse_releases(API)[kind] if e['text'] == text][0]


def facts(fw='F-1.21', bl='B-1.13', mode='firmware'):
    return {'fw': releases.version_of_meter(fw), 'bl': bl, 'mode': mode}


class ReleaseList(unittest.TestCase):
    def test_kinds_sorted_newest_first_and_older_versions_kept(self):
        r = releases.parse_releases(API)
        self.assertEqual([e['text'] for e in r['firmware']], ['F-1.22', 'F-1.21', 'F-1.19', 'F-1.15', 'F-1.02', 'F-0.99'])
        self.assertEqual([e['tag'] for e in r['firmware']], ['v1.2.2', 'v1.2.1', 'v1.1.9', 'v1.1.5', 'v1.0.2', 'v0.9.9'])
        self.assertEqual([e['text'] for e in r['bootloader']], ['B-1.13', 'B-1.12', 'B-1.11'])
        self.assertEqual([e['text'] for e in r['companion']], ['1.2.25', '1.2.9'])          # numerically, not as text
        self.assertEqual(r['firmware'][0]['published'], '2026-11-07')
        self.assertEqual(r['firmware'][-1]['published'], '')

    def test_drafts_prereleases_and_foreign_tags_left_out(self):
        tags = [e['tag'] for lst in releases.parse_releases(API).values() for e in lst]
        for bad in ('v9.9.9', 'v8.8.8', 'like205-v1.0.0', None):
            self.assertNotIn(bad, tags)

    def test_latest_functions_use_the_list_and_pages_are_followed(self):
        pages = []

        def get(url):
            pages.append(url)
            page = int(url.rsplit('page=', 1)[1])
            part = [{'tag_name': 'v1.0.%d' % (i % 10), 'published_at': ''} for i in range(releases.PER_PAGE)] if page == 1 else API
            return json.dumps(part).encode()
        old = releases._get
        releases._get = get
        self.addCleanup(setattr, releases, '_get', old)
        releases.forget()
        self.addCleanup(releases.forget)
        self.assertEqual(releases.latest(), ((1, 2, 2), 'v1.2.2'))
        self.assertEqual(releases.latest_bootloader(), ((1, 1, 3), 'bl-v1.1.3'))
        self.assertEqual(releases.latest_companion(), ((1, 2, 25), 'companion-v1.2.25'))
        self.assertEqual(len(pages), 2)                                # two pages, fetched once for the three questions

    def test_no_release_of_a_kind(self):
        releases.forget()
        old = releases._fetch
        releases._fetch = lambda: [{'tag_name': 'v1.0.0'}]
        self.addCleanup(setattr, releases, '_fetch', old)
        with self.assertRaises(releases.ReleaseError):
            releases.latest_companion()

    def test_program_version_text(self):
        self.assertEqual(releases.version_of_companion('1.2.24'), (1, 2, 24))
        for text in ('source', 'dev', 'unknown', '', None, '1.2'):
            self.assertIsNone(releases.version_of_companion(text))
        self.assertEqual(releases.page_url('companion-v1.2.25'), 'https://github.com/%s/releases/tag/companion-v1.2.25' % releases.REPO)


class Checks(unittest.TestCase):
    def test_bootloader_image_checks(self):
        self.assertIsNone(releases.check_bootloader_image(bl_image()))
        self.assertIsNone(releases.check_bootloader_image(bl_image(size=releases.BL_MAX)))
        self.assertIn('size', releases.check_bootloader_image(bl_image(size=releases.BL_MAX + 4)))
        self.assertIn('size', releases.check_bootloader_image(bl_image()[:100]))
        self.assertIn('stack pointer', releases.check_bootloader_image(bl_image(sp=0x20002000)))
        self.assertIn('vector 1', releases.check_bootloader_image(bl_image(vec=0x08000500)))          # no Thumb bit
        self.assertIn('vector 1', releases.check_bootloader_image(bl_image(vec=0x08000101)))          # below the bootloader
        self.assertIn('vector 1', releases.check_bootloader_image(bl_image(size=2000, vec=0x08001B01)))   # beyond the image
        self.assertIn('stack pointer', releases.check_bootloader_image(fw_image(2000)))                    # a firmware is no bootloader

    def test_eevblogs_bootloader_is_too_big(self):
        # both known builds are 24576 bytes (bootloader/DESIGN.md 1): over the 23296 bytes a bootloader image may have
        self.assertIn('size', releases.check_bootloader_image(bl_image(size=24576)))


class Plan(unittest.TestCase):
    def test_no_meter_asks_for_the_meter_instead_of_refusing(self):
        # without a meter the list said "refused" for every bootloader; it now asks for the meter, and still sends nothing
        for kind, tag in (('bootloader', 'B-1.13'), ('firmware', 'F-1.21')):
            f = dict(facts(fw=None, bl=None, mode='unknown'), connected=False)
            p = install.make_plan(kind, f, release=entry(kind, tag))
            self.assertTrue(p['needs_meter'], kind)
            self.assertIn('connect the meter', p['refusal'])
        p = install.make_plan('firmware', dict(facts(), connected=True), release=entry('firmware', 'F-1.21'))
        self.assertNotIn('needs_meter', p)

    def test_upgrade_and_same_version_need_no_confirmation(self):
        for fw, tag in (('F-1.15', 'F-1.21'), ('F-1.21', 'F-1.21')):
            p = install.make_plan('firmware', facts(fw=fw), release=entry('firmware', tag), newest=(1, 2, 2))
            self.assertFalse(p['needs_confirm'], tag)
            self.assertEqual((p['refusal'], p['warnings']), (None, []))
        self.assertEqual(install.make_plan('firmware', facts(fw='F-1.15'), release=entry('firmware', 'F-1.21'))['relation'], 'newer')

    def test_firmware_downgrade_needs_confirmation_and_lists_what_lies_between(self):
        p = install.make_plan('firmware', facts(fw='F-1.21'), release=entry('firmware', 'F-1.15'), newest=(1, 2, 2))
        self.assertEqual((p['relation'], p['needs_confirm'], p['refusal']), ('older', True, None))
        text = install.text_of(p)
        self.assertIn('F-1.15 is older than the F-1.21 on the meter', text)
        for later in ('F-1.16', 'F-1.17', 'F-1.18', 'F-1.19', 'F-1.21'):          # introduced after F-1.15, up to the meter's
            self.assertIn(later + ':', text)
        for not_between in ('F-1.15:', 'F-1.12:', 'F-1.22:', 'F-1.04:'):           # the target's own, older ones, newer than the meter
            self.assertNotIn(not_between, text)
        self.assertIn('careful mode', text)
        self.assertIn('CHIrP', text)
        self.assertIn('ignores the stored value', text)
        self.assertIn('data EEPROM', text)

    def test_downgrade_far_back_names_the_bootloader_question_and_the_card(self):
        text = install.text_of(install.make_plan('firmware', facts(fw='F-1.21'), release=entry('firmware', 'F-1.02'), newest=(1, 2, 2)))
        self.assertIn('F-1.03:', text)
        self.assertIn('SD card', text)
        self.assertIn('F-1.04:', text)
        self.assertIn('exFAT', text)
        self.assertIn('F-1.12:', text)

    def test_unknown_firmware_version_asks_unless_it_is_the_newest(self):
        f = facts(fw='F-1.21')
        f['fw'] = None                                                   # EEVblog's v2.05, or the meter in its update mode
        old = install.make_plan('firmware', f, release=entry('firmware', 'F-1.19'), newest=(1, 2, 2))
        self.assertEqual((old['relation'], old['needs_confirm']), ('unknown', True))
        self.assertIn('does not know which firmware', install.text_of(old))
        newest = install.make_plan('firmware', f, release=entry('firmware', 'F-1.22'), newest=(1, 2, 2))
        self.assertFalse(newest['needs_confirm'])

    def test_bootloader_downgrade_needs_confirmation(self):
        p = install.make_plan('bootloader', facts(bl='B-1.13'), release=entry('bootloader', 'B-1.11'), newest=(1, 1, 3))
        self.assertEqual((p['relation'], p['needs_confirm'], p['refusal']), ('older', True, None))
        text = install.text_of(p)
        self.assertIn('B-1.12:', text)
        self.assertIn('B-1.13:', text)
        self.assertNotIn('B-1.11:', text)
        self.assertIn('puts the previous bootloader back', text)
        up = install.make_plan('bootloader', facts(bl='B-1.11'), release=entry('bootloader', 'B-1.13'), newest=(1, 1, 3))
        self.assertFalse(up['needs_confirm'])

    def test_first_install_of_an_older_bootloader_release_asks(self):
        p = install.make_plan('bootloader', facts(bl='EEV'), release=entry('bootloader', 'B-1.12'), newest=(1, 1, 3))
        self.assertEqual((p['needs_confirm'], p['refusal']), (True, None))
        self.assertIn('starter', install.text_of(p))
        self.assertFalse(install.make_plan('bootloader', facts(bl='EEV'), release=entry('bootloader', 'B-1.13'),
                                           newest=(1, 1, 3))['needs_confirm'])

    def test_bootloader_safety_rule(self):
        good = {'name': 'my.bin', 'size': 2000, 'sha256': '0' * 64}
        # a file of your own never goes to EEVblog's bootloader (the starter is written once and never again)
        p = install.make_plan('bootloader', facts(bl='EEV'), custom=good)
        self.assertIn('starter', p['refusal'])
        self.assertFalse(p['needs_confirm'])
        # nor to a meter that does not say which bootloader it has
        self.assertIn('does not say', install.make_plan('bootloader', facts(bl=None), custom=good)['refusal'])
        self.assertIn('does not say', install.make_plan('bootloader', facts(bl=None), release=entry('bootloader', 'B-1.13'))['refusal'])
        # the first install needs firmware F-1.03 or newer
        old = install.make_plan('bootloader', facts(fw='F-1.02', bl='EEV'), release=entry('bootloader', 'B-1.13'), newest=(1, 1, 3))
        self.assertIn('F-1.03', old['refusal'])
        # with the two-part bootloader the file is allowed, with the typed confirmation
        ok = install.make_plan('bootloader', facts(bl='B-1.13'), custom=good)
        self.assertEqual((ok['refusal'], ok['needs_confirm']), (None, True))
        self.assertIn('vector table of the two-part bootloader', install.text_of(ok))
        self.assertIn('previous one back', install.text_of(ok))
        # also while the meter is in its update mode (the bootloader answered)
        self.assertIsNone(install.make_plan('bootloader', facts(bl='B-1.12', mode='bootloader'), custom=good)['refusal'])

    def test_custom_firmware_always_asks_and_the_bootloader_limit_applies(self):
        p = install.make_plan('firmware', facts(), custom={'name': 'x.bin', 'size': 1000, 'sha256': '0' * 64})
        self.assertEqual((p['custom'], p['needs_confirm'], p['refusal']), (True, True, None))
        self.assertIn('file of your own', install.text_of(p))
        self.assertIn('SD card route stays', install.text_of(p))
        big = {'name': 'x.bin', 'size': install.BL_FW_MAX + 1, 'sha256': '0' * 64}
        self.assertIn('at most 311296', install.make_plan('firmware', facts(), custom=big)['refusal'])
        self.assertIsNone(install.make_plan('firmware', facts(bl='EEV'), custom=big)['refusal'])      # the card route: up to 0x5A000

    def test_argument_errors(self):
        with self.assertRaises(ValueError):
            install.make_plan('both', facts(), release=entry('firmware', 'F-1.21'))
        with self.assertRaises(ValueError):
            install.make_plan('firmware', facts())


class Install(AppCase):
    """The commands through the program with the transfer steps recorded."""

    def setUp(self):
        super().setUp()
        releases.forget()
        old = releases._fetch
        releases._fetch = lambda: API
        self.addCleanup(setattr, releases, '_fetch', old)
        self.addCleanup(releases.forget)
        self.app.version, self.app.bl = 'F-1.21', 'B-1.13'
        self.calls = []
        a = self.app
        a._enter_update_mode = lambda: self.calls.append(('enter',))
        a._boot_send = lambda data, kind, version, text: self.calls.append(('send', data, kind, version, text))
        a._wait_restart = lambda ready, failure, what, timeout=90.0, poll=None: self.calls.append(('wait', ready, failure, what))
        self.images = {}
        old_image, old_files = releases.image, releases.bootloader_files
        releases.image = lambda tag: self.images[tag]
        releases.bootloader_files = lambda tag: self.images[tag]
        self.addCleanup(setattr, releases, 'image', old_image)
        self.addCleanup(setattr, releases, 'bootloader_files', old_files)

    def done(self):
        self.assertTrue(wait(lambda: self.app.update['state'] in ('done', 'error') and not self.app._picks), 'update did not end')
        return self.app.update

    def test_release_list_marks_what_is_older(self):
        j = self.app.command({'release_list': True})
        rel = {e['text']: e['relation'] for e in j['firmware']}
        self.assertEqual(rel, {'F-1.22': 'newer', 'F-1.21': 'same', 'F-1.19': 'older', 'F-1.15': 'older', 'F-1.02': 'older', 'F-0.99': 'older'})
        self.assertEqual({e['text']: e['relation'] for e in j['bootloader']}, {'B-1.13': 'same', 'B-1.12': 'older', 'B-1.11': 'older'})
        self.assertEqual(j['meter'], {'firmware': 'F-1.21', 'bootloader': 'B-1.13', 'mode': 'firmware'})
        self.assertFalse(any('needs_meter' in e for e in j['firmware'] + j['bootloader']))

    def test_release_list_without_a_meter_asks_for_it(self):
        # the page labels these "connect the meter" (needs_meter), not "refused"
        self.app.link.state = 'idle'
        j = self.app.command({'release_list': True})
        self.assertTrue(all(e.get('needs_meter') for e in j['firmware'] + j['bootloader']))

    def test_downgrade_is_refused_without_the_typed_word(self):
        self.images['v1.1.9'] = fw_image()
        for confirm in (None, True, 'yes', 'install', ''):
            c = {'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.1.9'}
            if confirm is not None:
                c['confirm'] = confirm
            with self.assertRaises(ValueError, msg=repr(confirm)):
                self.app.command(c)
        self.assertEqual(self.calls, [])
        self.assertEqual(self.app.update['state'], 'none')

    def test_downgrade_with_the_word_goes_through_the_update_transfer(self):
        self.images['v1.1.9'] = data = fw_image()
        plan = self.app.command({'install_plan': True, 'kind': 'firmware', 'tag': 'v1.1.9'})['plan']
        self.assertTrue(plan['needs_confirm'])
        self.assertIn('F-1.19 is older than the F-1.21', plan['warnings'][0])
        self.app.command({'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.1.9', 'confirm': install.CONFIRM_WORD})
        u = self.done()
        self.assertEqual((u['state'], u['picked']), ('done', 'F-1.19'))
        self.assertEqual([c[0] for c in self.calls], ['enter', 'send', 'wait'])
        self.assertEqual(self.calls[1][1:], (data, transfer.KIND_FIRMWARE, None, 'F-1.19'))
        ready = self.calls[2][1]
        self.app.mode, self.app.version = 'bootloader', None
        self.assertFalse(ready())
        self.app.mode, self.app.version = 'firmware', 'F-1.21'                  # the old firmware is not the one asked for
        self.assertFalse(ready())
        self.app.version = 'F-1.19'
        self.assertTrue(ready())

    def test_upgrade_needs_no_word(self):
        self.images['v1.2.2'] = fw_image()
        self.app.command({'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.2.2'})
        self.assertEqual(self.done()['state'], 'done')
        self.assertEqual(self.calls[1][4], 'F-1.22')

    def test_unknown_release_and_busy_states(self):
        with self.assertRaises(ValueError):
            self.app.command({'install_plan': True, 'kind': 'firmware', 'tag': 'v7.7.7'})
        with self.assertRaises(ValueError):
            self.app.command({'install_plan': True, 'kind': 'both', 'tag': 'v1.1.9'})
        self.app.update['state'] = 'sending'
        with self.assertRaises(RuntimeError):
            self.app.command({'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.2.2'})
        self.app.update['state'] = 'none'
        self.app.link.state = 'idle'
        with self.assertRaises(RuntimeError):
            self.app.command({'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.2.2'})
        self.assertEqual(self.calls, [])

    def test_firmware_over_the_bootloader_limit_stops_before_the_restart(self):
        self.images['v1.2.2'] = fw_image(size=install.BL_FW_MAX + 4)
        self.app.command({'install_chosen': True, 'kind': 'firmware', 'tag': 'v1.2.2'})
        u = self.done()
        self.assertEqual(u['state'], 'error')
        self.assertIn('at most %d' % install.BL_FW_MAX, u['message'])
        self.assertEqual(self.calls, [])                                     # the meter was not restarted into its update mode

    def test_file_of_your_own_as_firmware(self):
        data = fw_image(size=5000)
        r = self.app.stage_file('firmware', '/some/folder/my fw.bin', data)
        self.assertEqual(r['staged']['name'], 'my fw.bin')                    # the name only, no folders
        self.assertEqual(self.app.state()['staged'], r['staged'])
        self.assertNotIn('data', r['staged'])
        with self.assertRaises(ValueError):
            self.app.command({'install_chosen': True, 'kind': 'firmware', 'staged': True})
        with self.assertRaises(ValueError):
            self.app.command({'install_chosen': True, 'kind': 'bootloader', 'staged': True, 'confirm': install.CONFIRM_WORD})
        self.assertEqual(self.calls, [])
        self.app.command({'install_chosen': True, 'kind': 'firmware', 'staged': True, 'confirm': install.CONFIRM_WORD})
        u = self.done()
        self.assertEqual((u['state'], u['picked']), ('done', 'my fw.bin'))
        self.assertEqual(self.calls[1][1:], (data, transfer.KIND_FIRMWARE, None, 'my fw.bin'))   # exactly the checked bytes
        ready = self.calls[2][1]
        self.app.mode, self.app.version = 'firmware', 'F-9.99'                # the version of a file is not known: any firmware
        self.assertTrue(ready())
        self.app.mode = 'bootloader'
        self.assertFalse(ready())

    def test_bad_files_are_refused_with_the_reason_and_never_kept(self):
        self.app.stage_file('firmware', 'good.bin', fw_image())
        bad = [('firmware', fw_image(size=100), 'size'), ('firmware', b'', 'empty'),
               ('firmware', fw_image(sp=0x10000000), 'stack pointer'), ('firmware', fw_image(reset=0x08006100), 'reset vector'),
               ('firmware', fw_image(reset=0x08001001), 'reset vector'), ('firmware', bl_image(), 'reset vector'),
               ('bootloader', fw_image(size=2000), 'stack pointer'), ('bootloader', bl_image(sp=0x20002000), 'stack pointer'),
               ('bootloader', bl_image(size=24576), 'size'), ('firmware', bytes(0x5A001), 'at most')]
        for kind, data, why in bad:
            with self.assertRaises(ValueError, msg=why) as cm:
                self.app.stage_file(kind, 'bad.bin', data)
            self.assertIn(why, str(cm.exception))
            self.assertIn('bad.bin', str(cm.exception))
            self.assertIsNone(self.app.staged, why)                            # a refused file replaces the earlier one
            self.app.stage_file('firmware', 'good.bin', fw_image())
        with self.assertRaises(ValueError):
            self.app.stage_file('both', 'x.bin', fw_image())

    def test_first_install_file_is_named_as_such(self):
        starter = struct.pack('<II', 0x20002000, 0x08000201) + bytes(0x400 - 8)
        header = struct.pack('<4I', 0x32484C42, 2000, 0, 0x00010103)
        header += struct.pack('<I', 0) + bytes(0x100 - 20)
        inst = starter + header + bl_image()
        inst += bytes(-len(inst) % 128)
        self.assertIsNone(releases.check_install(inst))
        with self.assertRaises(ValueError) as cm:
            self.app.stage_file('bootloader', 'install.bin', inst)
        self.assertIn('first-install file', str(cm.exception))

    def test_bootloader_file_of_your_own(self):
        data = bl_image(size=3000)
        self.app.stage_file('bootloader', 'bl.bin', data)
        with self.assertRaises(ValueError):                                    # not without the word
            self.app.command({'install_chosen': True, 'kind': 'bootloader', 'staged': True})
        self.app.command({'install_chosen': True, 'kind': 'bootloader', 'staged': True, 'confirm': install.CONFIRM_WORD})
        u = self.done()
        self.assertEqual(u['state'], 'done')
        self.assertEqual(self.calls[1][1:], (data, transfer.KIND_BOOTLOADER, None, 'bl.bin'))     # version word 0 (none sent)
        ready = self.calls[2][1]
        self.app.mode = 'bootloader'
        self.assertFalse(ready())
        self.app.mode = 'firmware'
        self.assertTrue(ready())

    def test_bootloader_file_refused_on_eevblogs_bootloader(self):
        self.app.bl = 'EEV'
        self.app.stage_file('bootloader', 'bl.bin', bl_image())
        with self.assertRaises(ValueError) as cm:
            self.app.command({'install_chosen': True, 'kind': 'bootloader', 'staged': True, 'confirm': install.CONFIRM_WORD})
        self.assertIn('starter', str(cm.exception))
        self.assertEqual(self.calls, [])
        self.assertEqual(self.app.update['state'], 'none')

    def test_bootloader_release_downgrade(self):
        self.images['bl-v1.1.1'] = (b'install', bl_image())
        with self.assertRaises(ValueError):
            self.app.command({'install_chosen': True, 'kind': 'bootloader', 'tag': 'bl-v1.1.1'})
        self.app.command({'install_chosen': True, 'kind': 'bootloader', 'tag': 'bl-v1.1.1', 'confirm': install.CONFIRM_WORD})
        self.assertEqual(self.done()['state'], 'done')
        self.assertEqual(self.app._picks, {})
        self.assertEqual(self.calls[1][1:], (self.images['bl-v1.1.1'][1], transfer.KIND_BOOTLOADER, 0x00010101, 'B-1.11'))
        self.app.bl = 'B-1.11'
        self.assertTrue(self.calls[2][1]())
        self.app.bl = 'B-1.13'
        self.assertFalse(self.calls[2][1]())

    def test_the_normal_update_is_unchanged(self):
        self.images['v1.2.2'] = fw_image()
        self.app.update.update(state='available', fw=('F-1.22', 'v1.2.2'), bl=None)
        self.app.command({'update_now': 'firmware'})
        u = self.done()
        self.assertEqual((u['state'], u['picked']), ('done', ''))
        self.assertEqual(self.calls[1][1:], (self.images['v1.2.2'], transfer.KIND_FIRMWARE, None, 'F-1.22'))


class Notice(AppCase):
    def setUp(self):
        super().setUp()
        releases.forget()
        old = releases._fetch
        releases._fetch = lambda: API
        self.addCleanup(setattr, releases, '_fetch', old)
        self.addCleanup(releases.forget)
        self.version = '1.2.24'
        old_v = app_mod.report.app_version
        app_mod.report.app_version = lambda: self.version
        self.addCleanup(setattr, app_mod.report, 'app_version', old_v)
        self.app.version, self.app.bl = 'F-1.22', 'B-1.13'

    def test_newer_release_of_the_program_is_noticed_with_a_link(self):
        self.app._check_release()
        n = self.app.update['companion']
        self.assertEqual(n, {'text': '1.2.25', 'tag': 'companion-v1.2.25',
                             'url': 'https://github.com/%s/releases/tag/companion-v1.2.25' % releases.REPO})
        self.assertEqual(self.app.state()['companion'], {'version': '1.2.24', 'newer': n})

    def test_no_notice_when_up_to_date_newer_or_run_from_source(self):
        for version in ('1.2.25', '1.3.0', 'source', 'unknown', 'dev'):
            self.version = version
            self.app._check_release()
            self.assertIsNone(self.app.update['companion'], version)
            self.assertEqual(self.app.state()['companion'], {'version': version, 'newer': None})

    def test_ten_is_newer_than_nine(self):
        self.version = '1.2.9'
        self.app._check_release()
        self.assertEqual(self.app.update['companion']['text'], '1.2.25')

    def test_check_off_clears_the_notice(self):
        self.app._check_release()
        self.app.settings['update_check'] = 'never'
        self.app._check_release()
        self.assertIsNone(self.app.update['companion'])

    def test_open_release_page_opens_only_the_known_address(self):
        opened = []
        old = app_mod.webbrowser.open
        app_mod.webbrowser.open = opened.append
        self.addCleanup(setattr, app_mod.webbrowser, 'open', old)
        with self.assertRaises(ValueError):
            self.app.command({'open_release_page': True, 'url': 'https://example.com/'})
        self.assertEqual(opened, [])
        self.app._check_release()
        r = self.app.command({'open_release_page': True, 'url': 'https://example.com/'})
        self.assertEqual(opened, [r['url']])
        self.assertTrue(r['url'].endswith('/releases/tag/companion-v1.2.25'))


class Upload(AppCase):
    def start(self):
        self.app._frame_t = 1e12                         # the desk watcher stays quiet
        httpd = server.serve(self.app, 0)
        self.addCleanup(httpd.server_close)
        self.addCleanup(httpd.shutdown)
        self.port = httpd.server_address[1]

    def post(self, query, body, headers=None, length=None):
        c = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        c.putrequest('POST', '/upload' + query)
        for k, v in (headers if headers is not None else {server.HEADER: '1'}).items():
            c.putheader(k, v)
        if length is not False:
            c.putheader('Content-Length', str(len(body) if length is None else length))
        c.endheaders()
        c.send(body)
        r = c.getresponse()
        try:
            return r.status, json.loads(r.read())
        finally:
            c.close()

    def test_upload_checks_and_keeps_a_good_file(self):
        self.start()
        data = fw_image(size=3000)
        code, body = self.post('?kind=firmware&name=my%20fw.bin', data)
        self.assertEqual(code, 200)
        self.assertEqual((body['staged']['name'], body['staged']['size'], body['staged']['kind']), ('my fw.bin', 3000, 'firmware'))
        self.assertEqual(self.app.staged['data'], data)

    def test_upload_refuses_a_bad_file_with_the_reason(self):
        self.start()
        code, body = self.post('?kind=firmware&name=bad.bin', fw_image(reset=0x08001001))
        self.assertEqual(code, 400)
        self.assertIn('reset vector', body['error'])
        self.assertIsNone(self.app.staged)
        code, body = self.post('?kind=bootloader&name=fw.bin', fw_image(size=2000))
        self.assertEqual(code, 400)
        self.assertIn('stack pointer', body['error'])

    def test_upload_needs_the_header_a_length_and_a_size_within_the_limit(self):
        self.start()
        self.assertEqual(self.post('?kind=firmware&name=a.bin', fw_image(), headers={})[0], 403)
        self.assertEqual(self.post('?kind=firmware&name=a.bin', b'', length=False)[0], 400)
        code, body = self.post('?kind=firmware&name=a.bin', b'', length=server.UPLOAD_MAX + 1)
        self.assertEqual(code, 413)
        self.assertIsNone(self.app.staged)


if __name__ == '__main__':
    unittest.main()
