"""Deterministic proximity decisions. Times are monotonic milliseconds.

No clock, Bluetooth, desktop, or locking side effects live here. UNKNOWN is a
loss of evidence, never evidence of departure. Thresholds are Classic RSSI.
"""

from collections import deque
from statistics import median


class PresenceMachine:
    def __init__(self, *, near_threshold=-5, away_threshold=-10, stale_seconds=15,
                 away_seconds=30, return_seconds=5, arm_seconds=10):
        if away_threshold >= near_threshold:
            raise ValueError('away threshold must be lower than near threshold')
        self.near_threshold = near_threshold
        self.away_threshold = away_threshold
        self.stale_ms = stale_seconds * 1000
        self.away_ms = away_seconds * 1000
        self.return_ms = return_seconds * 1000
        self.arm_ms = arm_seconds * 1000
        self.reset()

    def reset(self, reason='Waiting for three fresh near readings spanning at least ten seconds.'):
        self.history = deque(maxlen=3)
        self.last_sample_at = None
        self.raw = self.filtered = None
        self.armed = False
        self.near_since = self.return_since = self.away_since = None
        self.near_count = self.away_count = 0
        self.away_kind = None
        self.locked_once = self.lock_in_flight = False
        self.lock_failures = 0
        self.next_lock_retry_at = 0
        self.state = 'WAITING_FOR_NEAR'
        self.reason = reason
        self.kind = 'unknown'

    def unknown(self, reason):
        self.reset(reason)
        self.state = 'UNKNOWN'

    def _cancel_away(self):
        self.away_since = None
        self.away_count = 0
        self.away_kind = None
        self.next_lock_retry_at = 0
        self.lock_failures = 0

    def observe(self, rssi, now_ms):
        return self.accept('measured', now_ms, rssi)

    def accept(self, kind, now_ms, rssi=None, reason=''):
        if kind not in ('measured', 'absent') or (kind == 'measured' and
                (type(rssi) is not int or not -127 <= rssi <= 126)):
            self.unknown(reason or 'No usable connection measurement; fresh arming required.')
            return self.state
        if self.last_sample_at is not None:
            gap = now_ms - self.last_sample_at
            if gap <= 0:
                self.unknown('Duplicate or out-of-order reading; fresh arming required.')
                return self.state
            if gap > self.stale_ms:
                self.unknown('Readings expired; fresh arming required.')
        self.last_sample_at = now_ms
        self.kind = kind
        self.raw = rssi if kind == 'measured' else None
        if kind == 'absent':
            self.history.clear()
            self.filtered = None
            classification = 'away'
        else:
            self.history.append((now_ms, rssi))
            while self.history and now_ms - self.history[0][0] > self.stale_ms:
                self.history.popleft()
            self.filtered = median(value for _, value in self.history) if len(self.history) == 3 else None
            # A single non-away reading immediately cancels pending departure,
            # even when the median still reflects earlier weak readings.
            classification = 'band'
            if rssi >= self.near_threshold:
                classification = 'near' if self.filtered is not None and self.filtered >= self.near_threshold else 'warming'
            elif rssi <= self.away_threshold and self.filtered is not None and self.filtered <= self.away_threshold:
                classification = 'away'

        if not self.armed:
            if classification in ('near', 'warming'):
                if self.near_since is None:
                    self.near_since = now_ms
                self.near_count = min(3, self.near_count + 1)
                if (classification == 'near' and self.near_count >= 3
                        and now_ms - self.near_since >= self.arm_ms):
                    self.armed = True
                    self.state = 'NEAR_ARMED'
                    self.reason = 'Fresh nearby connection readings; ready to detect departure.'
                    return self.state
            else:
                self.near_since = None
                self.near_count = 0
            self.state = 'WAITING_FOR_NEAR'
            self.reason = 'Startup/recovery requires fresh near readings; absence alone cannot arm.'
            return self.state

        if classification == 'away':
            self.return_since = None
            if self.away_since is None or self.away_kind != kind:
                self.away_since = now_ms
                self.away_count = 0
                self.away_kind = kind
            self.away_count = min(3, self.away_count + 1)
            self.state = 'LOCKED_AWAY' if self.locked_once else 'AWAY_PENDING'
            self.reason = 'Waiting for sustained weak signal or repeated healthy-controller connection timeouts.'
        else:
            self._cancel_away()
            if classification == 'near':
                if self.return_since is None:
                    self.return_since = now_ms
                if now_ms - self.return_since >= self.return_ms:
                    self.locked_once = False
                    self.state = 'NEAR_ARMED'
                    self.reason = 'Nearby return confirmed; ready for the next departure.'
                else:
                    self.state = 'RETURN_PENDING'
                    self.reason = 'Confirming a stable nearby return; no unlock is performed.'
            else:
                self.return_since = None
                self.state = 'SIGNAL_UNCERTAIN'
                self.reason = 'Signal between thresholds or warming filter; pending transitions cancelled.'
        return self.state

    def eligible(self, now_ms):
        if self.last_sample_at is not None and now_ms - self.last_sample_at > self.stale_ms:
            self.unknown('Readings expired; no lock without fresh evidence.')
        return (self.armed and self.away_since is not None and self.away_count >= 3
                and self.last_sample_at - self.away_since >= self.away_ms
                and not self.locked_once and not self.lock_in_flight
                and now_ms >= self.next_lock_retry_at)

    def tick(self, now_ms, is_idle):
        should_lock = False
        if self.eligible(now_ms):
            if is_idle:
                self.lock_in_flight = True
                self.state = 'LOCK_REQUESTED'
                self.reason = 'Fresh departure evidence and GNOME idle confirmation; lock requested.'
                should_lock = True
            else:
                self.state = 'AWAY_WAITING_FOR_IDLE'
                self.reason = 'Departure confirmed; waiting for GNOME idle confirmation.'
        elif self.away_since is not None and self.next_lock_retry_at > now_ms:
            self.state = 'LOCK_FAILED'
            self.reason = 'Lock retry delayed; fresh departure evidence is still required.'
        return {'state': self.state, 'should_lock': should_lock}

    def lock_succeeded(self):
        self.lock_in_flight = False
        self.locked_once = True
        self.state = 'LOCKED_AWAY'
        self.reason = 'Lock confirmed (or dry-run decision); waiting for a stable nearby return.'

    def lock_failed(self, now_ms):
        self.lock_in_flight = False
        self.lock_failures = min(self.lock_failures + 1, 6)
        self.next_lock_retry_at = now_ms + min(300000, 10000 * 2 ** (self.lock_failures - 1))
        self.state = 'LOCK_FAILED'
        self.reason = 'Lock could not be confirmed; retrying with bounded backoff while departure stays confirmed.'
