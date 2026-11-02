#!/usr/bin/env python3
"""Read-only checks of synthetic simulator stores; fail closed on schema drift."""
import hashlib, json, sqlite3, sys, uuid
from pathlib import Path


def connection(path):
    return sqlite3.connect(Path(path).resolve().as_uri() + '?mode=ro', uri=True)


def scalar(value):
    if isinstance(value, bytes):
        return {'sha256': hashlib.sha256(value).hexdigest(), 'length': len(value)}
    return value


def rows_by_id(db, table):
    # Core Data bookkeeping may change on write; all model columns must survive.
    columns = [r[1] for r in db.execute(f'PRAGMA table_info({table})') if r[1] not in ('Z_PK', 'Z_OPT', 'Z_ENT')]
    assert 'ZID' in columns, (table, columns)
    rows = {}
    for values in db.execute(f'SELECT {",".join(columns)} FROM {table}'):
        row = dict(zip(columns, values))
        key = row['ZID'].hex() if isinstance(row['ZID'], bytes) else str(row['ZID'])
        assert key not in rows, (table, key)
        rows[key] = {k: scalar(v) for k, v in row.items()}
    return rows


def inspect(path, strength_count=1):
    with connection(path) as db:
        assert db.execute('PRAGMA integrity_check').fetchone() == ('ok',)
        workouts = {}
        for sid, tags, features in db.execute('SELECT ZID,ZUSERTAGS,ZFEATURESDATA FROM ZWORKOUT'):
            assert sid not in workouts
            workouts[sid] = {'tags': scalar(tags), 'features': scalar(features)}
        ids = sorted(workouts)
        assert len(ids) == 1000 and ids == sorted(f'synthetic-launch-{i}' for i in range(1000))
        assert all(isinstance(x['features'], dict) and x['features']['length'] > 10000 for x in workouts.values())
        assert workouts['synthetic-launch-0']['tags'] != workouts['synthetic-launch-1']['tags'], 'sentinel tag missing'
        estimates = rows_by_id(db, 'ZLOADESTIMATERECORD')
        assert len(estimates) >= 1000
        strength = rows_by_id(db, 'ZSTRENGTHSETRECORD')
        observation = rows_by_id(db, 'ZLOCALOBSERVATION')
        assert len(strength) == strength_count and len(observation) == 1
        sentinels = [row for row in strength.values() if row.get('ZSESSIONID') == 'synthetic-launch-0' and row.get('ZWEIGHTKG') == 42]
        assert len(sentinels) == 1, 'expected one original strength sentinel'
        setrow = sentinels[0]; obsrow = next(iter(observation.values()))
        assert setrow.get('ZSESSIONID') == 'synthetic-launch-0' and setrow.get('ZREPS') == 8 and setrow.get('ZEXERCISEID') == 'squat'
        assert obsrow.get('ZSESSIONID') == 'synthetic-launch-0' and obsrow.get('ZSEVERITY') == 2 and obsrow.get('ZNOTE') == 'synthetic sentinel note'
        thresholds = db.execute('SELECT ZCARDIOMAXHEARTRATE FROM ZUSERTHRESHOLDS').fetchall()
        assert len(thresholds) == 1
        latest = {}
        for session, computed, payload in db.execute('SELECT ZSESSIONID,ZCOMPUTEDAT,ZINPUTDATA FROM ZLOADESTIMATERECORD'):
            if session not in latest or computed > latest[session][0]:
                latest[session] = (computed, [payload])
            elif computed == latest[session][0]:
                latest[session][1].append(payload)
        return {'workouts': workouts, 'estimates': estimates, 'strength': strength,
                'observation': observation, 'threshold': thresholds[0][0]}, latest


cmd, source, out = sys.argv[1:4]
if cmd == 'backup':
    with connection(source) as src, sqlite3.connect(out) as dest:
        src.backup(dest)
    baseline, _ = inspect(out)
    Path(out + '.baseline.json').write_text(json.dumps(baseline, sort_keys=True))
    print('Synthetic seed verified: 1000 workouts with dense HR, 1000+ estimates, user tag, set and observation')
elif cmd == 'verify-seed':
    baseline = json.loads(Path(out).read_text())
    current, _ = inspect(source)
    assert current == baseline, 'staged synthetic seed differs from verified baseline'
    print('Staged synthetic seed matches all verified baseline fields')
elif cmd == 'verify':
    baseline = json.loads(Path(out).read_text())
    current, latest = inspect(source)
    assert current['workouts'] == baseline['workouts'], 'workout IDs, personal tags or original features changed'
    for eid, row in baseline['estimates'].items():
        assert current['estimates'].get(eid) == row, f'old estimate changed or lost: {eid}'
    assert current['strength'] == baseline['strength'], 'personal strength set changed or lost'
    assert current['observation'] == baseline['observation'], 'personal observation changed or lost'
    assert current['threshold'] == 180, f"unexpected saved maximum HR: {current['threshold']}"
    assert len(latest) == 1000
    for sid in baseline['workouts']:
        for payload in latest[sid][1]:
            assert payload, f'missing latest input snapshot: {sid}'
            assert json.loads(payload).get('maxHeartRate') == 180, f'outdated latest input: {sid}'
    print('Verified all source features and tags, every old estimate field, set and observation; latest input HR 180')
elif cmd == 'verify-extended':
    baseline = json.loads(Path(out).read_text())
    current, latest = inspect(source, strength_count=21)
    assert current['workouts'] == baseline['workouts'], 'original workouts, tags or features changed'
    assert current['observation'] == baseline['observation'], 'personal observation changed or lost'
    assert current['threshold'] == 180, 'saved maximum HR changed'
    for eid, row in baseline['estimates'].items():
        assert current['estimates'].get(eid) == row, f'old estimate changed or lost: {eid}'
    for sid, row in baseline['strength'].items():
        assert current['strength'].get(sid) == row, f'old strength set changed or lost: {sid}'
    additions = {sid: row for sid, row in current['strength'].items() if sid not in baseline['strength']}
    assert len(additions) == 20, f'expected exactly 20 new sets, found {len(additions)}'
    for row in additions.values():
        assert row['ZSESSIONID'] == 'synthetic-launch-0' and row['ZEXERCISEID'] == 'squat'
        assert row['ZREPS'] == 8 and row['ZWEIGHTKG'] is None and row['ZRIR'] is None
    assert len(latest) == 1000
    for sid in baseline['workouts']:
        for payload in latest[sid][1]:
            assert payload and json.loads(payload).get('maxHeartRate') == 180, f'outdated latest input: {sid}'
    expected_ids = {uuid.UUID(hex=sid) for sid in current['strength']}
    for payload in latest['synthetic-launch-0'][1]:
        sets = json.loads(payload).get('sets')
        assert isinstance(sets, list) and len(sets) == 21
        actual_ids = [uuid.UUID(item['id']) for item in sets]
        assert len(set(actual_ids)) == 21 and set(actual_ids) == expected_ids, 'latest estimate omits or duplicates sets'
    print('Verified 20 unique new sets, all original data and estimates, and latest input includes 21 unique sets')
else:
    raise SystemExit('Unexpected command')
