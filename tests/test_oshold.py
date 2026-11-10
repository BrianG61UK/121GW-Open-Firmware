"""oshold (GitHub issue 23): does the system still hold the meter after the disconnect, and what follows from it."""
import asyncio
import sys
import types
import unittest

sys.path.insert(0, __file__.rsplit('/', 2)[0])
from meter121 import oshold  # noqa: E402


async def no_sleep(_s):
    return None


class AfterDisconnect(unittest.TestCase):
    def setUp(self):
        self.old = (oshold.held, oshold.release)
        self.addCleanup(lambda: (setattr(oshold, 'held', self.old[0]), setattr(oshold, 'release', self.old[1])))

    def run_check(self, states, release=None):
        seq = list(states)

        async def held(_a, _s):
            return seq.pop(0) if seq else states[-1]

        async def rel(_a):
            return release
        oshold.held, oshold.release = held, rel
        return asyncio.run(oshold.check_after_disconnect('AA:BB:CC:DD:EE:FF', 'svc', sleep=no_sleep))

    def test_released_by_the_system(self):
        self.assertEqual(self.run_check([False]), (False, False, None))

    def test_cannot_tell_says_nothing(self):
        self.assertEqual(self.run_check([None]), (None, False, None))

    def test_released_after_a_while(self):
        self.assertEqual(self.run_check([True, True, False]), (False, False, None))

    def test_still_held_gives_the_hint_of_the_system(self):
        held, released, hint = self.run_check([True, True, True, True])
        self.assertTrue(held)
        self.assertFalse(released)
        self.assertIn(oshold.HINT['win32' if sys.platform == 'win32' else 'linux' if sys.platform.startswith('linux')
                                  else 'darwin'], hint)

    def test_linux_release_that_works(self):
        self.assertEqual(self.run_check([True, True, True, False], release=True), (False, True, None))


class PrepareClose(unittest.TestCase):
    def test_windows_lets_the_link_go(self):
        session = types.SimpleNamespace(maintain_connection=True)
        client = types.SimpleNamespace(_backend=types.SimpleNamespace(_session=session))
        old = oshold.sys.platform
        oshold.sys.platform = 'win32'
        try:
            oshold.prepare_close(client)
        finally:
            oshold.sys.platform = old
        self.assertFalse(session.maintain_connection)

    def test_other_systems_and_odd_clients_untouched(self):
        session = types.SimpleNamespace(maintain_connection=True)
        oshold.prepare_close(types.SimpleNamespace(_backend=types.SimpleNamespace(_session=session)))
        if sys.platform != 'win32':
            self.assertTrue(session.maintain_connection)
        oshold.prepare_close(object())                # no backend: nothing, no error


class HeldNeverRaises(unittest.TestCase):
    def test_errors_mean_cannot_tell(self):
        old = oshold._held_macos, oshold._held_windows, oshold._bluez_path

        async def aboom(*_a):
            raise RuntimeError('no Bluetooth')
        oshold._held_macos, oshold._held_windows, oshold._bluez_path = aboom, aboom, aboom
        try:
            self.assertIsNone(asyncio.run(oshold.held('AA:BB:CC:DD:EE:FF', 'svc')))
            self.assertIsNone(asyncio.run(oshold.release('AA:BB:CC:DD:EE:FF')))
        finally:
            oshold._held_macos, oshold._held_windows, oshold._bluez_path = old


if __name__ == '__main__':
    unittest.main()
