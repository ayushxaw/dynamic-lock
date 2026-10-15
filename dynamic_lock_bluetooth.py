"""Linux Classic Bluetooth sensor. No discovery, profile connection, or privileges.

Only the worker owns these sockets. SDP is used as a small link keepalive, not
to collect services. Classic HCI RSSI is relative to the golden receive range;
zero is valid and these readings are NOT advertising RSSI in dBm.
"""

from dataclasses import dataclass, field
import errno
import fcntl
import re
import socket
import struct
import time


class SensorError(Exception):
    """Messages are fixed, public diagnostics; never include device identifiers."""


@dataclass(frozen=True)
class Target:
    address: str = field(repr=False)
    local_address: str = field(repr=False)
    index: int
    device_path: str = field(repr=False)
    adapter_path: str = field(repr=False)


@dataclass(frozen=True)
class Sample:
    kind: str  # measured, absent, unknown
    reason: str
    rssi: int | None = None


def select_target(objects, address):
    """Select exactly one paired target, on its own powered adapter."""
    matches = []
    for path, interfaces in objects.items():
        device = interfaces.get("org.bluez.Device1", {})
        if device.get("Address", "").upper() == address.upper():
            matches.append((path, device))
    if not matches:
        raise SensorError("Phone not found: pair it in Ubuntu Bluetooth settings and check PHONE_ADDRESS.")
    if len(matches) != 1:
        raise SensorError("Phone exists on multiple adapters; remove the unused pairing before monitoring.")
    path, device = matches[0]
    if not device.get("Paired", False):
        raise SensorError("Phone is not paired; pair it in Ubuntu Bluetooth settings.")
    adapter_path = device.get("Adapter", "")
    adapter = objects.get(adapter_path, {}).get("org.bluez.Adapter1", {})
    if not adapter.get("Powered", False):
        raise SensorError("Local Bluetooth adapter unavailable or off; enable Bluetooth. Locking inhibited.")
    match = re.fullmatch(r"/org/bluez/hci(\d+)", adapter_path)
    local = adapter.get("Address", "")
    if not match or not re.fullmatch(r"(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}", local):
        raise SensorError("BlueZ returned an unsupported adapter identity.")
    return Target(address, local, int(match[1]), path, adapter_path)


def validate_sdp(packet, transaction):
    if len(packet) < 5:
        raise SensorError("Malformed SDP response; locking inhibited.")
    pdu, tx, length = struct.unpack_from(">BHH", packet)
    if tx != transaction or length != len(packet) - 5:
        raise SensorError("Stale or malformed SDP response; locking inhibited.")
    if pdu == 1:
        raise SensorError("Phone rejected the SDP query; this device may be unsupported.")
    if pdu != 3 or length < 5:
        raise SensorError("Unexpected SDP response; locking inhibited.")
    total, count = struct.unpack_from(">HH", packet, 5)
    # We requested at most one record; continuation is permitted, never followed.
    end = 9 + 4 * count
    if count > 1 or count > total or end >= len(packet):
        raise SensorError("Malformed SDP record count; locking inhibited.")
    continuation = packet[end]
    if continuation > 16 or len(packet) != end + 1 + continuation:
        raise SensorError("Malformed SDP continuation; locking inhibited.")


def command_response(packet, opcode):
    """Return command-complete parameters, or None for unrelated/status events."""
    if len(packet) < 3 or packet[0] != 4 or len(packet) != packet[2] + 3:
        raise SensorError("Malformed controller response; locking inhibited.")
    event = packet[1]
    if event == 0x0F:
        if len(packet) != 7:
            raise SensorError("Malformed controller status; locking inhibited.")
        if struct.unpack_from("<H", packet, 5)[0] == opcode and packet[3]:
            raise SensorError("Controller rejected the read command; RSSI may be unsupported.")
        return None
    if event != 0x0E:
        return None
    if len(packet) < 7:
        raise SensorError("Truncated controller completion; locking inhibited.")
    if struct.unpack_from("<H", packet, 4)[0] != opcode:
        return None
    if packet[6]:
        raise SensorError("Controller read failed; locking inhibited until a fresh connection succeeds.")
    return packet[6:]


class ConnectionSensor:
    CONNECT_TIMEOUT = 6.0  # Allow the normal Classic page timeout (~5.12 s).
    SDP_TIMEOUT = 2.0
    HCI_TIMEOUT = 1.0
    READ_RSSI = 0x1405
    READ_VERSION = 0x1001
    HCIGETCONNINFO = 0x800448D5  # Linux _IOR('H', 213, int), asm-generic ABI.

    def __init__(self, target_provider):
        self.target_provider = target_provider
        self.target = None
        self.link = None
        self.transaction = 0

    def close(self):
        if self.link is not None:
            self.link.close()
            self.link = None

    def _connect(self):
        link = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_SEQPACKET, socket.BTPROTO_L2CAP)
        try:
            link.settimeout(self.CONNECT_TIMEOUT)
            link.bind((self.target.local_address, 0))
            link.connect((self.target.address, 1))  # SDP PSM; no audio/network profile.
        except BaseException:
            link.close()
            raise
        self.link = link

    def _ping(self):
        self.transaction = (self.transaction % 65535) + 1
        body = b"\x35\x03\x19\x10\x02\x00\x01\x00"
        request = struct.pack(">BHH", 2, self.transaction, len(body)) + body
        self.link.settimeout(self.SDP_TIMEOUT)
        if self.link.send(request) != len(request):
            raise SensorError("Incomplete SDP request; locking inhibited.")
        response = self.link.recv(1024)
        if not response:
            raise ConnectionResetError("SDP channel closed")
        validate_sdp(response, self.transaction)

    def _hci(self):
        hci = socket.socket(socket.AF_BLUETOOTH, socket.SOCK_RAW, socket.BTPROTO_HCI)
        try:
            hci.bind((self.target.index,))
        except BaseException:
            hci.close()
            raise
        return hci

    def _command(self, hci, opcode, parameters, expected_length, handle=None):
        # A fresh raw socket per measurement prevents old replies being reused.
        hci.setsockopt(socket.SOL_HCI, socket.HCI_FILTER,
                       struct.pack("=IIIH2x", 1 << 4, (1 << 14) | (1 << 15), 0, opcode))
        hci.settimeout(self.HCI_TIMEOUT)
        request = struct.pack("<BHB", 1, opcode, len(parameters)) + parameters
        if hci.send(request) != len(request):
            raise SensorError("Incomplete controller request; locking inhibited.")
        deadline = time.monotonic() + self.HCI_TIMEOUT
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise SensorError("Local controller read timed out; locking inhibited.")
            hci.settimeout(remaining)
            result = command_response(hci.recv(260), opcode)
            if result is None:
                continue
            if len(result) != expected_length:
                raise SensorError("Unexpected controller response length; locking inhibited.")
            if handle is not None and struct.unpack_from("<H", result, 1)[0] != handle:
                continue
            return result

    def _handle(self, hci):
        address = bytes.fromhex(self.target.address.replace(":", ""))[::-1]
        request = bytearray(struct.pack("=6sB17x", address, 1))  # ACL_LINK
        fcntl.ioctl(hci.fileno(), self.HCIGETCONNINFO, request, True)
        handle = struct.unpack_from("=H", request, 8)[0]
        if handle > 0x0EFF or request[10:16] != address or request[16] != 1:
            raise SensorError("Controller returned a different connection; locking inhibited.")
        return handle

    def _rssi(self):
        with self._hci() as hci:
            handle = self._handle(hci)
            result = self._command(hci, self.READ_RSSI, struct.pack("<H", handle), 4, handle)
            if self._handle(hci) != handle:
                raise SensorError("Connection changed during measurement; locking inhibited.")
            value = struct.unpack_from("b", result, 3)[0]
            if value in (127, -128):
                raise SensorError("Connection RSSI unavailable; this phone/controller may be unsupported.")
            return value

    def _healthy(self):
        if self.target_provider() != self.target:
            raise SensorError("Bluetooth adapter or pairing changed; fresh arming required.")
        with self._hci() as hci:
            self._command(hci, self.READ_VERSION, b"", 9)

    def _connection_timeout(self):
        # A remote timeout is only evidence with a fresh BlueZ AND HCI health check.
        self._healthy()
        return Sample("absent", "Remote connection timed out; local controller responded.")

    def sample(self):
        try:
            target = self.target_provider()
            if target != self.target:
                self.close()
                self.target = target
            if self.link is not None:
                try:
                    self._ping()
                except OSError:
                    # A dropped/idle SDP channel alone is not departure. Reconnect.
                    self.close()
            if self.link is None:
                try:
                    self._connect()
                except (TimeoutError, OSError) as error:
                    if isinstance(error, TimeoutError) or error.errno == errno.ETIMEDOUT:
                        return self._connection_timeout()
                    raise
                self._ping()
            rssi = self._rssi()
            if self.target_provider() != self.target:
                raise SensorError("Bluetooth adapter or pairing changed during measurement.")
            return Sample("measured", "Live connection RSSI received.", rssi)
        except SensorError as error:
            self.close()
            return Sample("unknown", str(error))
        except OSError as error:
            self.close()
            if error.errno in (errno.EACCES, errno.EPERM):
                reason = "Bluetooth access denied. This kernel/session is unsupported without additional permissions; do not run as root."
            elif error.errno == errno.ECONNREFUSED:
                reason = "Phone refused SDP connection; check pairing. Refusal is not departure."
            elif isinstance(error, TimeoutError):
                reason = "SDP or controller reply timed out; no valid proximity measurement."
            else:
                reason = "Bluetooth connection unavailable; retrying. Check Bluetooth and pairing with --doctor."
            return Sample("unknown", reason)
