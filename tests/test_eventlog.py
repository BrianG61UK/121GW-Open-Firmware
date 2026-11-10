"""The event log file (meter121/eventlog.py, GitHub issue 23): lines, start markers, threads, two writers, rotation,
the lines before this start, a folder that cannot be written."""
import os
import shutil
import stat
import sys
import tempfile
import threading
import unittest

from support import card  # noqa: F401  (sets the import path)
from meter121 import eventlog


class EventLogFile(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.path = os.path.join(self.tmp, 'cfg', 'events.log')

    def lines(self, p=None):
        with open(p or self.path, encoding='utf-8') as f:
            return f.read().splitlines()

    def test_marker_and_lines(self):
        log = eventlog.EventLog(self.path, '1.3.1')
        log.write(1700000000.25, 'link connected')
        log.write(1700000001.5, 'two\nlines')
        got = self.lines()
        self.assertTrue(got[0].startswith('--- start ') and 'pid %d companion 1.3.1' % os.getpid() in got[0], got[0])
        self.assertTrue(got[1].endswith('.250  link connected'), got[1])
        self.assertTrue(got[2].endswith('two lines'), got[2])           # one event, one line
        self.assertEqual(len(got), 3)

    def test_threads_and_two_writers_give_whole_lines(self):
        a, b = eventlog.EventLog(self.path, 'a'), eventlog.EventLog(self.path, 'b')

        def run(log, tag):
            for i in range(500):
                log.write(1700000000.0, '%s %d end' % (tag, i))
        ts = [threading.Thread(target=run, args=(log, tag)) for log, tag in ((a, 'A'), (a, 'B'), (b, 'C'), (b, 'D'))]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        got = [x for x in self.lines() if not x.startswith('--- start ')]
        self.assertEqual(len(got), 2000)
        self.assertTrue(all(x.endswith(' end') for x in got))

    def test_rotation(self):
        old = eventlog.MAX_BYTES
        eventlog.MAX_BYTES = 2000
        self.addCleanup(setattr, eventlog, 'MAX_BYTES', old)
        log = eventlog.EventLog(self.path, 'x')
        for i in range(200):
            log.write(1700000000.0, 'event %03d %s' % (i, 'x' * 20))
        self.assertTrue(os.path.exists(self.path + '.1'))
        self.assertLessEqual(os.path.getsize(self.path), 2000 + 100)
        self.assertTrue(self.lines()[-1].endswith('event 199 ' + 'x' * 20))

    def test_previous_start_only(self):
        first = eventlog.EventLog(self.path, 'one')
        first.write(1700000000.0, 'before 1')
        first.write(1700000001.0, 'before 2')
        second = eventlog.EventLog(self.path, 'two')
        second.write(1700000002.0, 'after')
        prev = second.previous(300)
        self.assertTrue(prev[0].startswith('--- start ') and 'companion one' in prev[0], prev)
        self.assertEqual([x[-8:] for x in prev[1:]], ['before 1', 'before 2'])
        self.assertFalse(any(x.endswith('after') for x in prev))
        self.assertEqual(second.previous(1), prev[-1:])

    @unittest.skipIf(sys.platform == 'win32' or os.geteuid() == 0, 'a read-only folder needs a non-root POSIX user')
    def test_unwritable_folder_is_noted_once(self):
        folder = os.path.join(self.tmp, 'ro')
        os.makedirs(folder)
        os.chmod(folder, stat.S_IRUSR | stat.S_IXUSR)
        self.addCleanup(os.chmod, folder, stat.S_IRWXU)
        notes = []
        log = eventlog.EventLog(os.path.join(folder, 'events.log'), 'x', on_error=notes.append)
        log.write(1700000000.0, 'one')
        log.write(1700000001.0, 'two')
        self.assertEqual(len(notes), 1)
        self.assertIn('event log file:', notes[0])

    def test_write_error_is_noted_once_on_any_platform(self):
        # the folder path is an existing file: makedirs fails on every platform and for every user
        blocker = os.path.join(self.tmp, 'blocker')
        open(blocker, 'w').close()
        notes = []
        log = eventlog.EventLog(os.path.join(blocker, 'events.log'), 'x', on_error=notes.append)
        log.write(1700000000.0, 'one')
        log.write(1700000001.0, 'two')
        self.assertEqual(len(notes), 1)
        self.assertIn('event log file:', notes[0])


if __name__ == '__main__':
    unittest.main()
