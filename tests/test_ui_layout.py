"""What the page shows (GitHub issue 35: the meter settings were cut to a few letters and named "item N").

The real page (ui/index.html) from the real server, opened in headless Chromium (Playwright); the program's /state is
answered by the test with a connected state that holds every meter setting, each at the value with its widest text.
For every window size (the smallest the program allows, the reporter's, the page's base size, two wide screens) and
both themes the test fails on:
- any element of a settings row whose text does not fit (cut off with "..." or wider than its box), a row wider than
  its column;
- a row tag that still reads "item N" (the v2.05 pages without letters are "page N");
- a value whose text differs from the program's (settings.item: `texts`, or the number x scale with its unit).
The other views (idle state) are checked for text cut off with "...".
Without Playwright and its Chromium the test is skipped, except in CI (GITHUB_ACTIONS), where it must run.
"""
import json
import os
import re
import shutil
import tempfile
import unittest

from support import card  # noqa: F401  (sets the import path)
from meter121 import app as app_mod, server, settings

SIZES = [(860, 560), (921, 1007), (1180, 732), (1920, 1080), (2560, 1080)]
THEMES = ['dark', 'light']
OTHER_VIEWS = ['live', 'scope', 'log', 'card', 'meter', 'prefs']

CUT_JS = """(sel) => {
  const out = [];
  for (const root of document.querySelectorAll(sel)) {
    for (const e of [root, ...root.querySelectorAll('*')]) {
      const cs = getComputedStyle(e);
      if (cs.display === 'inline' || cs.display === 'none' || e.offsetParent === null && e !== root) continue;
      const text = (e.value !== undefined && e.tagName === 'INPUT' ? e.value : e.textContent || '').trim();
      const wide = e.scrollWidth > e.clientWidth + 1, tall = e.scrollHeight > e.clientHeight + 1;
      if (cs.textOverflow === 'ellipsis' && wide) out.push('cut with ...: ' + e.tagName + '.' + e.className + ' "' + text.slice(0, 40) + '"');
      else if (sel === '#setlist .srow' && text && (wide || (tall && cs.overflowY !== 'visible')))
        out.push('does not fit: ' + e.tagName + '.' + e.className + ' "' + text.slice(0, 40) + '" ' + e.scrollWidth + '/' + e.clientWidth);
    }
  }
  return out;
}"""

ROWS_JS = """() => [...document.querySelectorAll('#setlist .srow')].map(r => ({
  id: r.dataset.id, tag: r.querySelector('.code').textContent, name: r.querySelector('.name').textContent,
  choice: r.querySelector('.choice') ? r.querySelector('.choice').textContent : null,
  input: r.querySelector('input') ? r.querySelector('input').value : null,
  unit: r.querySelector('.unit') ? r.querySelector('.unit').textContent : null}))"""


def widest_items():
    """state.settings.items: every setting of the newest firmware, each at the value with its widest text."""
    out = []
    for s in settings.Settings(None).rows():
        it = settings.item(s, 0 if s.wide else (s.min << s.shift))
        if it['texts']:
            v = s.min + max(range(len(it['texts'])), key=lambda i: len(it['texts'][i]))
        else:
            v = s.max
        raw = v if s.wide else (v << s.shift)
        out.append(settings.item(s, raw))
    return out


def expected(it):
    """(choice text, input text, unit) the row must show for the item."""
    if it['texts']:
        return it['texts'][it['value'] - it['min']], None, None
    if it['choices']:
        return it['choices'][it['value']], None, None
    scale = it['scale']
    shown = ('%.1f' % (it['value'] * scale)) if scale < 1 else '%d' % it['value']
    return None, shown, ('Ω' if it['unit'] == 'ohm' else it['unit'] or None)


class PageLayout(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from playwright.sync_api import sync_playwright
            cls.pw = sync_playwright().start()
            cls.browser = cls.pw.chromium.launch()
        except Exception as e:                               # noqa: BLE001 - no Playwright or no browser here
            if os.environ.get('GITHUB_ACTIONS'):
                raise
            raise unittest.SkipTest('Playwright with Chromium is not available here: %s' % e)
        cls.tmp = tempfile.mkdtemp()
        cls._cfg = app_mod.config_path
        app_mod.config_path = lambda: os.path.join(cls.tmp, 'cfg', 'settings.json')
        cls.app = app_mod.Companion(os.path.join(cls.tmp, 'docs'))
        cls.httpd = server.serve(cls.app, 0)
        cls.base = 'http://127.0.0.1:%d' % cls.httpd.server_address[1]

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.browser.close()
        cls.pw.stop()
        app_mod.config_path = cls._cfg
        shutil.rmtree(cls.tmp, True)

    def open_page(self, size, theme, connected, offline=False, prefs=None):
        page = self.browser.new_page(viewport={'width': size[0], 'height': size[1]})
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        st = self.app.state()
        if connected:
            st['link'] = dict(st['link'], state='connected')
            st['settings'] = {'items': self.items, 'error': None, 'locked_reason': None}
        if offline:
            st['offline'] = True
        if prefs:
            st['prefs'] = dict(st['prefs'], **prefs)
        body = json.dumps(st, default=str)
        page.route(re.compile(r'/state(\?|$)'), lambda r: r.fulfill(status=200, content_type='application/json', body=body))
        page.route(re.compile(r'/api$'), lambda r: r.fulfill(status=200, content_type='application/json', body='{"ok": true}'))
        page.goto(self.base + '/')
        page.wait_for_selector('#v-live.on')
        page.evaluate("(t) => document.documentElement.setAttribute('data-theme', t)", theme)
        return page, errors

    def test_meter_settings_fit_and_read_right(self):
        self.items = widest_items()
        by_id = {str(it['id']): it for it in self.items}
        for size in SIZES:
            for theme in THEMES:
                with self.subTest(size=size, theme=theme):
                    page, errors = self.open_page(size, theme, True)
                    page.click('nav button[data-v=msettings]')
                    page.wait_for_timeout(500)
                    rows = page.evaluate(ROWS_JS)
                    self.assertEqual(len(rows), len(self.items))
                    self.assertEqual(page.evaluate(CUT_JS, '#setlist .srow'), [])
                    self.assertEqual(page.evaluate(CUT_JS, '#setlist'), [])
                    for r in rows:
                        it = by_id[r['id']]
                        self.assertFalse(r['tag'].startswith('item '), r)
                        self.assertEqual(r['name'], it['name'])
                        choice, shown, unit = expected(it)
                        self.assertEqual((r['choice'], r['input'], r['unit']), (choice, shown, unit), it['code'])
                    self.assertEqual(errors, [])
                    page.close()

    def test_offline_window_follows_the_setting(self):
        # GitHub issue 23 (Josh): with the setting off the window does not show; "Don't show again" switches it off
        self.items = []
        for on in (True, False):
            with self.subTest(offline_window=on):
                page, errors = self.open_page((1180, 732), 'dark', False, offline=True, prefs={'offline_window': on})
                page.wait_for_timeout(500)
                shown = page.evaluate("() => document.getElementById('oconfirm').classList.contains('show')")
                self.assertEqual(shown, on)
                if on:
                    posts = []
                    page.on('request', lambda r: posts.append(r.post_data) if r.method == 'POST' else None)
                    page.click('#oc-never')
                    page.wait_for_timeout(500)
                    self.assertFalse(page.evaluate("() => document.getElementById('oconfirm').classList.contains('show')"))
                    sent = [json.loads(x) for x in posts if x]
                    self.assertIn({'prefs_set': {'key': 'offline_window', 'value': False}}, sent)
                self.assertEqual(errors, [])
                page.close()

    def test_settings_read_when_page_ld_appears(self):
        # GitHub issue 37 (Mike4U): with the METER SETTINGS page open, page Ld shown on the meter reads the settings by
        # itself (before: only READ did, the check looked for the old page name); opening the page reads them again
        st = self.app.state()
        st['link'] = dict(st['link'], state='connected')
        st['settings'] = {'items': widest_items(), 'error': None, 'locked_reason': 'show the SETUP page Ld on the meter'}
        st['desk'] = False
        box = {'body': json.dumps(st, default=str)}
        page = self.browser.new_page(viewport={'width': 1180, 'height': 732})
        errors, posts = [], []
        page.on('pageerror', lambda e: errors.append(str(e)))
        page.on('request', lambda r: posts.append(r.post_data) if r.method == 'POST' else None)
        page.route(re.compile(r'/state(\?|$)'), lambda r: r.fulfill(status=200, content_type='application/json', body=box['body']))
        page.route(re.compile(r'/api$'), lambda r: r.fulfill(status=200, content_type='application/json', body='{"ok": true}'))
        page.goto(self.base + '/')
        page.wait_for_selector('#v-live.on')
        page.click('nav button[data-v=msettings]')
        page.wait_for_timeout(500)
        reads = lambda: [x for x in posts if x and 'settings_get' in json.loads(x)]
        self.assertEqual(reads(), [])                        # locked (no page Ld): nothing is asked
        st['settings']['locked_reason'] = None
        st['desk'] = True                                    # the meter now shows page Ld
        box['body'] = json.dumps(st, default=str)
        page.wait_for_timeout(800)
        self.assertEqual(len(reads()), 1)                    # read once by itself, the list was not empty
        page.click('nav button[data-v=live]')
        page.click('nav button[data-v=msettings]')
        page.wait_for_timeout(500)
        self.assertEqual(len(reads()), 2)                    # opening the page reads again
        self.assertEqual(errors, [])
        page.close()

    def test_other_views_cut_no_text(self):
        self.items = []
        for size in SIZES:
            for theme in THEMES:
                with self.subTest(size=size, theme=theme):
                    page, errors = self.open_page(size, theme, False)
                    for v in OTHER_VIEWS:
                        page.click('nav button[data-v=%s]' % v)
                        page.wait_for_timeout(250)
                        self.assertEqual(page.evaluate(CUT_JS, '#v-' + v), [], v)
                    self.assertEqual(errors, [])
                    page.close()


if __name__ == '__main__':
    unittest.main()
