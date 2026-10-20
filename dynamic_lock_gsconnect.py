"""GSConnect's actual D-Bus API; never invokes kdeconnect-cli or probes an IP.

Paired+Connected is a connection observation, not a radio distance. Laptop
network loss and service failures yield UNKNOWN, not a departed phone.
"""

from gi.repository import Gio, GLib

from dynamic_lock_bluetooth import Sample, SensorError

SERVICE = 'org.gnome.Shell.Extensions.GSConnect'
PATH = '/org/gnome/Shell/Extensions/GSConnect'
DEVICE = SERVICE + '.Device'
MANAGER = 'org.freedesktop.DBus.ObjectManager'
PROPERTIES = 'org.freedesktop.DBus.Properties'
NM = 'org.freedesktop.NetworkManager'
NM_PATH = '/org/freedesktop/NetworkManager'


def select_phone(objects, device_id='', name=''):
    devices = [(path, interfaces[DEVICE]) for path, interfaces in objects.items()
               if DEVICE in interfaces and interfaces[DEVICE].get('Paired') is True
               and interfaces[DEVICE].get('Type') == 'phone']
    if not devices:
        raise SensorError('No paired GSConnect phone. Open KDE Connect on the phone, pair with this laptop in GSConnect (not Bluetooth), then run --setup.')
    if device_id:
        devices = [(path, props) for path, props in devices if props.get('Id') == device_id]
    elif name:
        devices = [(path, props) for path, props in devices
                   if str(props.get('Name', '')).casefold() == name.casefold()]
    if len(devices) != 1:
        raise SensorError('Phone selection does not match exactly one paired GSConnect phone. Review GSCONNECT_DEVICE_ID or GSCONNECT_DEVICE_NAME in the private config, then run --setup.')
    path, props = devices[0]
    if not isinstance(props.get('Id'), str) or not props['Id'] or type(props.get('Connected')) is not bool:
        raise SensorError('GSConnect returned incomplete phone properties; locking inhibited.')
    return path, props


class GSConnectSensor:
    def __init__(self, session_bus, system_bus, device_id='', name=''):
        self.session_bus, self.system_bus = session_bus, system_bus
        self.device_id, self.name = device_id, name
        self.identity = self.owner = self.network = None
        self.device_path = None

    def close(self):
        # Own no sockets, scanning sessions, or phone profiles. Keep the selected
        # identity across pause/resume so an unrelated phone cannot take its place.
        pass

    def _call(self, bus, destination, path, interface, method, parameters=None):
        return bus.call_sync(destination, path, interface, method, parameters, None,
                             Gio.DBusCallFlags.NO_AUTO_START, 1500, None).unpack()

    def _owner(self):
        return self._call(self.session_bus, 'org.freedesktop.DBus', '/org/freedesktop/DBus',
                          'org.freedesktop.DBus', 'GetNameOwner', GLib.Variant('(s)', (SERVICE,)))[0]

    def _network(self):
        props = self._call(self.system_bus, NM, NM_PATH, PROPERTIES, 'GetAll',
                           GLib.Variant('(s)', (NM,)))[0]
        # Local/site connectivity is enough: neither internet access nor a
        # particular Wi-Fi SSID is required. Never print connection paths/IPs.
        state = props.get('State')
        if props.get('NetworkingEnabled') is not True or type(state) is not int or state < 50:
            raise SensorError('Laptop network is unavailable; no lock from local network loss. Reconnect it to resume.')
        connections = props.get('ActiveConnections')
        if not isinstance(connections, (list, tuple)) or not connections or any(not isinstance(p, str) for p in connections):
            raise SensorError('Laptop has no active network connection; locking inhibited.')
        return tuple(sorted(connections))

    def sample(self):
        try:
            owner = self._owner()
            network = self._network()
            objects = self._call(self.session_bus, SERVICE, PATH, MANAGER, 'GetManagedObjects')[0]
            path, props = select_phone(objects, self.device_id, self.name)
            identity = (path, props['Id'])
            if self.identity is not None and identity != self.identity:
                raise SensorError('Selected GSConnect phone changed; check private selection before restarting.')
            self.identity, self.device_path = identity, path
            if owner != self._owner() or network != self._network():
                raise SensorError('GSConnect or the laptop network changed during the check; fresh arming required.')
            replaced = ((self.owner is not None and owner != self.owner) or
                        (self.network is not None and network != self.network))
            self.owner, self.network = owner, network
            if replaced:
                return Sample('unknown', 'GSConnect or the laptop network restarted; fresh connected checks required.')
            if props['Connected']:
                return Sample('connected', 'Paired phone connected in GSConnect; this is network presence, not distance.')
            return Sample('disconnected', 'Paired phone disconnected; GSConnect and the laptop network are available.')
        except SensorError as error:
            return Sample('unknown', str(error))
        except (GLib.Error, KeyError, TypeError, ValueError):
            return Sample('unknown', 'Cannot read GSConnect or NetworkManager. Enable GSConnect in GNOME, open KDE Connect on the phone, and check the local network.')
