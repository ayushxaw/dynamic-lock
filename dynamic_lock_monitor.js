#!/usr/bin/env gjs
// GNOME/BlueZ event monitor. Bluetooth and idle state are observed over D-Bus;
// there is no periodic bluetoothctl process or network dependency.
const {Gio, GLib} = imports.gi;
const System = imports.system;
const ByteArray = imports.byteArray;
const {ProximityMachine} = imports.dynamic_lock_state;

const BLUEZ = 'org.bluez';
const DEVICE_IFACE = 'org.bluez.Device1';
const ADAPTER_IFACE = 'org.bluez.Adapter1';
const PROPERTIES_IFACE = 'org.freedesktop.DBus.Properties';
const MUTTER_IDLE = 'org.gnome.Mutter.IdleMonitor';
const MUTTER_PATH = '/org/gnome/Mutter/IdleMonitor/Core';

function usageError(message) {
    printerr(`ERROR: ${message}`);
    System.exit(1);
}

function readConfig(path) {
    let contents;
    try {
        contents = ByteArray.toString(GLib.file_get_contents(path)[1]);
    } catch (error) {
        usageError(`Cannot read config ${path}: ${error.message}`);
    }

    const allowed = new Set([
        'PHONE_ADDRESS', 'RSSI_DROP_DB', 'RSSI_STALE_SECONDS',
        'AWAY_CONFIRM_SECONDS', 'RETURN_CONFIRM_SECONDS',
        'IDLE_AFTER_SECONDS', 'LOCK_CMD',
    ]);
    const config = {};
    for (const [index, raw] of contents.split(/\r?\n/).entries()) {
        const line = raw.trim();
        if (!line || line.startsWith('#'))
            continue;
        const equal = line.indexOf('=');
        if (equal < 1) {
            printerr(`WARN: ignoring malformed config line ${index + 1}`);
            continue;
        }
        const key = line.slice(0, equal).trim();
        let value = line.slice(equal + 1).trim();
        if ((value.startsWith('"') && value.endsWith('"')) ||
            (value.startsWith("'") && value.endsWith("'")))
            value = value.slice(1, -1);
        if (!allowed.has(key)) {
            printerr(`WARN: ignoring unknown config key ${key}`);
            continue;
        }
        config[key] = value;
    }

    if (!config.PHONE_ADDRESS)
        usageError(`Set PHONE_ADDRESS in ${path} to the paired phone's Bluetooth address. See README setup steps.`);
    if (!/^([0-9a-f]{2}:){5}[0-9a-f]{2}$/i.test(config.PHONE_ADDRESS))
        usageError('PHONE_ADDRESS must be a Bluetooth address like AA:BB:CC:DD:EE:FF.');

    const integerSettings = {
        RSSI_DROP_DB: [10, 3, 30],
        RSSI_STALE_SECONDS: [15, 5, 120],
        AWAY_CONFIRM_SECONDS: [30, 5, 300],
        RETURN_CONFIRM_SECONDS: [5, 1, 60],
        IDLE_AFTER_SECONDS: [1, 0, 3600],
    };
    for (const [key, [fallback, minimum, maximum]] of Object.entries(integerSettings)) {
        const raw = config[key] ?? String(fallback);
        if (!/^-?\d+$/.test(raw)) {
            printerr(`WARN: ${key} is not an integer; using ${fallback}`);
            config[key] = fallback;
        } else {
            const parsed = Number(raw);
            if (!Number.isSafeInteger(parsed) || parsed < minimum || parsed > maximum) {
                printerr(`WARN: ${key} must be ${minimum}–${maximum}; using ${fallback}`);
                config[key] = fallback;
            } else {
                config[key] = parsed;
            }
        }
    }
    return config;
}

function plain(value) {
    return value instanceof GLib.Variant ? value.deep_unpack() : value;
}

function prop(properties, name) {
    if (!properties || !(name in properties))
        return undefined;
    return plain(properties[name]);
}

function processSucceeded(argv) {
    try {
        const process = Gio.Subprocess.new(
            ['timeout', '5', ...argv],
            Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE
        );
        return process.wait_check(null);
    } catch (_error) {
        return false;
    }
}

function lockSession(customCommand) {
    if (customCommand) {
        let argv;
        try {
            const [success, parsed] = GLib.shell_parse_argv(customCommand);
            if (success)
                argv = parsed;
        } catch (_error) {
            printerr('ERROR: LOCK_CMD could not be parsed; using GNOME lock methods.');
        }
        if (Array.isArray(argv) && argv.length && processSucceeded(argv))
            return true;
    }

    const methods = [
        ['loginctl', 'lock-session'],
        ['gdbus', 'call', '--session', '--dest', 'org.gnome.ScreenSaver',
            '--object-path', '/org/gnome/ScreenSaver', '--method', 'org.gnome.ScreenSaver.Lock'],
        ['xdg-screensaver', 'lock'],
    ];
    return methods.some(method => processSucceeded(method));
}

class Monitor {
    constructor(config, stateFile, probeOnly) {
        this.config = config;
        this.stateFile = stateFile;
        this.probeOnly = probeOnly;
        this.connection = Gio.bus_get_sync(Gio.BusType.SYSTEM, null);
        this.manager = Gio.DBusProxy.new_sync(
            this.connection,
            Gio.DBusProxyFlags.DO_NOT_AUTO_START,
            null,
            BLUEZ,
            '/',
            'org.freedesktop.DBus.ObjectManager',
            null
        );
        this.machine = new ProximityMachine({
            dropDb: config.RSSI_DROP_DB,
            staleSeconds: config.RSSI_STALE_SECONDS,
            awaySeconds: config.AWAY_CONFIRM_SECONDS,
            returnSeconds: config.RETURN_CONFIRM_SECONDS,
        });
        this.loop = new GLib.MainLoop(null, false);
        this.devicePath = null;
        this.adapterPath = null;
        this.ownsDiscovery = false;
        this.previousState = '';
        this.paused = false;
        this.sleeping = false;
        this.lastTick = GLib.get_monotonic_time();
        this.fatal = false;
    }

    start() {
        this._subscribe();
        this._attachExistingDevice();
        this._startDiscovery();
        this._signals();
        this._writeState('WAITING_FOR_NEAR', 'Waiting for paired phone signal');
        print(this.probeOnly
            ? 'Probe active: showing RSSI and GNOME idle state; no lock commands will run.'
            : 'Monitor active: waiting for stable near readings before arming.');
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 1, () => this._tick());
        this.loop.run();
        this._stopDiscovery();
        return this.fatal ? 1 : 0;
    }

    _objects() {
        const result = this.manager.call_sync(
            'GetManagedObjects', null, Gio.DBusCallFlags.NONE, 5000, null
        ).deep_unpack()[0];
        return result;
    }

    _subscribe() {
        this.connection.signal_subscribe(
            BLUEZ,
            PROPERTIES_IFACE,
            'PropertiesChanged',
            null,
            null,
            Gio.DBusSignalFlags.NONE,
            (_connection, _sender, path, _interface, _signal, parameters) => {
                const [iface, changed] = parameters.deep_unpack();
                if (iface === DEVICE_IFACE && path === this.devicePath) {
                    const rssi = prop(changed, 'RSSI');
                    if (Number.isInteger(rssi)) {
                        const state = this.machine.observe(rssi, GLib.get_monotonic_time() / 1000);
                        if (this.probeOnly)
                            print(`RSSI ${rssi} dBm; filtered state ${state}`);
                    }
                } else if (iface === ADAPTER_IFACE && path === this.adapterPath) {
                    if (prop(changed, 'Powered') === false) {
                        this._fail('Bluetooth adapter was powered off; monitoring stopped safely.');
                    } else if (prop(changed, 'Discovering') === false && !this.paused && !this.sleeping) {
                        this._fail('Bluetooth discovery stopped unexpectedly; monitoring stopped safely.');
                    }
                }
            }
        );
        this.connection.signal_subscribe(
            'org.freedesktop.DBus',
            'org.freedesktop.DBus',
            'NameOwnerChanged',
            '/org/freedesktop/DBus',
            null,
            Gio.DBusSignalFlags.NONE,
            (_connection, _sender, _path, _interface, _signal, parameters) => {
                const [name, oldOwner, newOwner] = parameters.deep_unpack();
                if (name === BLUEZ && oldOwner && !newOwner)
                    this._fail('BlueZ stopped; monitoring stopped safely. Restart the service after Bluetooth returns.');
            }
        );
        this.connection.signal_subscribe(
            'org.freedesktop.login1',
            'org.freedesktop.login1.Manager',
            'PrepareForSleep',
            '/org/freedesktop/login1',
            null,
            Gio.DBusSignalFlags.NONE,
            (_connection, _sender, _path, _interface, _signal, parameters) => {
                const [preparing] = parameters.deep_unpack();
                if (preparing) {
                    this.sleeping = true;
                    this.machine.reset();
                    this._stopDiscovery();
                    this._writeState('SUSPENDED', 'System is suspending; monitoring will re-arm after wake');
                    this._log('Suspend detected; cleared proximity readings.');
                } else {
                    this.sleeping = false;
                    this.machine.reset();
                    this._writeState('WAITING_FOR_NEAR', 'Woke from suspend; waiting for fresh near readings');
                    this._log('Resume detected; waiting for Bluetooth discovery before re-arming.');
                    this._resumeDiscovery();
                }
            }
        );
    }

    _attachExistingDevice() {
        const objects = this._objects();
        const wanted = this.config.PHONE_ADDRESS.toLowerCase();
        for (const [path, interfaces] of Object.entries(objects)) {
            const device = interfaces[DEVICE_IFACE];
            if (!device)
                continue;
            if (String(prop(device, 'Address') ?? '').toLowerCase() !== wanted)
                continue;
            if (prop(device, 'Paired') !== true)
                usageError('The configured phone is not paired in BlueZ. Pair it in GNOME Settings → Bluetooth first.');
            this.devicePath = path;
            this.adapterPath = prop(device, 'Adapter');
            break;
        }
        if (!this.devicePath)
            usageError('Configured phone is not known to BlueZ. Pair it in GNOME Settings → Bluetooth, then update PHONE_ADDRESS.');
    }

    _startDiscovery() {
        if (this.ownsDiscovery)
            return;
        const objects = this._objects();
        const adapter = objects[this.adapterPath]?.[ADAPTER_IFACE];
        if (!adapter || prop(adapter, 'Powered') !== true)
            throw new Error('Bluetooth adapter is unavailable or powered off. Enable Bluetooth and retry.');
        try {
            const proxy = Gio.DBusProxy.new_sync(
                this.connection, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
                BLUEZ, this.adapterPath, ADAPTER_IFACE, null
            );
            // BlueZ normally suppresses RSSI PropertiesChanged signals until
            // the signal changes by a controller-dependent delta. A minimal
            // RSSI filter disables that suppression so the state machine can
            // smooth real samples rather than mistaking quiet updates for loss.
            const filter = Object.create(null);
            filter.RSSI = new GLib.Variant('n', -127);
            try {
                proxy.call_sync(
                    'SetDiscoveryFilter', new GLib.Variant('(a{sv})', [filter]),
                    Gio.DBusCallFlags.NONE, 5000, null
                );
            } catch (error) {
                throw new Error(`Could not configure Bluetooth RSSI reporting: ${error.message}`);
            }
            try {
                proxy.call_sync('StartDiscovery', null, Gio.DBusCallFlags.NONE, 5000, null);
                this.ownsDiscovery = true;
            } catch (error) {
                const name = error.dbus_error_name ?? '';
                const discovering = prop(adapter, 'Discovering') === true;
                if (discovering && name.endsWith('.InProgress'))
                    this.ownsDiscovery = true;
                else
                    throw new Error(`Could not start Bluetooth discovery: ${error.message}`);
            }
        } catch (error) {
            throw error;
        }
    }

    _resumeDiscovery() {
        let attempts = 0;
        const retry = () => {
            if (this.paused || this.sleeping)
                return GLib.SOURCE_REMOVE;
            attempts++;
            try {
                this._startDiscovery();
                this._log('Bluetooth discovery is active after resume.');
                return GLib.SOURCE_REMOVE;
            } catch (error) {
                if (attempts >= 6) {
                    this._fail(`Bluetooth did not recover after resume: ${error.message}`);
                    return GLib.SOURCE_REMOVE;
                }
                this._log(`Bluetooth is not ready after resume (attempt ${attempts}/6); retrying shortly.`);
                return GLib.SOURCE_CONTINUE;
            }
        };
        GLib.timeout_add_seconds(GLib.PRIORITY_DEFAULT, 2, retry);
    }

    _signals() {
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 10, () => {
            this.paused = true;
            this.machine.reset();
            this._stopDiscovery();
            this._writeState('PAUSED', 'Paused by user');
            print('Paused; monitoring will require fresh near readings when resumed.');
            return GLib.SOURCE_CONTINUE;
        });
        GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 12, () => {
            this.paused = false;
            this.machine.reset();
            try {
                this._startDiscovery();
            } catch (error) {
                this._fail(`Could not resume Bluetooth discovery: ${error.message}`);
            }
            this._writeState('WAITING_FOR_NEAR', 'Resumed; waiting for fresh near readings');
            print('Resumed; waiting for fresh near readings before arming.');
            return GLib.SOURCE_CONTINUE;
        });
        for (const signal of [2, 15, 1]) {
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal, () => {
                this.loop.quit();
                return GLib.SOURCE_REMOVE;
            });
        }
    }

    _stopDiscovery() {
        if (!this.ownsDiscovery || !this.connection || !this.adapterPath)
            return;
        try {
            const proxy = Gio.DBusProxy.new_sync(
                this.connection, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
                BLUEZ, this.adapterPath, ADAPTER_IFACE, null
            );
            proxy.call_sync('StopDiscovery', null, Gio.DBusCallFlags.NONE, 2000, null);
        } catch (_error) {
            // BlueZ releases this process's discovery session when D-Bus closes.
        }
        this.ownsDiscovery = false;
    }

    _tick() {
        if (this.paused || this.sleeping)
            return GLib.SOURCE_CONTINUE;

        const now = GLib.get_monotonic_time();
        if (now - this.lastTick > 30 * 1000 * 1000) {
            // A large monotonic-time gap means suspend/resume. Do not interpret
            // a long sleep as an absent phone; require fresh near reports.
            this.machine.reset();
            this._log('Wake/scheduler gap detected; cleared readings and re-arming from fresh data.');
        }
        this.lastTick = now;

        let result = this.machine.tick(now / 1000, false);
        if (result.state === 'AWAY_WAITING_FOR_IDLE') {
            const idleMs = this._idleMilliseconds();
            if (idleMs !== null) {
                const threshold = this.config.IDLE_AFTER_SECONDS * 1000;
                result = this.machine.tick(now / 1000, idleMs >= threshold);
                if (this.probeOnly)
                    print(`GNOME idle ${Math.floor(idleMs / 1000)}s; state ${result.state}`);
            }
        }

        if (result.state !== this.previousState) {
            this.previousState = result.state;
            this._writeState(result.state, this._stateDescription(result.state));
            this._log(`State: ${result.state}`);
        }

        if (result.shouldLock && !this.probeOnly) {
            this._log('Phone signal stayed away and the GNOME session is idle; requesting screen lock.');
            if (lockSession(this.config.LOCK_CMD ?? '')) {
                this._log('Screen lock command completed. Return proximity will re-arm; it will not unlock.');
                this._writeState('LOCKED_AWAY', 'Lock requested; waiting for phone return to re-arm');
            } else {
                this.machine.lockFailed(now / 1000);
                this._writeState('LOCK_FAILED', 'Lock command failed; check lock-session support and logs');
                this._log('ERROR: All screen-lock methods failed. From GNOME, test `loginctl lock-session`; if that fails, set LOCK_CMD to your desktop lock command and inspect the journal.');
            }
        }
        return GLib.SOURCE_CONTINUE;
    }

    _idleMilliseconds() {
        try {
            const proxy = Gio.DBusProxy.new_sync(
                Gio.DBus.session, Gio.DBusProxyFlags.DO_NOT_AUTO_START, null,
                MUTTER_IDLE, MUTTER_PATH, MUTTER_IDLE, null
            );
            const result = proxy.call_sync(
                'GetIdletime', null, Gio.DBusCallFlags.NONE, 1000, null
            );
            return Number(result.deep_unpack()[0]) / 1000;
        } catch (_error) {
            if (!this.idleWarningShown) {
                this.idleWarningShown = true;
                this._log('ERROR: GNOME idle monitor unavailable; refusing to lock without idle confirmation.');
            }
            return null;
        }
    }

    _stateDescription(state) {
        return ({
            WAITING_FOR_NEAR: 'Waiting for stable near readings to arm',
            NEAR_ARMED: 'Phone nearby; monitor armed',
            AWAY_PENDING: 'Phone signal low or stale; confirming departure',
            AWAY_WAITING_FOR_IDLE: 'Phone away; waiting for GNOME idle state',
            LOCK_REQUESTED: 'Screen lock requested',
            LOCKED_AWAY: 'Lock requested; waiting for phone return to re-arm',
            LOCK_FAILED: 'Screen lock failed; see service logs',
        })[state] ?? state;
    }

    _writeState(state, description) {
        if (!this.stateFile)
            return;
        const text = `State: ${state}\n${description}\n`;
        try {
            const temporary = `${this.stateFile}.tmp`;
            GLib.file_set_contents(temporary, text);
            GLib.rename(temporary, this.stateFile);
        } catch (error) {
            this._log(`WARN: Could not update runtime status: ${error.message}`);
        }
    }

    _log(message) {
        const line = `[dynamic_lock] ${message}`;
        print(line);
        try {
            const process = Gio.Subprocess.new(
                ['logger', '-t', 'dynamic_lock', message],
                Gio.SubprocessFlags.STDOUT_SILENCE | Gio.SubprocessFlags.STDERR_SILENCE
            );
            process.wait_async(null, () => {});
        } catch (_error) {
            // systemd captures stdout even when logger is unavailable.
        }
    }

    _fail(message) {
        this.fatal = true;
        this._log(`ERROR: ${message}`);
        this._writeState('UNKNOWN', message);
        this.loop.quit();
    }
}

function parseArgs(args) {
    let configPath = GLib.build_filenamev([GLib.get_home_dir(), '.config', 'dynamic_lock', 'config']);
    let stateFile = null;
    let probe = false;
    for (let i = 0; i < args.length; i++) {
        if (args[i] === '--config')
            configPath = args[++i];
        else if (args[i] === '--state')
            stateFile = args[++i];
        else if (args[i] === '--probe')
            probe = true;
        else
            usageError(`unknown monitor option ${args[i]}`);
    }
    return {configPath, stateFile, probe};
}

function main() {
    try {
        const args = parseArgs(ARGV);
        const config = readConfig(args.configPath);
        const monitor = new Monitor(config, args.stateFile, args.probe);
        System.exit(monitor.start());
    } catch (error) {
        usageError(`Monitor startup failed: ${error.message}`);
    }
}

main();
