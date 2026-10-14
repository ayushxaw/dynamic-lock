#!/usr/bin/env gjs
imports.searchPath.unshift('.');
const {ProximityMachine} = imports.dynamic_lock_state;

function assert(condition, message) {
    if (!condition)
        throw new Error(message);
}

function armedMachine() {
    const machine = new ProximityMachine({dropDb: 10, staleSeconds: 15, awaySeconds: 30, returnSeconds: 5});
    machine.observe(-50, 0);
    machine.observe(-51, 1000);
    machine.observe(-49, 2000);
    assert(machine.armed, 'three nearby samples should arm');
    return machine;
}

function testRequiresNearBeforeAwayLock() {
    const machine = new ProximityMachine({awaySeconds: 1});
    const result = machine.tick(100000, true);
    assert(!result.shouldLock, 'must not lock before first near readings');
    assert(result.state === 'WAITING_FOR_NEAR', 'initial state should be safe and explicit');
}

function testSustainedDropAndIdleGate() {
    const machine = armedMachine();
    machine.observe(-65, 3000);
    machine.observe(-65, 4000);
    machine.observe(-65, 5000);
    assert(machine.state === 'AWAY_PENDING', 'sustained RSSI drop should become pending');

    let result = machine.tick(34000, false);
    assert(!result.shouldLock, 'must wait for full away confirmation');
    result = machine.tick(50000, false);
    assert(result.state === 'AWAY_WAITING_FOR_IDLE' && !result.shouldLock,
        'must not lock while user is active');
    result = machine.tick(50000, true);
    assert(result.shouldLock, 'confirmed away plus idle should request one lock');
    result = machine.tick(51000, true);
    assert(!result.shouldLock, 'must not issue duplicate locks in one away episode');
}

function testStaleReportsRequireTimeoutAndAwayConfirmation() {
    const machine = armedMachine();
    let result = machine.tick(17001, true);
    assert(!result.shouldLock && result.state === 'AWAY_PENDING',
        'stale RSSI should begin, not immediately trigger, departure confirmation');
    result = machine.tick(46999, true);
    assert(!result.shouldLock, 'confirmation must be measured after staleness');
    result = machine.tick(47000, true);
    assert(result.shouldLock, 'stale reports plus healthy monitor and idle should lock after grace');
}

function testFreshWeakSampleAfterGapIsNotMaskedByOldNearbyReadings() {
    const machine = armedMachine();
    assert(!machine.tick(17001, true).shouldLock, 'stale readings should only start departure confirmation');
    machine.observe(-92, 18001);
    assert(machine.state === 'AWAY_PENDING', 'a fresh weak sample must not be masked by old near samples');
    assert(machine.history.length === 1, 'fresh samples after a long gap should restart the median window');
    assert(machine.tick(48002, true).shouldLock, 'confirmed weak signal can lock after the away period');
}

function testReturnRearmsWithoutUnlocking() {
    const machine = armedMachine();
    machine.observe(-65, 3000);
    machine.observe(-65, 4000);
    machine.observe(-65, 5000);
    assert(machine.tick(50000, true).shouldLock, 'departure should lock after stale and away confirmation');
    machine.observe(-49, 51000);
    machine.observe(-49, 54000);
    machine.observe(-49, 57000);
    machine.observe(-49, 60000);
    machine.observe(-49, 62000);
    assert(machine.state === 'NEAR_ARMED' && !machine.lockedOnce,
        'stable return should re-arm the next departure without unlocking the session');
}

function testLockFailureCanRetry() {
    const machine = armedMachine();
    machine.observe(-65, 3000);
    machine.observe(-65, 4000);
    machine.observe(-65, 5000);
    assert(machine.tick(50000, true).shouldLock, 'first lock should be requested after stale and away confirmation');
    machine.lockFailed(50000);
    assert(!machine.tick(59999, true).shouldLock, 'failed lock should wait for its retry backoff');
    assert(machine.tick(60000, true).shouldLock, 'failed lock should retry after ten seconds');
}

function testPartialReturnDoesNotReuseOldDepartureTimer() {
    const machine = new ProximityMachine({dropDb: 10, staleSeconds: 15, awaySeconds: 30, returnSeconds: 5, historyLimit: 1, armSamples: 1});
    machine.observe(-50, 0);
    machine.observe(-50, 1000);
    machine.observe(-50, 2000);
    machine.observe(-65, 3000);
    machine.observe(-65, 4000);
    machine.observe(-65, 5000);
    assert(!machine.tick(32000, true).shouldLock, 'away confirmation is not yet complete');
    machine.observe(-49, 32001);
    assert(!machine.tick(34000, true).shouldLock, 'partial return must suppress locking');
    machine.observe(-65, 35000);
    assert(!machine.tick(35001, true).shouldLock, 'drop after partial return starts a fresh grace period');
    assert(!machine.tick(64999, true).shouldLock, 'fresh away grace period must complete');
    assert(machine.tick(65000, true).shouldLock, 'fresh away grace period eventually permits locking');
}

function testStalePartialReturnRestartsAwayGrace() {
    const machine = new ProximityMachine({dropDb: 10, staleSeconds: 15, awaySeconds: 30, returnSeconds: 5, historyLimit: 1, armSamples: 1});
    machine.observe(-50, 0);
    machine.observe(-65, 3000);
    machine.observe(-49, 32000);
    assert(!machine.tick(34000, true).shouldLock, 'unconfirmed return must suppress a pending lock');
    assert(!machine.tick(48001, true).shouldLock, 'stale return must start a fresh away grace period');
    assert(!machine.tick(78000, true).shouldLock, 'fresh grace period must not expire early');
    assert(machine.tick(78001, true).shouldLock, 'fresh grace period eventually permits locking');
}

function testInvalidRSSIIsIgnored() {
    const machine = armedMachine();
    const state = machine.state;
    machine.observe(1000, 5000);
    assert(machine.state === state, 'invalid RSSI must not mutate state');
}

const tests = [
    testRequiresNearBeforeAwayLock,
    testSustainedDropAndIdleGate,
    testStaleReportsRequireTimeoutAndAwayConfirmation,
    testFreshWeakSampleAfterGapIsNotMaskedByOldNearbyReadings,
    testReturnRearmsWithoutUnlocking,
    testLockFailureCanRetry,
    testPartialReturnDoesNotReuseOldDepartureTimer,
    testStalePartialReturnRestartsAwayGrace,
    testInvalidRSSIIsIgnored,
];

for (const test of tests) {
    test();
    print(`PASS ${test.name}`);
}
print(`${tests.length} tests passed`);
