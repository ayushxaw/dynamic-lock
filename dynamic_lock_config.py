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
    'AWAY_CONFIRM_SECONDS': (30, 10, 300),
    'RETURN_CONFIRM_SECONDS': (5, 1, 60),
    'IDLE_AFTER_SECONDS': (1, 0, 3600),
    'POLL_SECONDS': (5, 2, 10),
}
OBSOLETE = {'RSSI_DROP_DB', 'GSCONNECT_DEVICE_NAME', 'DEVICE_ID', 'DEVICE_NAME'}


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
            print(f'WARN: {key} is obsolete and ignored. Connection RSSI uses explicit near/away thresholds.', file=sys.stderr)
            continue
        if key not in SETTINGS and key not in ('PHONE_ADDRESS', 'LOCK_CMD'):
            print(f'WARN: unknown config key on line {number}; ignored.', file=sys.stderr)
            continue
        if key in values:
            raise ConfigError(f'Duplicate config setting on line {number}.')
        if len(value) >= 2 and value[0] == value[-1] and value[0] in '\"\'':
            value = value[1:-1]
        values[key] = value
    config = {'PHONE_ADDRESS': values.get('PHONE_ADDRESS', '').upper(), 'LOCK_CMD': values.get('LOCK_CMD', '')}
    for key, (default, minimum, maximum) in SETTINGS.items():
        try:
            value = int(values.get(key, default))
        except ValueError as error:
            raise ConfigError(f'{key} must be an integer; default is {default}.') from error
        if not minimum <= value <= maximum:
            raise ConfigError(f'{key} must be between {minimum} and {maximum}; default is {default}.')
        config[key] = value
    address = config['PHONE_ADDRESS']
    if address and not re.fullmatch(r'(?:[0-9A-F]{2}:){5}[0-9A-F]{2}', address):
        raise ConfigError('PHONE_ADDRESS must be the paired phone Bluetooth address (six hex pairs separated by colons).')
    if require_phone and not address:
        raise ConfigError('Set PHONE_ADDRESS in ~/.config/dynamic_lock/config after pairing your phone in Ubuntu Bluetooth settings.')
    if config['RSSI_AWAY_THRESHOLD'] >= config['RSSI_NEAR_THRESHOLD']:
        raise ConfigError('RSSI_AWAY_THRESHOLD must be lower than RSSI_NEAR_THRESHOLD.')
    if config['RSSI_STALE_SECONDS'] < 2 * config['POLL_SECONDS']:
        raise ConfigError('RSSI_STALE_SECONDS must allow at least two POLL_SECONDS intervals.')
    try:
        shlex.split(config['LOCK_CMD'])
    except ValueError as error:
        raise ConfigError('LOCK_CMD has unmatched quotes; use an executable and arguments, without shell syntax.') from error
    return config
