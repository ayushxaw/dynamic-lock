"""Pure RSSI proximity state machine for the Dynamic Lock monitor."""


class PresenceMachine:
    def __init__(
        self,
        *,
        drop_db=10,
        stale_seconds=15,
        away_seconds=30,
        return_seconds=5,
        arm_samples=3,
        history_limit=5,
    ):
        self.drop_db = drop_db
        self.stale_ms = stale_seconds * 1000
        self.away_ms = away_seconds * 1000
        self.return_ms = return_seconds * 1000
        self.arm_samples = arm_samples
        self.history_limit = history_limit
        self.reset()

    def reset(self):
        self.history = []
        self.last_sample_at = None
        self.baseline = None
        self.armed = False
        self.away_since = None
        self.return_since = None
        self.locked_once = False
        self.lock_failures = 0
        self.next_lock_retry_at = None
        self.state = "WAITING_FOR_NEAR"

    def observe(self, rssi, now_ms):
        if not isinstance(rssi, int) or rssi < -127 or rssi > 20:
            return self.state

        self.last_sample_at = now_ms
        self.history.append(rssi)
        self.history = self.history[-self.history_limit :]
        smooth = self._median(self.history)

        if not self.armed:
            if len(self.history) >= self.arm_samples:
                self.armed = True
                self.baseline = smooth
                self.state = "NEAR_ARMED"
            return self.state

        away_threshold = self.baseline - self.drop_db
        return_threshold = self.baseline - (self.drop_db / 2)
        if smooth >= return_threshold:
            if self.return_since is None:
                self.return_since = now_ms
            if now_ms - self.return_since >= self.return_ms:
                self.away_since = None
                self.return_since = None
                self.locked_once = False
                self.lock_failures = 0
                self.next_lock_retry_at = None
                self.state = "NEAR_ARMED"
                if smooth > self.baseline:
                    self.baseline = smooth
            elif self.away_since is not None:
                self.state = "RETURN_PENDING"
        elif smooth <= away_threshold:
            # A weak report clears an incomplete return and restarts grace.
            if self.return_since is not None and self.away_since is not None:
                self.away_since = now_ms
            self.return_since = None
            if self.away_since is None:
                self.away_since = now_ms
            self.state = "AWAY_PENDING"
        # Readings in the hysteresis band keep the current state and timers.
        return self.state

    def tick(self, now_ms, is_idle):
        if not self.armed or self.last_sample_at is None:
            self.state = "WAITING_FOR_NEAR"
            return {"state": self.state, "should_lock": False}

        if now_ms - self.last_sample_at > self.stale_ms:
            stale_at = self.last_sample_at + self.stale_ms
            if self.return_since is not None:
                self.return_since = None
                self.away_since = now_ms
            elif self.away_since is None or self.away_since < stale_at:
                self.away_since = stale_at
            self.state = "AWAY_PENDING"

        if self.away_since is None:
            return {"state": self.state, "should_lock": False}
        if self.return_since is not None:
            return {"state": "RETURN_PENDING", "should_lock": False}
        if now_ms - self.away_since < self.away_ms:
            self.state = "AWAY_PENDING"
            return {"state": self.state, "should_lock": False}
        if self.locked_once:
            self.state = "LOCKED_AWAY"
            return {"state": self.state, "should_lock": False}
        if not is_idle:
            self.state = "AWAY_WAITING_FOR_IDLE"
            return {"state": self.state, "should_lock": False}
        if self.next_lock_retry_at is not None and now_ms < self.next_lock_retry_at:
            self.state = "LOCK_FAILED"
            return {"state": self.state, "should_lock": False}

        self.locked_once = True
        self.state = "LOCK_REQUESTED"
        return {"state": self.state, "should_lock": True}

    def lock_failed(self, now_ms):
        self.locked_once = False
        self.lock_failures += 1
        backoff_ms = min(300000, 10000 * (2 ** (self.lock_failures - 1)))
        self.next_lock_retry_at = now_ms + backoff_ms
        self.state = "LOCK_FAILED"

    @staticmethod
    def _median(values):
        ordered = sorted(values)
        return ordered[len(ordered) // 2]
