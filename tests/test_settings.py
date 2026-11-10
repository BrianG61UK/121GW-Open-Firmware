"""Settings of the meter: the table, the range checks, get / put over the fake meter (read-modify-write of shared bytes)."""
import unittest
from unittest import mock

from support import RANGES, FakeMeter, card, make_client, settings


def meter(**eeprom):
    e = {s.wire: 0 for s in settings.TABLE}
    e[0x01A] = 14
    e[0x022] = 1
    e[0x02A] = 100
    e.update({int(k[1:], 16): v for k, v in eeprom.items()})
    return FakeMeter(eeprom=e)


class Table(unittest.TestCase):
    def test_ids_codes_and_ranges(self):
        self.assertEqual(len({s.id for s in settings.TABLE}), len(settings.TABLE))
        codes = [s.code for s in settings.TABLE]
        for c in ('bL', 'bt', 'rEL', 'tc', 'dSP', 'bH', 'LP', 'Pt', 'CL', 'BAT', 'tr', 'Ch', 'HUnt'):
            self.assertIn(c, codes)
        for s in settings.TABLE:
            self.assertLessEqual(s.min, s.max)
            if s.choices:
                self.assertEqual((s.min, s.max), (0, len(s.choices) - 1), s.code)
            self.assertLessEqual((s.mask << s.shift), 0xFF, s.code)
        # bftset.s: 21 ids; 0x020 is one id shown as four rows (ids 0x120, 0x220, 0x320, 0x420); 0x018 is not offered
        self.assertEqual(sorted(s.wire for s in settings.TABLE),
                         sorted([0x00F, 0x010, 0x011, 0x013, 0x014, 0x015, 0x016, 0x017, 0x01A, 0x01B, 0x01E, 0x020, 0x020,
                                 0x020, 0x020, 0x021, 0x022, 0x028, 0x029, 0x02A, 0x02B, 0x02C, 0x02D, 0x02F]))
        self.assertEqual({s.wire for s in settings.TABLE if s.wide}, {0x02D})
        self.assertEqual({s.id for s in settings.TABLE if s.wire == 0x020}, {0x120, 0x220, 0x320, 0x420})
        self.assertEqual({r: (s.min, s.max) for r, s in ((s.wire, s) for s in settings.TABLE if s.wire != 0x020)},
                         {r: v for r, v in RANGES.items() if r != 0x020})

    def test_values_of_the_documented_ranges(self):
        by = {s.code: s for s in settings.TABLE}
        self.assertEqual((by['tc'].min, by['tc'].max), (0, 5))             # K J T N R S
        self.assertEqual((by['bL'].min, by['bL'].max), (0, 100))           # off, 30 s, 1..99 min
        self.assertEqual((by['Ch'].min, by['Ch'].max), (1, 255))
        self.assertEqual((by['BAT'].min, by['BAT'].max), (50, 150))
        self.assertEqual((by['tr'].min, by['tr'].max), (0, 2))             # 3 is refused by the meter: not offered
        self.assertEqual((by['HUnt'].choices, by['HUnt'].shift, by['HUnt'].mask, by['HUnt'].wire),
                         (['off', 'on'], 4, 1, 0x020))                       # bit 4 of the shared byte
        self.assertEqual((by['item 4'].min, by['item 4'].max), (10, 17))   # LCD contrast

    def test_range_checks(self):
        for code, ok, bad in (('tc', (0, 5), (-1, 6, 255)), ('bL', (0, 1, 100), (101, -1)), ('Ch', (1, 255), (0, 256)),
                              ('BAT', (50, 100, 150), (49, 151, 0)), ('Pt', (0, 2), (3,)), ('tr', (0, 2), (3,)),
                              ('CL', (0, 1), (2,)), ('rEL', (0, 1), (2,)), ('HUnt', (0, 1), (2,)), ('item 4', (10, 17), (9, 18)),
                              ('item 10', (0, 17), (18,)), ('th', (1, 250, 500), (0, 501)), ('HY', (1, 250), (0, 251))):
            sid = next(s.id for s in settings.TABLE if s.code == code)
            for v in ok:
                self.assertEqual(settings.check(sid, v)[1], v)
            for v in bad:
                with self.assertRaises(ValueError, msg='%s %d' % (code, v)):
                    settings.check(sid, v)

    def test_user_continuity_settings(self):
        m = FakeMeter(eeprom={0x014: 0, 0x02D: 30, 0x02F: 50, 0x02C: 0})
        s = settings.Settings(make_client(m))
        by = {i['code']: i for i in s.get_all()}
        self.assertEqual((by['th']['value'], by['th']['text']), (30, '30 ohm'))
        self.assertEqual((by['HY']['value'], by['HY']['text']), (50, '5.0 ohm'))
        by = {i['code']: i for i in s.put(0x02D, 499)}                     # the two-byte PUT
        self.assertEqual((by['th']['value'], m.eeprom[0x02D]), (499, 499))
        s.put(0x02F, 7)
        s.put(0x014, 17)
        self.assertEqual((m.eeprom[0x02F], m.eeprom[0x014], m.eeprom[0x02C]), (7, 17, 0))

    def test_user_continuity_on_older_firmware(self):
        m = FakeMeter(eeprom={0x014: 3, 0x02C: 0})
        m.user_cont_fw = False
        s = settings.Settings(make_client(m), user_cont=False)
        codes = [i['code'] for i in s.get_all()]
        self.assertNotIn('th', codes)
        self.assertNotIn('HY', codes)
        with self.assertRaises(ValueError):
            s.put(0x014, 16)                                                # F-1.33 only
        with self.assertRaises(ValueError):
            s.put(0x02D, 100)
        self.assertEqual(m.eeprom, {0x014: 3, 0x02C: 0})

    def test_wide_setting_is_refused_in_the_one_byte_forms(self):
        m = FakeMeter(eeprom={0x02D: 30, 0x02F: 50})
        c = make_client(m)
        field, data = c.ok(settings.T_GET)
        self.assertEqual(settings.parse_get(field, data), [(0x02F, 50)])    # the old form: no two-byte setting
        self.assertEqual(c.request(settings.T_PUT, settings.put_request(0x02D, 40))[0], card.ST_ARG)

    def test_page_tags_and_value_texts(self):
        # GitHub issue 35: no row named "item N" on the page, every value in words as the meter shows it
        by = {s.code: s for s in settings.TABLE}
        self.assertEqual([settings.tag(s) for s in settings.TABLE if s.code.startswith('item ')],
                         ['page 0', 'page 10', 'page 2', 'page 4', 'page 11', 'page 3'])
        self.assertEqual(settings.texts(by['item 10'])[:4] + settings.texts(by['item 10'])[16:], ['DN 30', 'UP 30', 'DN300', 'UP300', 'DNUSr', 'UPUSr'])
        self.assertEqual(settings.texts(by['item 4']), ['Lcd-%d' % n for n in range(8)])     # the meter's page 4: "Lcd-n"
        self.assertEqual(settings.texts(by['bL'])[:3] + settings.texts(by['bL'])[-1:], ['off', '30 s', '1 min', '99 min'])
        self.assertEqual(settings.texts(by['BAT'])[0], '-10.0 %')
        for code, unit, scale in (('Ch', '', 1), ('th', 'ohm', 1), ('HY', 'ohm', 0.1)):
            it = settings.item(by[code], by[code].min)
            self.assertEqual((it['texts'], it['unit'], it['scale']), (None, unit, scale), code)
        for s in settings.TABLE:
            t = settings.texts(s)
            self.assertTrue(t is None or len(t) == s.max - s.min + 1, s.code)
        old = settings.Settings(None, user_cont=False).rows()
        self.assertEqual(len(settings.texts(next(s for s in old if s.id == 0x014))), 16)    # older firmware: 0..15

    def test_unknown_ids_and_types_are_refused(self):
        for sid in (0x018, 0x008, 0x003, 0x030, 0x020, 0x2E0, -1, None, 'tc', [1], 1.5, True):
            with self.assertRaises(ValueError, msg=repr(sid)):
                settings.check(sid, 0)
        for v in (None, '1', 1.0, True, [1]):
            with self.assertRaises(ValueError, msg=repr(v)):
                settings.check(0x00F, v)

    def test_texts(self):
        by = {s.code: s for s in settings.TABLE}
        self.assertEqual(settings.text(by['bL'], 0), 'off')
        self.assertEqual(settings.text(by['bL'], 1), '30 s')
        self.assertEqual(settings.text(by['bL'], 2), '1 min')
        self.assertEqual(settings.text(by['bL'], 100), '99 min')
        self.assertEqual(settings.text(by['BAT'], 100), '+0.0 %')
        self.assertEqual(settings.text(by['BAT'], 150), '+10.0 %')
        self.assertEqual(settings.text(by['tc'], 3), 'N')
        self.assertEqual(settings.text(by['tc'], 255), 'invalid (255)')


class OverTheLink(unittest.TestCase):
    def setUp(self):
        p = mock.patch.dict(card.TIMEOUTS, {k: 0.05 for k in card.TIMEOUTS})
        p.start()
        self.addCleanup(p.stop)

    def test_get_all_lists_known_ids_only(self):
        m = meter()
        m.eeprom[0x030] = 7                             # a byte the table does not have: dropped
        items = settings.Settings(make_client(m)).get_all()
        self.assertEqual([i['code'] for i in items], [s.code for s in settings.TABLE])
        tc = next(i for i in items if i['code'] == 'tc')
        self.assertEqual(tc, {'id': 0x00F, 'code': 'tc', 'tag': 'tc', 'name': 'Thermocouple type (TEMP)', 'value': 0, 'min': 0,
                              'max': 5, 'choices': ['K', 'J', 'T', 'N', 'R', 'S'], 'text': 'K',
                              'texts': ['K', 'J', 'T', 'N', 'R', 'S'], 'unit': None, 'scale': 1})
        self.assertIsNone(next(i for i in items if i['code'] == 'bL')['choices'])

    def test_auto_power_off_time_listed_only_when_reported(self):
        m = meter()
        items = settings.Settings(make_client(m)).get_all()
        apo = next(i for i in items if i['code'] == 'APO')
        self.assertEqual((apo['id'], apo['choices']), (0x02B, ['30 min', '1 min', '15 min', '60 min']))
        items = settings.Settings(make_client(m)).put(0x02B, 2)
        self.assertEqual(m.eeprom[0x02B], 2)
        self.assertEqual(next(i for i in items if i['code'] == 'APO')['text'], '15 min')
        del m.eeprom[0x02B]                             # firmware before F-1.18 does not report the id
        self.assertNotIn('APO', [i['code'] for i in settings.Settings(make_client(m)).get_all()])

    def test_diode_chirp_listed_only_when_reported(self):
        m = meter()
        items = settings.Settings(make_client(m)).get_all()
        row = next(i for i in items if i['code'] == 'CHIrP')
        self.assertEqual((row['id'], row['choices'], row['text']), (0x02C, ['off', 'on'], 'off'))
        items = settings.Settings(make_client(m)).put(0x02C, 1)
        self.assertEqual(m.eeprom[0x02C], 1)
        self.assertEqual(next(i for i in items if i['code'] == 'CHIrP')['text'], 'on')
        del m.eeprom[0x02C]                             # firmware before F-1.21 does not report the id
        self.assertNotIn('CHIrP', [i['code'] for i in settings.Settings(make_client(m)).get_all()])

    def test_put_changes_one_value_and_reads_it_back(self):
        m = meter()
        items = settings.Settings(make_client(m)).put(0x00F, 4)
        self.assertEqual(m.eeprom[0x00F], 4)
        self.assertEqual(next(i for i in items if i['code'] == 'tc')['text'], 'R')
        self.assertEqual([t for t, _ in m.sent].count(settings.T_PUT), 1)

    def test_out_of_range_never_reaches_the_meter(self):
        m = meter()
        with self.assertRaises(ValueError):
            settings.Settings(make_client(m)).put(0x00F, 6)
        self.assertEqual(m.sent, [])

    def test_shared_byte_keeps_the_other_fields(self):
        m = meter(b020=0b0100)                          # tr = 2 (bits 2..1), CL 0, rEL 0
        s = settings.Settings(make_client(m))
        s.put(0x320, 1)                                 # CL 12-hour: bit 3
        self.assertEqual(m.eeprom[0x020], 0b1100)
        s.put(0x120, 1)                                 # rEL percent: bit 0
        self.assertEqual(m.eeprom[0x020], 0b1101)
        s.put(0x220, 1)                                 # tr = 1: bits 2..1 = 01
        self.assertEqual(m.eeprom[0x020], 0b1011)
        s.put(0x320, 0)
        self.assertEqual(m.eeprom[0x020], 0b0011)
        puts = [p for t, p in m.sent if t == settings.T_PUT]
        self.assertEqual(puts, [b'\x20\x00\x0c', b'\x20\x00\x0d', b'\x20\x00\x0b', b'\x20\x00\x03'])   # id 0x020, whole value

    def test_anti_hunting_is_bit_4_and_keeps_the_other_fields(self):
        m = meter(b020=0b01101)                         # rEL percent, tr 2... bits 3..0 = 1101: rEL 1, tr 2 (bits 2..1 = 10), CL 1
        s = settings.Settings(make_client(m))
        items = s.get_all()
        self.assertEqual(next(i for i in items if i['code'] == 'HUnt')['text'], 'off')
        s.put(0x420, 1)
        self.assertEqual(m.eeprom[0x020], 0b11101)
        self.assertEqual(next(i for i in s.get_all() if i['code'] == 'HUnt')['text'], 'on')
        s.put(0x120, 0)                                 # another row keeps bit 4
        self.assertEqual(m.eeprom[0x020], 0b11100)
        s.put(0x420, 0)
        self.assertEqual(m.eeprom[0x020], 0b01100)
        puts = [p for t, p in m.sent if t == settings.T_PUT]
        self.assertEqual(puts, [b'\x20\x00\x1d', b'\x20\x00\x1c', b'\x20\x00\x0c'])

    def test_firmware_before_f116_neither_lists_nor_changes_the_row(self):
        m = meter(b020=0b0100)
        s = settings.Settings(make_client(m), hunt=False)
        self.assertNotIn('HUnt', [i['code'] for i in s.get_all()])
        self.assertIn('CL', [i['code'] for i in s.get_all()])
        with self.assertRaises(ValueError):
            s.put(0x420, 1)
        self.assertEqual([t for t, _ in m.sent].count(settings.T_PUT), 0)

    def test_buzzer_quiet_only_for_f124(self):
        # GitHub issue 28: the buzzer's third value qUiEt (2); older firmware refuses it, so it is neither offered nor sent
        m = meter()
        s = settings.Settings(make_client(m))
        row = next(r for r in s.rows() if r.id == 0x01E)
        self.assertEqual((row.max, row.choices[2]), (2, 'quiet (keys silent)'))
        s.put(0x01E, 2)
        self.assertEqual(m.eeprom[0x01E], 2)
        self.assertEqual(next(i for i in s.get_all() if i['code'] == 'item 3')['text'], 'quiet (keys silent)')
        old = settings.Settings(make_client(m), quiet=False)
        row = next(r for r in old.rows() if r.id == 0x01E)
        self.assertEqual((row.max, row.choices), (1, ['off', 'on']))
        puts = [t for t, _ in m.sent].count(settings.T_PUT)
        with self.assertRaises(ValueError) as cm:
            old.put(0x01E, 2)
        self.assertIn('F-1.24', str(cm.exception))
        self.assertEqual([t for t, _ in m.sent].count(settings.T_PUT), puts)   # nothing sent
        old.put(0x01E, 0)
        self.assertEqual(m.eeprom[0x01E], 0)

    def test_paged_get_adapts_to_a_damaging_link(self):
        # GitHub issue 30 / IMP-55: one 68-byte answer never arrived on a BLE112 link; F-1.25 answers GET in pages
        old = settings.GET_PAGE_WAIT
        settings.GET_PAGE_WAIT = 0.2
        self.addCleanup(setattr, settings, 'GET_PAGE_WAIT', old)
        m = meter()
        plain = settings.Settings(make_client(m)).get_all()
        m.get_pages.clear()                             # the plain read was one GET start 0 max 255 flags 1 (F-1.33)
        m.adapt_fw = True
        m.damage_over = 9                               # answers above 3 entries never arrive intact
        s = settings.Settings(make_client(m), paged=True)
        self.assertEqual(s.get_all(), plain)
        self.assertEqual(m.get_pages[0], (0, settings.GET_PAGE_FIRST))
        self.assertTrue(all(mx <= 2 for _, mx in m.get_pages[-3:]))     # settled on pages that arrive
        s.put(0x01E, 0)                                 # PUT reads back through the pages too
        self.assertEqual(m.eeprom[0x01E], 0)

    def test_paged_get_refused_by_older_firmware_is_an_error_not_a_hang(self):
        m = meter()                                     # adapt_fw False: GET with a payload answers 0x22
        m.user_cont_fw = False                          # firmware before F-1.25 has no F-1.33 forms either
        with self.assertRaises(card.CardError):
            settings.Settings(make_client(m), paged=True, user_cont=False).get_all()

    def test_a_value_above_31_in_the_shared_byte_is_not_changed(self):
        m = meter(b020=0x20)                            # bit 5 is no setting: the meter would refuse the whole value
        s = settings.Settings(make_client(m))
        with self.assertRaises(card.CardError):
            s.put(0x420, 1)
        self.assertEqual([t for t, _ in m.sent].count(settings.T_PUT), 0)

    def test_invalid_trigger_must_be_set_first(self):
        m = meter(b020=0b0110)                          # tr = 3: the meter would refuse a PUT carrying it
        s = settings.Settings(make_client(m))
        with self.assertRaises(card.CardError):
            s.put(0x320, 1)
        self.assertEqual([t for t, _ in m.sent].count(settings.T_PUT), 0)
        s.put(0x220, 0)
        self.assertEqual(m.eeprom[0x020], 0)
        self.assertEqual(next(i for i in s.get_all() if i['code'] == 'tr')['text'], 'interval')

    def test_backlight_state_bit_is_kept(self):
        m = meter(b017=5)                               # the value of the page (the meter keeps the remembered state)
        s = settings.Settings(make_client(m))
        items = s.get_all()
        self.assertEqual(next(i for i in items if i['code'] == 'bL')['value'], 5)
        s.put(0x017, 30)
        self.assertEqual(m.eeprom[0x017], 30)
        self.assertEqual([p for t, p in m.sent if t == settings.T_PUT], [b'\x17\x00\x1e'])

    def test_meter_refusals_are_reported(self):
        m = meter()
        m.refuse_put = card.ST_NOT_NOW
        with self.assertRaises(card.CardError) as e:
            settings.Settings(make_client(m)).put(0x015, 2)
        self.assertEqual(e.exception.status, card.ST_NOT_NOW)
        m.logging = True
        m.refuse_put = None
        with self.assertRaises(card.CardError):
            settings.Settings(make_client(m)).put(0x015, 2)

    def test_a_value_the_meter_does_not_keep_is_an_error(self):
        m = meter()
        real = m._handle
        m._handle = lambda t, p: (card.ST_OK, 0x00F, bytes([0])) if t == settings.T_PUT else real(t, p)   # says 0, stores nothing
        with self.assertRaises(card.CardError) as e:
            settings.Settings(make_client(m)).put(0x00F, 3)
        self.assertIn('applied 0 instead of 3', str(e.exception))
        m._handle = lambda t, p: (card.ST_OK, 0x00F, bytes([3])) if t == settings.T_PUT else real(t, p)   # says 3, stores nothing
        with self.assertRaises(card.CardError) as e:
            settings.Settings(make_client(m)).put(0x00F, 3)
        self.assertIn('did not keep', str(e.exception))

    def test_id_the_meter_does_not_report(self):
        m = meter()
        del m.eeprom[0x00F]
        with self.assertRaises(card.CardError):
            settings.Settings(make_client(m)).put(0x00F, 1)

    def test_layout_helpers(self):
        pairs = [(0x15, 2), (0x28, 1), (0x2A, 100)]
        field, data = settings.get_answer(pairs)
        self.assertEqual((field, data), (3, b'\x15\x00\x02\x28\x00\x01\x2a\x00\x64'))
        self.assertEqual(settings.parse_get(field, data), pairs)
        self.assertEqual(settings.put_request(0x0120, 7), b'\x20\x01\x07')
        self.assertEqual(settings.parse_put(0x17, 0x17, b'\x05'), 5)
        for bad in ((0x17, b''), (0x18, b'\x05'), (0x17, b'\x05\x06')):
            with self.assertRaises(card.CardError):
                settings.parse_put(0x17, *bad)
        with self.assertRaises(card.CardError):
            settings.parse_get(2, b'\x01\x00\x00')


if __name__ == '__main__':
    unittest.main()
