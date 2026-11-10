"""The program's events in a file, so that a closed program or a failed update leaves them behind (GitHub issue 23:
after a failed update attempt the log came out empty: the events lived only in memory until Save report).

    events.log     next to the settings file (paths.config_dir(); app.event_log_path())
    events.log.1   the previous file, once events.log passed MAX_BYTES (at most about 2 * MAX_BYTES on disk)

One line per event in the time format of the report.  Every write opens the file, appends one line and closes it, so
Windows can rename it.  Appends from two handles are not atomic on Windows (CI 2026-11-10: two writers lost 2 of 2000
lines), so every append holds a lock shared by all EventLog objects of the file in this process and an OS lock on
`events.log.lock` (Windows msvcrt.locking, elsewhere fcntl.flock), which two copies of the program (the server takes the
next free port) both respect.  Each start of the program writes a marker line; the report
lists the lines before this start's marker ("events before this start"), so a report saved after the program was
reopened still shows the failed attempt.  The file is not anonymised (it never leaves the computer unless the user
sends it); the report that is meant to be sent anonymises everything it takes from it.
A write that fails (disk full, no permission) is noted once through `on_error`; the program never stops for the log.
"""
import os
import sys
import threading
import time

MAX_BYTES = 1024 * 1024                         # rotation size of events.log
TAIL_BYTES = 64 * 1024                          # bytes read from the end of each file for the report
MARKER = '--- start '
_LOCKS = {}                                     # path -> threading.Lock shared by every EventLog of that file
_LOCKS_GUARD = threading.Lock()


def _path_lock(path):
    with _LOCKS_GUARD:
        return _LOCKS.setdefault(os.path.abspath(path), threading.Lock())


class _FileLock:
    """An exclusive OS lock on `path` (created if missing) for the time of a `with` block."""
    def __init__(self, path):
        self.path = path

    def __enter__(self):
        self.f = open(self.path, 'a+b')
        try:
            if sys.platform == 'win32':
                import msvcrt
                self.f.seek(0)
                msvcrt.locking(self.f.fileno(), msvcrt.LK_LOCK, 1)   # retries for about 10 s, then OSError
            else:
                import fcntl
                fcntl.flock(self.f.fileno(), fcntl.LOCK_EX)
        except BaseException:
            self.f.close()
            raise
        return self

    def __exit__(self, *exc):
        try:
            if sys.platform == 'win32':
                import msvcrt
                self.f.seek(0)
                msvcrt.locking(self.f.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.f.fileno(), fcntl.LOCK_UN)
        finally:
            self.f.close()
        return False


def line(t, text):
    """One event in the report's time format."""
    return '%s.%03d  %s' % (time.strftime('%Y-%m-%d %H:%M:%S', time.localtime(t)), int((t % 1) * 1000), text)


class EventLog:
    def __init__(self, path, version, on_error=None):
        """Writes this start's marker at once; `on_error(text)` is told the first failed write (not again until a write
        succeeds)."""
        self.path = path
        self.on_error = on_error
        self._lock = _path_lock(path)
        self._failed = False
        self.marker = '%s%s pid %d companion %s ---' % (MARKER, time.strftime('%Y-%m-%dT%H:%M:%S'), os.getpid(), version)
        self._append(self.marker)

    def write(self, t, text):
        self._append(line(t, text))

    def _append(self, text):
        note = None
        with self._lock:
            try:
                os.makedirs(os.path.dirname(self.path), exist_ok=True)
                with _FileLock(self.path + '.lock'):
                    self._rotate()
                    with open(self.path, 'a', encoding='utf-8', errors='replace', newline='\n') as f:
                        f.write(text.replace('\n', ' ') + '\n')
                self._failed = False
            except OSError as e:
                if not self._failed:
                    self._failed = True                     # set before the note: the note itself must not recurse
                    note = 'event log file: %s' % e
        if note and self.on_error:
            self.on_error(note)

    def _rotate(self):
        try:
            if os.path.getsize(self.path) <= MAX_BYTES:
                return
        except OSError:
            return                                          # no file yet
        try:
            os.replace(self.path, self.path + '.1')
        except OSError:
            pass                                            # another copy holds it (Windows): keep appending

    def previous(self, limit):
        """The last `limit` event lines written before this start's marker (older starts' markers included), oldest first."""
        lines = []
        for p in (self.path + '.1', self.path):
            lines += _tail_lines(p)
        try:
            cut = len(lines) - 1 - lines[::-1].index(self.marker)
        except ValueError:
            cut = len(lines)                                # this start's marker was rotated away or not written
        return lines[:cut][-limit:]


def _tail_lines(path):
    """The complete lines in the last TAIL_BYTES of `path` ([] when it cannot be read)."""
    try:
        with open(path, 'rb') as f:
            f.seek(0, os.SEEK_END)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read()
    except OSError:
        return []
    text = data.decode('utf-8', errors='replace')
    parts = text.split('\n')
    if size > TAIL_BYTES:
        parts = parts[1:]                                   # the first line may be cut
    return parts[:-1]                                       # after the last newline: '' or a line still being written
