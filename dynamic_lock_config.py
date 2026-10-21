"""Private data-only configuration; never source shell syntax."""

import os
import re
import shlex
import stat
import sys


class ConfigError(Exception):
    pass


SETTINGS = {
    'RSSI_NEAR_THRESHOLD': (-5, -126, 126),
    'RSSI_AWAY_THRESHOLD': (-10, -127, 125),
    'RSSI_STALE_SECONDS': (15, 10, 60),
    'STATUS_STALE_SECONDS': (15, 10, 60),
    'AWAY_CONFIRM_SECONDS': (30, 10, 300),
    'RETURN_CONFIRM_SECONDS': (5, 1, 60),
    'IDLE_AFTER_SECONDS': (1, 0, 3600),
    'POLL_SECONDS': (5, 2, 10),
}
OBSOLETE = {'RSSI_DROP_DB', 'DEVICE_ID', 'DEVICE_NAME'}
TEXT_SETTINGS = {'PHONE_ADDRESS', 'LOCK_CMD', 'BACKEND', 'GSCONNECT_DEVICE_ID', 'GSCONNECT_DEVICE_NAME'}


def read_config(path, require_phone=True):
    try:
        with open(path, encoding='utf-8') as source:
            info = os.fstat(source.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size > 65536:
                raise ConfigError('Config must be a small regular file.')
            if info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise ConfigError('Private config must belong to you with mode 600; run chmod 600 ~/.config/dynamic_lock/config.')
            lines = source.readlines()
    except (OSError, UnicodeError) as error:
        raise ConfigError('Cannot read private config; run install.sh and edit ~/.config/dynamic_lock/config.') from error
    values = {}
    for number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if '=' not in line:
            raise ConfigError(f'Malformed config line {number}; expected KEY=value.')
        key, value = (part.strip() for part in line.split('=', 1))
        if key in OBSOLETE:
            print(f'WARN: {key} is obsolete and ignored.', file=sys.stderr)
            continue
        if key not in SETTINGS and key not in TEXT_SETTINGS:
            print(f'WARN: unknown config key on line {number}; ignored.', file=sys.stderr)
            continue
        if key in values:
            raise ConfigError(f'Duplicate config setting on line {number}.')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '\"\'':
            value = value[1:-1]
        values[key] = value
    config = {key: values.get(key, '') for key in TEXT_SETTINGS}
    config['PHONE_ADDRESS'] = config['PHONE_ADDRESS'].upper()
    config['BACKEND'] = values.get('BACKEND', 'bluetooth').lower()
    if config['BACKEND'] not in ('gsconnect', 'bluetooth'):
        raise ConfigError('BACKEND must be gsconnect or bluetooth.')
    bluetooth = config['BACKEND'] == 'bluetooth'
    for key, (default, minimum, maximum) in SETTINGS.items():
        # Inactive radio thresholds must not block the GSConnect integration.
        raw = default if key.startswith('RSSI_') and not bluetooth else values.get(key, default)
        try:
            value = int(raw)
        except ValueError as error:
            raise ConfigError(f'{key} must be an integer; default is {default}.') from error
        if not minimum <= value <= maximum:
            raise ConfigError(f'{key} must be between {minimum} and {maximum}; default is {default}.')
        config[key] = value
    address = config['PHONE_ADDRESS']
    if bluetooth and address and not re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', address):
        raise ConfigError('PHONE_ADDRESS must be the paired phone Bluetooth address (six hex pairs separated by colons).')
    if bluetooth and require_phone and not address:
        raise ConfigError('Set PHONE_ADDRESS in ~/.config/dynamic_lock/config after pairing your phone in Ubuntu Bluetooth settings.')
    if bluetooth and config['RSSI_AWAY_THRESHOLD'] >= config['RSSI_NEAR_THRESHOLD']:
        raise ConfigError('RSSI_AWAY_THRESHOLD must be lower than RSSI_NEAR_THRESHOLD.')
    stale_key = 'RSSI_STALE_SECONDS' if bluetooth else 'STATUS_STALE_SECONDS'
    if config[stale_key] < 2 * config['POLL_SECONDS']:
        raise ConfigError(f'{stale_key} must allow at least two POLL_SECONDS intervals.')
    try:
        shlex.split(config['LOCK_CMD'])
    except ValueError as error:
        raise ConfigError('LOCK_CMD has unmatched quotes; use an executable and arguments, without shell syntax.') from error
    for key in ('GSCONNECT_DEVICE_ID', 'GSCONNECT_DEVICE_NAME'):
        if any(ord(char) < 32 for char in config[key]) or len(config[key]) > 256:
            raise ConfigError(f'{key} must be a single short line of text.')
    return config


def save_gsconnect_selection(path, device_id):
    """Explicit setup changes two data fields; preserve the other private settings."""
    if not device_id or device_id.strip() != device_id or len(device_id) > 256 or any(ord(c) < 32 for c in device_id):
        raise ConfigError('GSConnect returned an invalid device identity; configuration was not changed.')
    _save_selection(path, {'BACKEND': 'gsconnect', 'GSCONNECT_DEVICE_ID': device_id})


def save_bluetooth_selection(path, address):
    if not re.fullmatch(r'(?:[0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}', address):
        raise ConfigError('BlueZ returned an invalid Bluetooth identity; configuration was not changed.')
    _save_selection(path, {'BACKEND': 'bluetooth', 'PHONE_ADDRESS': address.upper()})


def _save_selection(path, changes):
    with open(path, encoding='utf-8') as source:
        lines = source.read().splitlines()
    for index, line in enumerate(lines):
        key = line.split('=', 1)[0].strip()
        if key in changes:
            lines[index] = key + '=' + changes.pop(key)
    lines.extend(key + '=' + value for key, value in changes.items())
    temporary = str(path) + '.setup.tmp'
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write('\n'.join(lines) + '\n')
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
