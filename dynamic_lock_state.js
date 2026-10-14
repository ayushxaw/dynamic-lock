// Pure proximity state machine. No D-Bus or desktop calls, so behavior can be
// exercised with synthetic RSSI samples in tests.
var ProximityMachine = class ProximityMachine {
    constructor(options = {}) {
        this.dropDb = options.dropDb ?? 10;
        this.staleMs = (options.staleSeconds ?? 15) * 1000;
        this.awayMs = (options.awaySeconds ?? 30) * 1000;
        this.returnMs = (options.returnSeconds ?? 5) * 1000;
        this.armSamples = options.armSamples ?? 3;
        this.historyLimit = options.historyLimit ?? 5;
        this.reset();
    }

    reset() {
        this.history = [];
        this.lastSampleAt = null;
        this.baseline = null;
        this.armed = false;
        this.awaySince = null;
        this.returnSince = null;
        this.lockedOnce = false;
        this.lockFailures = 0;
        this.nextLockRetryAt = null;
        this.state = 'WAITING_FOR_NEAR';
    }

    observe(rssi, nowMs) {
        if (!Number.isInteger(rssi) || rssi < -127 || rssi > 20)
            return this.state;

        this.lastSampleAt = nowMs;
        this.history.push(rssi);
        if (this.history.length > this.historyLimit)
            this.history.shift();

        const smooth = this._median(this.history);
        if (!this.armed) {
            if (this.history.length >= this.armSamples) {
                this.armed = true;
                this.baseline = smooth;
                this.state = 'NEAR_ARMED';
            }
            return this.state;
        }

        const returnThreshold = this.baseline - (this.dropDb / 2);
        if (smooth > returnThreshold) {
            if (this.returnSince === null)
                this.returnSince = nowMs;
            if (nowMs - this.returnSince >= this.returnMs) {
                this.awaySince = null;
                this.lockedOnce = false;
                this.lockFailures = 0;
                this.nextLockRetryAt = null;
                this.state = 'NEAR_ARMED';
                // Track improving near readings without following a weakening
                // signal down and moving the departure threshold with it.
                if (smooth > this.baseline)
                    this.baseline = smooth;
            } else if (this.awaySince !== null) {
                this.state = 'RETURN_PENDING';
            }
        } else {
            // A partial recovery must not let an old away timer immediately
            // lock when the signal drops again.
            if (this.returnSince !== null && this.awaySince !== null)
                this.awaySince = nowMs;
            this.returnSince = null;
            if (this.awaySince === null)
                this.awaySince = nowMs;
            this.state = 'AWAY_PENDING';
        }
        return this.state;
    }

    tick(nowMs, isIdle) {
        if (!this.armed || this.lastSampleAt === null) {
            this.state = 'WAITING_FOR_NEAR';
            return {state: this.state, shouldLock: false};
        }

        if (nowMs - this.lastSampleAt > this.staleMs) {
            const staleAt = this.lastSampleAt + this.staleMs;
            if (this.returnSince !== null) {
                // The apparent return disappeared before it was confirmed.
                // Start a fresh grace period from this stale observation.
                this.returnSince = null;
                this.awaySince = nowMs;
            } else if (this.awaySince === null || this.awaySince < staleAt) {
                // A lone weak sample followed by a stalled scanner must not
                // retain its old timer. Confirm absence from the stale point.
                this.awaySince = staleAt;
            }
            this.state = 'AWAY_PENDING';
        }

        if (this.awaySince === null)
            return {state: this.state, shouldLock: false};

        if (this.returnSince !== null)
            return {state: 'RETURN_PENDING', shouldLock: false};

        if (nowMs - this.awaySince < this.awayMs)
            return {state: 'AWAY_PENDING', shouldLock: false};

        if (!isIdle) {
            this.state = 'AWAY_WAITING_FOR_IDLE';
            return {state: this.state, shouldLock: false};
        }

        if (this.nextLockRetryAt !== null && nowMs < this.nextLockRetryAt)
            return {state: 'LOCK_FAILED', shouldLock: false};

        if (this.lockedOnce)
            return {state: 'LOCKED_AWAY', shouldLock: false};

        this.state = 'LOCK_REQUESTED';
        this.lockedOnce = true;
        return {state: this.state, shouldLock: true};
    }

    lockFailed(nowMs) {
        this.lockedOnce = false;
        this.lockFailures++;
        const backoffMs = Math.min(300000, 10000 * (2 ** (this.lockFailures - 1)));
        this.nextLockRetryAt = nowMs + backoffMs;
        this.state = 'LOCK_FAILED';
    }

    _median(values) {
        const sorted = [...values].sort((a, b) => a - b);
        return sorted[Math.floor(sorted.length / 2)];
    }
};
