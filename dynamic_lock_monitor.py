#!/usr/bin/env python3
"""GNOME monitor with one bounded radio worker and a responsive GLib main loop."""

import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import signal
import sys
import time

try:
    import gi
    gi.require_version('Gio', '2.0')
    gi.require_version('GLib', '2.0')
    from gi.repository import Gio, GLib, GLibUnix
except (ImportError, ValueError):
    print('ERROR: system Python needs PyGObject with Gio/GLibUnix. On Ubuntu install python3-gi gir1.2-glib-2.0.', file=sys.stderr)
    raise SystemExit(1)

from dynamic_lock_bluetooth import ConnectionSensor, Sample, SensorError, select_target, select_paired_phone
from dynamic_lock_config import ConfigError, read_config, save_gsconnect_selection, save_bluetooth_selection
from dynamic_lock_desktop import Desktop, lock_settings_problem
from dynamic_lock_gsconnect import GSConnectSensor, select_phone, SERVICE as GSCONNECT, PATH as GSCONNECT_PATH, DEVICE as GSCONNECT_DEVICE, NM, NM_PATH
from dynamic_lock_state import PresenceMachine

BLUEZ = 'org.bluez'
DEVICE = 'org.bluez.Device1'
ADAPTER = 'org.bluez.Adapter1'
PROPERTIES = 'org.freedesktop.DBus.Properties'
OBJECT_MANAGER = 'org.freedesktop.DBus.ObjectManager'


def milliseconds():
    return time.monotonic() * 1000


def sleep_offset():
    # CLOCK_MONOTONIC pauses during suspend; BOOTTIME does not.
    return time.clock_gettime(time.CLOCK_BOOTTIME) - time.monotonic()


class BluezTarget:
    def __init__(self, bus, address):
        self.bus, self.address = bus, address
        self.target = None

    def __call__(self):
        try:
            objects = self.bus.call_sync(BLUEZ, '/', OBJECT_MANAGER, 'GetManagedObjects',
                None, None, Gio.DBusCallFlags.NO_AUTO_START, 1500, None).unpack()[0]
        except GLib.Error as error:
            raise SensorError('BlueZ unavailable; enable Bluetooth and check the bluetooth service. Retrying automatically.') from error
        self.target = select_target(objects, self.address)
        return self.target


class RadioWorker:
    """One outstanding job, no growing executor queue. Sockets stay on this thread."""
    def __init__(self, sensor):
        self.sensor = sensor
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='presence')
        self.busy = False
        self.generation = 0
        self.worker_generation = -1
        self.dirty = True

    def invalidate(self):
        self.generation += 1
        self.dirty = True

    def submit(self, callback, measure=True):
        if self.busy:
            return False
        self.busy = True
        generation = self.generation
        self.dirty = False

        def work():
            offset = sleep_offset()
            if self.worker_generation != generation or not measure:
                self.sensor.close()
                self.worker_generation = generation
            result = self.sensor.sample() if measure else None
            if abs(sleep_offset() - offset) > 2:
                self.sensor.close()
                result = Sample('unknown', 'Suspend interrupted measurement; fresh arming required.')
            return result, time.monotonic(), sleep_offset()

        def done(future):
            try:
                result = future.result()
            except Exception:
                # No exception repr: OS/BlueZ errors may contain private addresses.
                result = (Sample('unknown', 'Unexpected sensor failure; see --doctor and report the software version.'),
                          time.monotonic(), sleep_offset())
            GLib.idle_add(deliver, *result)

        def deliver(result, completed_at, offset):
            self.busy = False
            if generation == self.generation:
                if time.monotonic() - completed_at > 3 or abs(sleep_offset() - offset) > 2:
                    self.invalidate()
                    result = Sample('unknown', 'Delayed measurement discarded; fresh arming required.')
                callback(result)
            return GLib.SOURCE_REMOVE

        self.executor.submit(work).add_done_callback(done)
        return True

    def close(self):
        self.invalidate()
        # At most one bounded operation remains. Close after it, on the same worker.
        self.executor.submit(self.sensor.close)
        self.executor.shutdown(wait=True, cancel_futures=False)


class Monitor:
    def __init__(self, config, state_path=None, dry_run=False, duration=0):
        self.config, self.state_path = config, state_path
        self.dry_run, self.duration = dry_run, duration
        self.loop = GLib.MainLoop()
        self.system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        self.desktop = Desktop(Gio.bus_get_sync(Gio.BusType.SESSION, None))
        self.backend = config.get('BACKEND', 'bluetooth')
        if self.backend == 'gsconnect':
            self.target = GSConnectSensor(self.desktop.bus, self.system_bus,
                config.get('GSCONNECT_DEVICE_ID', ''), config.get('GSCONNECT_DEVICE_NAME', ''))
            self.worker = RadioWorker(self.target)
        else:
            self.target = BluezTarget(self.system_bus, config['PHONE_ADDRESS'])
            self.worker = RadioWorker(ConnectionSensor(self.target))
        self.machine = PresenceMachine(near_threshold=config['RSSI_NEAR_THRESHOLD'],
            away_threshold=config['RSSI_AWAY_THRESHOLD'],
            stale_seconds=config['STATUS_STALE_SECONDS'] if self.backend == 'gsconnect' else config['RSSI_STALE_SECONDS'],
            away_seconds=config['AWAY_CONFIRM_SECONDS'], return_seconds=config['RETURN_CONFIRM_SECONDS'],
            connection_mode=self.backend == 'gsconnect')
        self.paused = self.sleeping = self.stopping = self.desktop_busy = False
        self.last_tick = time.monotonic()
        self.sleep_delta = sleep_offset()
        self.next_sample = 0
        self.faults = 0
        self.health = 'unknown'
        self.sensor_reason = 'Waiting for the first measurement.'
        self.inhibited = ''
        self.previous_status = None
        self.subscriptions = []
        self.sources = []
        self.counts = dict.fromkeys(('measured', 'absent', 'connected', 'disconnected', 'unknown', 'lock_decisions', 'confirmed_locks'), 0)
        self.started = time.monotonic()

    @staticmethod
    def log(message):
        print('[dynamic_lock] ' + message, flush=True)

    def invalidate(self, reason):
        self.worker.invalidate()
        self.machine.unknown(reason)
        self.health, self.sensor_reason = 'unknown', reason
        self.next_sample = 0
        self.inhibited = reason
        self._status()

    def _pause(self):
        if not self.paused:
            self.paused = True
            self.invalidate('Paused by user; resume requires fresh presence checks.')
        return GLib.SOURCE_CONTINUE

    def _resume(self):
        if self.paused:
            self.paused = False
            self.invalidate('Resumed; waiting for fresh presence checks.')
        return GLib.SOURCE_CONTINUE

    def _prepare_for_sleep(self, _bus, _sender, _path, _iface, _signal, parameters):
        preparing = bool(parameters.unpack()[0])
        if preparing != self.sleeping:
            self.sleeping = preparing
            self.invalidate('Suspend/resume; discarded earlier readings and in-flight results.')
            self.sleep_delta = sleep_offset()
            self.last_tick = time.monotonic()

    def _bluez_changed(self, _bus, _sender, path, _iface, name, parameters):
        values = parameters.unpack()
        target = self.target.target
        if name == 'NameOwnerChanged':
            if values[0] == BLUEZ:
                self.invalidate('BlueZ restarted or stopped; fresh arming required.')
        elif target and name == 'PropertiesChanged':
            interface, changed, invalid = values
            relevant = ((path == target.adapter_path and interface == ADAPTER and
                         ('Powered' in changed or 'Powered' in invalid)) or
                        (path == target.device_path and interface == DEVICE and
                         ('Paired' in changed or 'Paired' in invalid or 'Adapter' in changed
                          or 'Blocked' in changed or 'Blocked' in invalid)))
            if relevant:
                self.invalidate('Bluetooth adapter or pairing changed; fresh arming required.')
        elif target and name == 'InterfacesRemoved' and values[0] in (target.device_path, target.adapter_path):
            self.invalidate('Bluetooth adapter or pairing removed; fresh arming required.')

    def _gsconnect_changed(self, _bus, _sender, path, _iface, name, parameters):
        values = parameters.unpack()
        if name == 'NameOwnerChanged':
            if values[0] in (GSCONNECT, NM):
                self.invalidate('GSConnect or NetworkManager restarted; fresh connected checks required.')
            return
        if name == 'InterfacesRemoved':
            if values[0] == self.target.device_path:
                self.invalidate('Selected GSConnect phone removed; check pairing.')
            return
        if name == 'InterfacesAdded':
            self.worker.invalidate()
            self.next_sample = 0
            return
        interface, changed, invalid = values
        keys = set(changed) | set(invalid)
        if path == NM_PATH and interface == NM and keys & {'State', 'NetworkingEnabled', 'ActiveConnections', 'PrimaryConnection', 'WirelessEnabled'}:
            self.invalidate('Laptop network changed; fresh connected checks required.')
        elif interface == GSCONNECT_DEVICE and (self.target.device_path is None or path == self.target.device_path):
            if keys & {'Paired', 'Id'}:
                self.invalidate('GSConnect pairing changed; fresh connected checks required.')
            elif 'Connected' in keys:
                # Cancel any pending asynchronous desktop request immediately,
                # then validate this change with fresh service/network checks.
                self.worker.invalidate()
                self.health = 'unknown'
                self.next_sample = 0

    def _received(self, sample):
        if sample is None or self.paused or self.sleeping or self.stopping:
            return
        now = time.monotonic()
        self.counts[sample.kind] += 1
        self.health, self.sensor_reason = sample.kind, sample.reason
        self.machine.accept(sample.kind, now * 1000, sample.rssi, sample.reason)
        self.faults = min(4, self.faults + 1) if sample.kind == 'unknown' else 0
        delay = min(30, self.config['POLL_SECONDS'] * 2 ** max(0, self.faults - 1))
        # Keep the normal cadence relative to sample start; slow operations never
        # create queued work. Only faults add an increasing recovery delay.
        self.next_sample = now + delay if self.faults else max(self.next_sample, now)
        self.inhibited = sample.reason if sample.kind == 'unknown' else ''
        if self.dry_run:
            signal = f'; connection RSSI={sample.rssi}' if self.backend == 'bluetooth' else ''
            self.log(f'Sample: {sample.kind}{signal}; {sample.reason}')
        self._decide()
        self._status()

    def _guard(self, generation):
        return (generation == self.worker.generation and not self.stopping and not self.paused
                and not self.sleeping and self.health in ('measured', 'absent', 'connected', 'disconnected')
                and self.machine.last_sample_at is not None
                and 0 <= milliseconds() - self.machine.last_sample_at <= 3000
                and self.machine.away_since is not None)

    def _decide(self):
        # Only a newly completed healthy measurement can start the desktop chain.
        now = milliseconds()
        self.machine.tick(now, False)
        if self.desktop_busy or not self.machine.eligible(now):
            return
        generation = self.worker.generation
        problem = lock_settings_problem()
        if problem:
            self.inhibited = problem
            return
        self.desktop_busy = True

        def idle_received(idle_ms):
            if not self._guard(generation):
                self.desktop_busy = False
                return
            if idle_ms is None:
                self.inhibited = 'GNOME idle monitor unavailable; no lock without idle confirmation.'
                self.desktop_busy = False
                self._status()
                return
            result = self.machine.tick(milliseconds(), idle_ms >= self.config['IDLE_AFTER_SECONDS'] * 1000)
            if not result['should_lock']:
                self.desktop_busy = False
                self._status()
                return
            self.counts['lock_decisions'] += 1
            if self.dry_run:
                self.log('DRY RUN: would lock now. No lock command was sent.')
                self.machine.lock_succeeded()
                self.desktop_busy = False
                self._status()
                return

            def locked(success):
                self.desktop_busy = False
                if generation != self.worker.generation or self.health == 'unknown' or self.paused or self.sleeping:
                    return
                if success:
                    self.counts['confirmed_locks'] += 1
                    self.machine.lock_succeeded()
                    self.log('GNOME reports lock screen active. Phone return will only re-arm.')
                else:
                    self.machine.lock_failed(milliseconds())
                    self.log('ERROR: lock could not be confirmed. Check GNOME lock settings with --doctor; retry is delayed.')
                self._status()
            self.desktop.lock(self.config['LOCK_CMD'], lambda: self._guard(generation), locked)
        self.desktop.idle(idle_received)

    def _status(self):
        state = 'PAUSED' if self.paused else 'SUSPENDED' if self.sleeping else self.machine.state
        reason = self.inhibited or self.machine.reason
        signature = (state, reason)
        if signature != self.previous_status:
            self.log(f'State: {state}. {reason}')
            self.previous_status = signature
        if not self.state_path:
            return
        status = {'pid': os.getpid(), 'mode': 'dry-run' if self.dry_run else 'automatic',
                  'backend': self.backend,
                  'updated_at': time.time(), 'state': state, 'sensor': self.health,
                  'signal_units': ('GSConnect connection (no distance measurement)' if self.backend == 'gsconnect' else
                                   'Classic connection RSSI (relative range, not dBm)'),
                  'raw_rssi': self.machine.raw, 'median_rssi': self.machine.filtered,
                  'reading_age_seconds': None if self.machine.last_sample_at is None else
                      round((milliseconds() - self.machine.last_sample_at) / 1000, 1),
                  'reason': reason, 'sensor_reason': self.sensor_reason, 'counts': self.counts}
        if self.backend == 'bluetooth':
            status.update(self.worker.sensor.connection_status())
        try:
            temporary = str(self.state_path) + '.tmp'
            with open(temporary, 'w', encoding='utf-8') as output:
                json.dump(status, output)
                output.write('\n')
            os.replace(temporary, self.state_path)
        except OSError:
            self.log('WARN: unable to write private runtime status.')

    def _tick(self):
        now = time.monotonic()
        offset = sleep_offset()
        if now - self.last_tick > 15 or abs(offset - self.sleep_delta) > 2:
            self.invalidate('Suspend or scheduler gap detected; fresh arming required.')
        self.last_tick, self.sleep_delta = now, offset
        if self.paused or self.sleeping:
            if self.worker.dirty:
                self.worker.submit(lambda _: None, measure=False)
        elif now >= self.next_sample:
            if self.worker.submit(self._received):
                self.next_sample = now + self.config['POLL_SECONDS']
        self.machine.tick(milliseconds(), False)
        self._status()
        return GLib.SOURCE_CONTINUE

    def _shutdown(self):
        self.stopping = True
        self.worker.invalidate()
        self.loop.quit()
        return GLib.SOURCE_CONTINUE

    def start(self):
        def subscribe(sender, iface, signal_name, path, callback, arg0=None, bus=None):
            bus = bus or self.system_bus
            self.subscriptions.append((bus, bus.signal_subscribe(sender, iface, signal_name,
                path, arg0, Gio.DBusSignalFlags.NONE, callback)))
        subscribe('org.freedesktop.login1', 'org.freedesktop.login1.Manager', 'PrepareForSleep',
                  '/org/freedesktop/login1', self._prepare_for_sleep)
        if self.backend == 'gsconnect':
            subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
                      '/org/freedesktop/DBus', self._gsconnect_changed, GSCONNECT, self.desktop.bus)
            subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
                      '/org/freedesktop/DBus', self._gsconnect_changed, NM)
            subscribe(GSCONNECT, PROPERTIES, 'PropertiesChanged', None, self._gsconnect_changed, bus=self.desktop.bus)
            for signal_name in ('InterfacesAdded', 'InterfacesRemoved'):
                subscribe(GSCONNECT, OBJECT_MANAGER, signal_name, GSCONNECT_PATH, self._gsconnect_changed, bus=self.desktop.bus)
            subscribe(NM, PROPERTIES, 'PropertiesChanged', NM_PATH, self._gsconnect_changed)
        else:
            subscribe('org.freedesktop.DBus', 'org.freedesktop.DBus', 'NameOwnerChanged',
                      '/org/freedesktop/DBus', self._bluez_changed, BLUEZ)
            subscribe(BLUEZ, PROPERTIES, 'PropertiesChanged', None, self._bluez_changed)
            subscribe(BLUEZ, OBJECT_MANAGER, 'InterfacesRemoved', '/', self._bluez_changed)
        for sig, callback in ((signal.SIGUSR1, self._pause), (signal.SIGUSR2, self._resume),
                              (signal.SIGTERM, self._shutdown), (signal.SIGINT, self._shutdown),
                              (signal.SIGHUP, self._shutdown)):
            self.sources.append(GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, sig, callback))
        self.sources.append(GLib.timeout_add_seconds(1, self._tick))
        if self.duration:
            self.sources.append(GLib.timeout_add_seconds(self.duration, self._shutdown))
        self.log(f'Backend: {self.backend}. ' + ('Dry run; locking disabled.' if self.dry_run else 'Automatic locking active; waiting for fresh presence checks.'))
        self._tick()
        try:
            self.loop.run()
        finally:
            for bus, subscription in self.subscriptions:
                bus.signal_unsubscribe(subscription)
            for source in self.sources:
                GLib.source_remove(source)
            self.worker.close()
            self.machine.unknown('Monitor stopped; no automatic locking.')
            self.inhibited = ''
            self.health = 'unknown'
            self._status()
        self.log(f'Run summary: elapsed={time.monotonic() - self.started:.1f}s; ' + json.dumps(self.counts, sort_keys=True))
        return 0 if self.counts['measured'] or self.counts['connected'] else 1


def doctor(config):
    """A connection sample and desktop checks; never invokes a lock method."""
    print('Doctor: no lock requests; device identifiers are redacted.', flush=True)
    problem = lock_settings_problem()
    if problem:
        print('ERROR: ' + problem)
    desktop = Desktop(Gio.bus_get_sync(Gio.BusType.SESSION, None))
    loop = GLib.MainLoop()
    results = {}

    def record(key, value):
        results[key] = value
        if len(results) == 2:
            loop.quit()
    desktop.idle(lambda value: record('idle', value))
    desktop.active(lambda value: record('active', value))
    loop.run()
    print('GNOME idle API: ' + ('available (milliseconds)' if results['idle'] is not None else 'unavailable'))
    print('GNOME lock-state API: ' + ('available' if results['active'] is not None else 'unavailable'))
    system_bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
    backend = config['BACKEND']
    sensor = (GSConnectSensor(desktop.bus, system_bus, config['GSCONNECT_DEVICE_ID'], config['GSCONNECT_DEVICE_NAME'])
              if backend == 'gsconnect' else ConnectionSensor(BluezTarget(system_bus, config['PHONE_ADDRESS'])))
    try:
        sample = sensor.sample()
        if sample.kind == 'measured':
            try:
                sensor._healthy()
            except (SensorError, OSError):
                sample = Sample('unknown', 'Local controller health read failed; absence detection is not ready on this kernel/controller.')
    finally:
        sensor.close()
    print(f'{backend}: {sample.kind}; {sample.reason}')
    if sample.rssi is not None:
        print(f'Connection RSSI: {sample.rssi} (Classic relative range, not dBm). Zero is valid.')
    ready = not problem and None not in results.values() and sample.kind in ('measured', 'connected')
    print('Diagnostic succeeded; background and departure tests are still required.' if ready else
          ('NOT READY: open KDE Connect on the paired phone, connect it to the laptop in GSConnect, then retry.' if backend == 'gsconnect' else
           'NOT READY: bring the paired phone nearby with Bluetooth on, resolve diagnostics, then retry.'))
    if backend == 'bluetooth':
        print('This one-shot check closes its own Bluetooth channel on exit. Use --dry-run for continuous connection/reconnection testing.')
    return 0 if ready else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', default=str(Path.home() / '.config/dynamic_lock/config'))
    parser.add_argument('--state')
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument('--doctor', action='store_true')
    modes.add_argument('--dry-run', action='store_true')
    modes.add_argument('--probe', action='store_true')
    modes.add_argument('--check-config', action='store_true')
    modes.add_argument('--setup', action='store_true', help='select a paired phone for the configured backend and save its identity privately')
    parser.add_argument('--duration', type=int, default=0, help='dry-run duration in seconds (0 = until interrupted)')
    args = parser.parse_args()
    if args.duration < 0 or args.duration > 86400 or (args.duration and not (args.dry_run or args.probe)):
        parser.error('--duration requires --dry-run or --probe and must be 0..86400 seconds')
    os.umask(0o077)
    try:
        config = read_config(args.config, require_phone=not (args.check_config or args.setup))
        if args.check_config:
            print('Configuration syntax and permissions valid. No hardware check performed.')
            return 0
        runtime = Path(os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')) / 'dynamic-lock'
        runtime.mkdir(mode=0o700, parents=False, exist_ok=True)
        if runtime.stat().st_uid != os.getuid() or runtime.stat().st_mode & 0o077:
            raise ConfigError('Runtime directory must belong to you with mode 700.')
        with open(runtime / 'monitor.lock', 'a', encoding='ascii') as lock_file:
            try:
                fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ConfigError('Another monitor or diagnostic is running. Stop it or use --disable before a new probe.') from None
            # A doctor/setup can hold the same lock without publishing monitor
            # state. Identify the owner so status cannot reuse another run's data.
            lock_file.seek(0)
            lock_file.truncate()
            lock_file.write(str(os.getpid()) + '\n')
            lock_file.flush()
            if args.doctor:
                return doctor(config)
            if args.setup:
                if config['BACKEND'] == 'bluetooth':
                    bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
                    objects = bus.call_sync(BLUEZ, '/', OBJECT_MANAGER, 'GetManagedObjects', None, None,
                        Gio.DBusCallFlags.NO_AUTO_START, 1500, None).unpack()[0]
                    target = select_paired_phone(objects, config['PHONE_ADDRESS'])
                    save_bluetooth_selection(args.config, target.address)
                    print('Selected paired Bluetooth phone; address saved privately. Automatic locking remains disabled.')
                    return 0
                sensor = GSConnectSensor(Gio.bus_get_sync(Gio.BusType.SESSION, None), None)
                objects = sensor._call(sensor.session_bus, GSCONNECT, GSCONNECT_PATH, OBJECT_MANAGER, 'GetManagedObjects')[0]
                _, props = select_phone(objects, config['GSCONNECT_DEVICE_ID'], config['GSCONNECT_DEVICE_NAME'])
                save_gsconnect_selection(args.config, props['Id'])
                print('Selected paired GSConnect phone; identity saved privately. BACKEND=gsconnect. No locking enabled.')
                print('Phone is connected.' if props['Connected'] else 'Phone is disconnected: open KDE Connect on the phone and connect to this laptop.')
                return 0
            monitor = Monitor(config, state_path=args.state or runtime / 'state',
                              dry_run=args.dry_run or args.probe,
                              duration=args.duration or (30 if args.probe else 0))
            return monitor.start()
    except (ConfigError, SensorError) as error:
        print('ERROR: ' + str(error), file=sys.stderr)
    except (GLib.Error, OSError):
        print('ERROR: cannot access runtime directory or desktop/system bus. Run from your GNOME user session and check --doctor.', file=sys.stderr)
    return 1


if __name__ == '__main__':
    raise SystemExit(main())
