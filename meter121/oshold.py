"""Does the operating system still hold the meter after the companion let it go (GitHub issue 23)?

The meter takes one Bluetooth connection and advertises only while it has none.  On Windows the meter stayed connected
after the companion's Disconnect ("Connected (1)" in the tray), so a new Connect found nothing until Bluetooth was
switched off and on.  What each system allows (research 2026-11-08, sources in the comments):

Windows   bleak's connect sets GattSession.maintain_connection = True ("keeps the device connected until we set
          maintain_connection = False", bleak 3.0.2 bleak/backends/winrt/client.py:366) and its disconnect never sets it
          back (client.py:449-497); with it set "the system waits indefinitely for a connection" (Microsoft Learn,
          GattSession.MaintainConnection).  prepare_close() sets it False before the disconnect.  After the disconnect
          Windows drops the link "after a small timeout period" once no app holds a reference (Microsoft Learn, GATT
          client); BluetoothLEDevice.ConnectionStatus tells whether it still has it.  No API forces a link down that
          Windows keeps (bleak issue 1949): the user removes the meter in Settings or switches Bluetooth off and on.
Linux     BlueZ: Device1.Connected tells; Device1.Disconnect "terminates low-level ACL connection" and any client may
          call it (bluez src/bluetooth.conf, context default) -> release().
macOS     CoreBluetooth: cancelPeripheralConnection does not guarantee the physical link goes down (Apple); there is
          no public API to force it or to forget the device; retrieveConnectedPeripheralsWithServices tells whether
          the system still holds a meter with the service.

Every function here returns None when it cannot tell (another system, a backend without the attribute, an error): the
caller then says nothing.  Private attributes of bleak are used only behind getattr, so a newer bleak only loses the
check, never the disconnect.
"""
import asyncio
import sys

HELD_WAIT = 4.0                                   # seconds after the disconnect before the check (Windows' "small timeout")
HELD_POLLS = 3                                    # checks, HELD_WAIT apart, before the system is said to hold the meter
MACOS_READY_WAIT = 2.0                            # seconds for CoreBluetooth's first state update (a permission dialog: no answer)

HINT = {
    'win32': 'Windows still holds the meter after the disconnect, so the meter does not advertise and Connect cannot '
             'find it.  Remove the meter in Settings > Bluetooth & devices (if it is listed there), or switch Bluetooth '
             'off and on in Windows or on the meter (hold PEAK twice).',
    'linux': 'Linux still holds the meter after the disconnect (BlueZ); the companion asked BlueZ to end the connection.  '
             'If Connect still finds nothing: bluetoothctl disconnect, or switch Bluetooth off and on.',
    'darwin': 'macOS still holds the meter after the disconnect (another app or the system keeps the link), so Connect '
              'cannot find it.  Close other Bluetooth apps for the meter, or switch Bluetooth off and on.',
}


def prepare_close(client):
    """Before the disconnect: on Windows let the system drop the link (maintain_connection False).  Never raises."""
    if sys.platform != 'win32':
        return
    try:
        session = getattr(getattr(client, '_backend', None), '_session', None)
        if session is not None:
            session.maintain_connection = False
    except Exception:                             # noqa: BLE001 - only a check is lost
        pass


async def held(address, service):
    """True when the system still has a connection to the meter, False when not, None when it cannot tell."""
    try:
        if sys.platform == 'win32':
            return await _held_windows(address)
        if sys.platform.startswith('linux'):
            path = await _bluez_path(address)
            if path is None:
                return None
            from bleak.backends.bluezdbus.manager import get_global_bluez_manager
            return bool((await get_global_bluez_manager()).is_connected(path))
        if sys.platform == 'darwin':
            return await _held_macos(service)
    except Exception:                             # noqa: BLE001 - cannot tell
        return None
    return None


async def release(address):
    """Linux: ask BlueZ to end the connection (Device1.Disconnect).  True when asked, None elsewhere or on failure."""
    if not sys.platform.startswith('linux'):
        return None
    try:
        path = await _bluez_path(address)
        if path is None:
            return None
        from bleak.backends.bluezdbus.manager import get_global_bluez_manager
        from dbus_fast import Message
        bus = getattr(await get_global_bluez_manager(), '_bus', None)
        if bus is None:
            return None
        await bus.call(Message(destination='org.bluez', path=path, interface='org.bluez.Device1', member='Disconnect'))
        return True
    except Exception:                             # noqa: BLE001
        return None


async def _held_windows(address):
    from winrt.windows.devices.bluetooth import BluetoothConnectionStatus, BluetoothLEDevice
    dev = await BluetoothLEDevice.from_bluetooth_address_async(int(address.replace(':', ''), 16))
    if dev is None:
        return False
    try:
        return dev.connection_status == BluetoothConnectionStatus.CONNECTED
    finally:
        dev.close()                               # this reference must not keep the link itself


async def _bluez_path(address):
    from bleak.backends.bluezdbus.manager import get_global_bluez_manager
    props = getattr(await get_global_bluez_manager(), '_properties', {})
    for path, ifaces in props.items():
        dev = ifaces.get('org.bluez.Device1')
        if dev and str(dev.get('Address', '')).upper() == address.upper():
            return path
    return None


async def _held_macos(service):
    """bleak 3.0.2: CentralManagerDelegate is a Python class whose central manager may be used only after
    wait_until_ready (backends/corebluetooth/CentralManagerDelegate.py:194, 220; 1.1.1 waited inside init)."""
    from CoreBluetooth import CBUUID
    from bleak.backends.corebluetooth.CentralManagerDelegate import CentralManagerDelegate
    delegate = CentralManagerDelegate()
    await asyncio.wait_for(delegate.wait_until_ready(), MACOS_READY_WAIT)
    cm = delegate.central_manager
    return len(cm.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_(service)]) or []) > 0


async def check_after_disconnect(address, service, sleep=asyncio.sleep):
    """After the companion's disconnect: (held, released, hint).  held None: cannot tell; on Linux a held meter is
    released through BlueZ and checked again."""
    state = None
    for _ in range(HELD_POLLS):
        await sleep(HELD_WAIT)
        state = await held(address, service)
        if state is not True:
            return state, False, None
    released = bool(await release(address))
    if released:
        await sleep(HELD_WAIT)
        if await held(address, service) is False:
            return False, True, None
    key = 'win32' if sys.platform == 'win32' else 'linux' if sys.platform.startswith('linux') else 'darwin'
    return True, released, HINT[key]
