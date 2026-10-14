"""Pure state machine for a lock-only Bluetooth presence monitor."""


class PresenceMachine:
    def __init__(self, *, away_seconds=30, return_seconds=5, arm_checks=3):
        self.away_ms = away_seconds * 1000
        self.return_ms = return_seconds * 1000
        self.arm_checks = arm_checks
        self.reset()

    def reset(self):
        self.near_checks = 0
        self.armed = False
        self.away_since = None
        self.return_since = None
        self.locked_once = False
        self.lock_failures = 0
        self.next_lock_retry_at = None
        self.state = "WAITING_FOR_NEAR"

    def observe(self, present, now_ms):
        if not self.armed:
            if present:
                self.near_checks += 1
                if self.near_checks >= self.arm_checks:
                    self.armed = True
                    self.state = "NEAR_ARMED"
            else:
                self.near_checks = 0
            return self.state

        if present:
            if self.return_since is None:
                self.return_since = now_ms
            if now_ms - self.return_since >= self.return_ms:
                self.away_since = None
                self.return_since = None
                self.locked_once = False
                self.lock_failures = 0
                self.next_lock_retry_at = None
                self.state = "NEAR_ARMED"
            elif self.away_since is not None:
                self.state = "RETURN_PENDING"
        else:
            if self.return_since is not None and self.away_since is not None:
                self.away_since = now_ms
            self.return_since = None
            if self.away_since is None:
                self.away_since = now_ms
            self.state = "AWAY_PENDING"
        return self.state

    def tick(self, now_ms, is_idle):
        if not self.armed:
            self.state = "WAITING_FOR_NEAR"
            return {"state": self.state, "should_lock": False}

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
