"""Card list / download / delete / info and the sync, against a fake meter that implements the protocol in Python."""
import json
import os
import struct
import zlib
import shutil
import tempfile
import unittest
from unittest import mock

def slurp(path):
    with open(path, 'rb') as f:
        return f.read()


from support import FakeMeter, card, make_client, sample_files, fat_date, fat_time


class CardCase(unittest.TestCase):
    def setUp(self):
        self.meter = FakeMeter(sample_files())
        self.card = card.Card(make_client(self.meter))
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # lost answers must not take the real timeouts
        p = mock.patch.dict(card.TIMEOUTS, {k: 0.05 for k in card.TIMEOUTS})
        p.start()
        self.addCleanup(p.stop)

    def count(self, rtype):
        return sum(1 for t, _ in self.meter.sent if t == rtype)


class ListInfo(CardCase):
    def test_all_pages(self):
        files = self.card.list()
        self.assertEqual([f['name'] for f in files], sorted(sample_files()))
        self.assertEqual(self.count(card.T_LIST), 2)                    # 5 files, 3 per page
        f = {x['name']: x for x in files}
        self.assertEqual(f['LOG0002.CSV'], {'name': 'LOG0002.CSV', 'size': 20000, 'date': '2026-11-04', 'time': '08:05:00'})
        self.assertEqual(f['cal.bin']['time'], '01:02:04')

    def test_info(self):
        self.assertEqual(self.card.info(), {'free_bytes': 1_000_000 * 64 * 512, 'total_bytes': 100_000_000 * 64 * 512})

    def test_list_must_advance(self):
        with mock.patch.object(card, 'parse_list', return_value=([], False)):
            with self.assertRaises(card.CardError):
                self.card.list()

    def test_fat_words(self):
        self.assertEqual(card.fat_date(0), '')                          # no date stored
        self.assertEqual(card.fat_date(fat_date(2026, 12, 31)), '2026-12-31')
        self.assertEqual(card.fat_time(fat_time(23, 59, 58)), '23:59:58')

    def test_layout_of_list_info_and_card_error(self):
        field, data = card.list_answer([('a b-1.txt', 5, 0x1234, 0x5678, 0x20, False), ('L' * 63, 1, 2, 3, 0x10, True)], True)
        self.assertEqual(field, 0x8002)
        self.assertEqual(data[:10], bytes([5, 0, 0, 0, 0x34, 0x12, 0x78, 0x56, 0x20, 9]))
        self.assertEqual(card.parse_list(field, data)[0][1], ('L' * 63, 1, 2, 3, 0x10, True))      # bit 7 of attr = cut
        self.assertEqual(card.parse_list(field, data)[1], True)
        with self.assertRaises(card.CardError):
            card.parse_list(0x0001, data[:12])
        self.assertEqual(card.describe(card.ST_CARD, 3 << 8 | 13), 'card error (step read, FatFs result 13)')
        self.assertEqual(card.parse_info(64, bytes(8)), (0, 0))
        with self.assertRaises(card.CardError):
            card.parse_info(0, bytes(8))

    def test_directories_and_cut_names_are_not_files(self):
        self.meter.files['SUBDIR'] = (b'', 0, 0, 0x10)
        self.meter.files['L' * 70] = (b'x', 0, 0)
        names = [e['name'] for e in self.card.list_entries()]
        self.assertIn('SUBDIR', names)
        self.assertIn('L' * 63, names)                                  # the cut name
        self.assertEqual(sorted(f['name'] for f in self.card.list()), sorted(sample_files()))
        r = self.card.sync(self.tmp)
        self.assertEqual(sorted(r['skipped']), ['L' * 63, 'SUBDIR'])

    def test_long_names_split_the_pages_by_bytes(self):
        self.meter.page = 100
        self.meter.files = {('%02d' % i + 'x' * 50 + '.txt'): (b'', 0, 0) for i in range(12)}      # 10 + 57 bytes each
        entries = self.card.list_entries()
        self.assertEqual(len(entries), 12)
        self.assertEqual(self.count(card.T_LIST), 4)                    # 232 // 67 = 3 per answer

    def test_name_rules_of_the_meter(self):
        for bad in ('', 'a..b', ' a', 'a ', 'a.', 'a+b', 'a,b', 'ä', 'x' * 64, 'a/b'):
            with self.assertRaises(card.CardError, msg=bad) as e:
                self.card.delete(bad)
            self.assertEqual(e.exception.status, card.ST_NAME)
        card.check_name('x' * 63)
        card.check_name('My file-1_2.txt')
        self.assertEqual(self.count(card.T_DELETE), 0)

    def test_card_error_status_is_explained(self):
        self.meter._handle = lambda t, p: (card.ST_CARD, 1 << 8 | 7, b'')
        with self.assertRaises(card.CardError) as e:
            self.card.info()
        self.assertEqual((e.exception.status, str(e.exception)), (card.ST_CARD, 'card error (step open, FatFs result 7)'))

    def test_not_allowed_now(self):
        self.meter.logging = True
        with self.assertRaises(card.CardError) as e:
            self.card.list()
        self.assertEqual(e.exception.status, card.ST_NOT_NOW)


class Download(CardCase):
    def test_multi_window_file(self):
        path = self.card.download('LOG0002.CSV', self.tmp, 20000)
        self.assertEqual(slurp(path), sample_files()['LOG0002.CSV'][0])
        self.assertEqual(self.count(card.T_READ), 3)                    # 8192 + 8192 + 3616
        self.assertEqual(self.count(card.T_CHUNK), 36 + 36 + 16)        # ceil(8192/232)=36, ceil(3616/232)=16
        self.assertEqual(os.listdir(self.tmp), ['LOG0002.CSV'])         # no .part left

    def test_size_from_list_and_empty_file(self):
        path = self.card.download('EMPTY.TXT', self.tmp)
        self.assertEqual(os.path.getsize(path), 0)

    def test_wrong_chunk_is_fetched_again(self):
        self.meter.corrupt_chunk_once = True
        path = self.card.download('LOG0001.CSV', self.tmp, 600)
        self.assertEqual(slurp(path), sample_files()['LOG0001.CSV'][0])
        self.assertEqual(self.count(card.T_READ), 1)                    # the chunks were requested again, no new staging
        self.assertEqual(self.count(card.T_CHUNK), 3 + 3)

    def test_persistent_mismatch_restages_then_fails(self):
        real = self.meter._handle

        def bad(rtype, p):
            st, f, data = real(rtype, p)
            return (st, f, data[:-1] + bytes([data[-1] ^ 1])) if rtype == card.T_CHUNK and data else (st, f, data)
        self.meter._handle = bad
        with self.assertRaises(card.CardError) as e:
            self.card.download('LOG0001.CSV', self.tmp, 600)
        self.assertIn('CRC-32', str(e.exception))
        self.assertEqual(self.count(card.T_READ), card.WINDOW_TRIES)
        self.assertEqual(os.listdir(self.tmp), [])                      # neither the file nor a .part

    def test_lost_chunk_answer_is_requested_again(self):
        real_send = self.meter.send
        state = {'n': 0}

        def lossy(pkt):
            if pkt[2] == card.T_CHUNK:
                state['n'] += 1
                if state['n'] == 2:
                    self.meter.drop_next = 1
            real_send(pkt)
        c = card.Card(card.Client(lossy, self.meter.answers))
        path = c.download('LOG0001.CSV', self.tmp, 600)
        self.assertEqual(slurp(path), sample_files()['LOG0001.CSV'][0])

    def test_not_found(self):
        with self.assertRaises(card.CardError) as e:
            self.card.download('NOPE.TXT', self.tmp, 10)
        self.assertEqual(e.exception.status, card.ST_NOT_FOUND)
        self.assertEqual(os.listdir(self.tmp), [])

    def test_file_shorter_than_listed(self):
        with self.assertRaises(card.CardError):
            self.card.download('EMPTY.TXT', self.tmp, 5)

    def test_names_for_the_local_disk(self):
        for bad in ('../x', 'a/b', 'a\\b', 'CON', 'nul.txt', '', 'x.part', card.MANIFEST, 'c:x', 'a ', 'a.'):
            with self.assertRaises(card.CardError, msg=bad):
                self.card.download(bad, self.tmp, 1)


class PackedDownload(CardCase):
    """READZ (firmware F-1.32, IMP-63): windows of 4096, the staged bytes unpacked with zlib, the CRC-32 checked."""
    def setUp(self):
        super().setUp()
        self.meter.readz_fw = True
        self.card = card.Card(make_client(self.meter), packed=True)

    def test_log_file_packed(self):
        path = self.card.download('LOG0002.CSV', self.tmp, 20000)
        self.assertEqual(slurp(path), sample_files()['LOG0002.CSV'][0])
        self.assertEqual(self.count(card.T_READZ), 5)                   # 4 x 4096 + 3616
        self.assertEqual(self.count(card.T_READ), 0)
        self.assertEqual(card.LAST_PACKED['read'], 20000)
        self.assertLess(card.LAST_PACKED['fetched'], 20000)

    def test_incompressible_bytes_come_as_they_are(self):
        import random
        r = random.Random(5)
        noise = bytes(r.randrange(256) for _ in range(3000))
        self.meter.files['NOISE.BIN'] = (noise, fat_date(2026, 11, 9), fat_time(10, 0, 0))
        path = self.card.download('NOISE.BIN', self.tmp, 3000)
        self.assertEqual(slurp(path), noise)
        self.assertEqual(card.LAST_PACKED['fetched'], 3000)

    def test_damaged_stream_is_fetched_again(self):
        self.meter.corrupt_chunk_once = True                            # a wrong byte in the packed stream
        path = self.card.download('LOG0002.CSV', self.tmp, 20000)
        self.assertEqual(slurp(path), sample_files()['LOG0002.CSV'][0])

    def test_answer_forms(self):
        with self.assertRaises(card.CardError):
            card.parse_readz(100, b'\0' * 4)                               # the 4-byte READ answer
        with self.assertRaises(card.CardError):
            card.parse_readz(100, struct.pack('<IHB', 0, 100, 1))         # packed but not shorter
        self.assertEqual(card.parse_readz(100, struct.pack('<IHB', 7, 100, 0)), (100, 7, 100, 0))
        self.assertIsNone(card.unpack_readz(b'\x03\x00', 5, 1))           # an empty stream for 5 bytes
        z = zlib.compressobj(9, zlib.DEFLATED, -15)
        s = z.compress(b'abcabcabc') + z.flush()
        self.assertEqual(card.unpack_readz(s, 9, 1), b'abcabcabc')
        self.assertIsNone(card.unpack_readz(s + b'\0', 9, 1))              # bytes after the stream
        self.assertIsNone(card.unpack_readz(s, 8, 1))                      # one byte more than read


class Delete(CardCase):
    def test_delete(self):
        self.card.delete('LOG0001.CSV')
        self.assertNotIn('LOG0001.CSV', self.meter.files)

    def test_protected_names_never_reach_the_meter(self):
        for name in ('cal.bin', 'CAL.BIN', 'EEVBlog.bin', 'eevblog.BIN', 'BTLOAD.TMP', 'btload.tmp'):
            with self.assertRaises(card.CardError) as e:
                self.card.delete(name)
            self.assertEqual(e.exception.status, card.ST_PROTECTED)
        for name in ('0:cal.bin', '/cal.bin', 'cal.bin ', 'cal.bin.', ' cal.bin', 'a\\cal.bin'):
            with self.assertRaises(card.CardError, msg=name):
                self.card.delete(name)
        self.assertEqual(self.count(card.T_DELETE), 0)
        self.assertIn('cal.bin', self.meter.files)

    def test_lost_answer_then_not_found_counts_as_done(self):
        self.meter.drop_next = 1                      # the first answer is lost after the file was deleted
        self.card.delete('LOG0001.CSV')
        self.assertNotIn('LOG0001.CSV', self.meter.files)
        self.assertEqual(self.count(card.T_DELETE), 2)

    def test_not_found_at_first_send_is_an_error(self):
        with self.assertRaises(card.CardError) as e:
            self.card.delete('NOPE.TXT')
        self.assertEqual(e.exception.status, card.ST_NOT_FOUND)


class Sync(CardCase):
    def read_manifest(self):
        with open(os.path.join(self.tmp, card.MANIFEST), encoding='utf-8') as f:
            return json.load(f)['files']

    def test_first_run_copies_everything_but_the_temporary_file(self):
        self.meter.files['BTLOAD.TMP'] = (b'partial', 0, 0)
        r = self.card.sync(self.tmp)
        self.assertEqual((r['copied'], r['unchanged'], r['skipped']), (5, 0, ['BTLOAD.TMP']))
        for name, (data, _, _) in sample_files().items():
            self.assertEqual(slurp(os.path.join(self.tmp, name)), data)
        self.assertEqual(sorted(self.read_manifest()), sorted(sample_files()))
        self.assertFalse([n for n in os.listdir(self.tmp) if n.endswith('.part')])

    def test_second_run_is_idempotent(self):
        self.card.sync(self.tmp)
        reads = self.count(card.T_READ)
        before = {n: os.stat(os.path.join(self.tmp, n)).st_mtime_ns for n in os.listdir(self.tmp)}
        r = self.card.sync(self.tmp)
        self.assertEqual((r['copied'], r['unchanged']), (0, 5))
        self.assertEqual(self.count(card.T_READ), reads)               # nothing was read from the card
        self.assertEqual(before, {n: os.stat(os.path.join(self.tmp, n)).st_mtime_ns for n in os.listdir(self.tmp)})

    def test_changed_size_or_date_is_copied_alone(self):
        self.card.sync(self.tmp)
        self.meter.files['LOG0001.CSV'] = (b'new content\n', fat_date(2026, 11, 5), fat_time(1, 1, 2))      # size and date
        data, d, t = self.meter.files['cal.bin']
        self.meter.files['cal.bin'] = (data, d, fat_time(1, 2, 6))                                            # time only
        r = self.card.sync(self.tmp)
        self.assertEqual((r['copied'], r['unchanged']), (2, 3))
        self.assertEqual(slurp(os.path.join(self.tmp, 'LOG0001.CSV')), b'new content\n')

    def test_missing_or_short_local_file_is_copied_again(self):
        self.card.sync(self.tmp)
        os.remove(os.path.join(self.tmp, 'LOG0002.CSV'))
        with open(os.path.join(self.tmp, 'cal.bin'), 'wb') as f:
            f.write(b'x')
        self.assertEqual(self.card.sync(self.tmp)['copied'], 2)

    def test_never_deletes_local_files(self):
        self.card.sync(self.tmp)
        extra = os.path.join(self.tmp, 'mine.txt')
        with open(extra, 'w') as f:
            f.write('keep')
        del self.meter.files['LOG0001.CSV']                            # gone from the card
        self.card.sync(self.tmp)
        self.assertTrue(os.path.isfile(extra))
        self.assertTrue(os.path.isfile(os.path.join(self.tmp, 'LOG0001.CSV')))

    def test_interrupted_run_keeps_finished_files_and_resumes(self):
        calls = {'n': 0}
        real = self.meter._handle

        def die(rtype, p):
            if rtype == card.T_READ:
                calls['n'] += 1
                if calls['n'] == 3:
                    return card.ST_CARD, 0x0301, b''
            return real(rtype, p)
        self.meter._handle = die
        with self.assertRaises(card.CardError):
            self.card.sync(self.tmp)
        done = sorted(self.read_manifest())
        self.assertEqual(done, ['EEVBlog.bin', 'EMPTY.TXT', 'LOG0001.CSV'])    # in name order, before the failing third READ
        self.assertFalse([n for n in os.listdir(self.tmp) if n.endswith('.part')])
        self.meter._handle = real
        r = self.card.sync(self.tmp)
        self.assertEqual((r['copied'], r['unchanged']), (2, 3))

    def test_damaged_manifest_means_copy_again_and_delete_nothing(self):
        self.card.sync(self.tmp)
        with open(os.path.join(self.tmp, card.MANIFEST), 'w') as f:
            f.write('{ not json')
        self.assertEqual(self.card.sync(self.tmp)['copied'], 5)

    def test_progress_reaches_total(self):
        seen = []
        self.card.sync(self.tmp, lambda done, total: seen.append((done, total)))
        total = sum(len(d) for n, (d, _, _) in sample_files().items())
        self.assertEqual(seen[-1], (total, total))

    def test_names_of_the_card_that_cannot_be_local_files_are_skipped(self):
        self.meter.files['x.part'] = (b'1', 0, 0)
        self.meter.files['NUL'] = (b'1', 0, 0)
        r = self.card.sync(self.tmp)
        self.assertEqual(sorted(r['skipped']), ['NUL', 'x.part'])
        # no file of that name in the folder (os.path.exists cannot tell: on Windows NUL is a device and always "exists")
        self.assertNotIn('nul', [n.lower() for n in os.listdir(self.tmp)])


if __name__ == '__main__':
    unittest.main()
