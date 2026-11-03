#!/usr/bin/env python3
"""Verify and, if needed, add one preselected internal TestFlight build."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.request import Request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from verify_testflight import BASE, Client, Retry, Unknown, attributes

APP = '6755509363'
GROUP = 'close door'
VERSION = '0.0.6'
BUILD = '43'
MAIN = '7e58715ec391dbd2ea236ac5e0e9a3820e851785'
ID = re.compile(r'^[A-Za-z0-9-]{1,100}$')


class Pending(Exception):
    pass


def safe_id(row):
    value = row.get('id') if isinstance(row, dict) else None
    if not isinstance(value, str) or not ID.fullmatch(value):
        raise Unknown('A required Apple resource ID is unavailable')
    return value


def current_main():
    try:
        out = subprocess.run(['git', 'ls-remote', 'https://github.com/GodisinHisHeaven/ohMyTss.git',
                              'refs/heads/main'], capture_output=True, text=True, timeout=20, check=True)
    except (OSError, subprocess.SubprocessError):
        raise Unknown('Could not verify the current main branch') from None
    if out.stdout.strip().split() != [MAIN, 'refs/heads/main']:
        raise Unknown('Main changed after the release archive was created')


def read_state(client, required_audience='INTERNAL_ONLY'):
    groups = client.all('/v1/apps/' + APP + '/betaGroups?limit=200')
    matches = [row for row in groups if attributes(row).get('name') == GROUP]
    if len(matches) != 1 or attributes(matches[0]).get('isInternalGroup') is not True:
        raise Unknown('The target must be one unique internal group')
    group = safe_id(matches[0])
    group_auto = attributes(matches[0]).get('hasAccessToAllBuilds')
    if not isinstance(group_auto, bool):
        raise Unknown('Automatic internal-group access is unknown')
    builds = client.all('/v1/apps/' + APP + '/builds?limit=200')
    candidates = []
    for row in builds:
        if attributes(row).get('version') != BUILD:
            continue
        build = safe_id(row)
        version = attributes(client.get('/v1/builds/' + build + '/preReleaseVersion').get('data'))
        if version.get('version') == VERSION and version.get('platform') == 'IOS':
            candidates.append(row)
    if not candidates:
        return {'group': group, 'auto': group_auto, 'build': None, 'linked': False, 'state': 'NOT_PROCESSED'}
    if len(candidates) != 1:
        raise Unknown('The requested app version and build are ambiguous')
    row = candidates[0]
    build = safe_id(row)
    detail = client.get('/v1/builds/' + build).get('data')
    if safe_id(detail) != build:
        raise Unknown('Apple returned a different build')
    values = attributes(detail)
    if values.get('version') != BUILD:
        raise Unknown('Build identity differs')
    if values.get('expired') is True or values.get('processingState') in {'FAILED', 'INVALID'}:
        raise Unknown('The requested build is expired or invalid')
    if values.get('processingState') != 'VALID' or values.get('expired') is not False:
        raise Pending('Apple is processing the build')
    if values.get('buildAudienceType') != required_audience:
        raise Unknown('Build audience differs from the expected audience')
    linked = any(safe_id(b) == build for b in client.all('/v1/betaGroups/' + group + '/builds?limit=200'))
    beta = attributes(client.get('/v1/builds/' + build + '/buildBetaDetail').get('data'))
    state = beta.get('internalBuildState')
    if state in {'PROCESSING_EXCEPTION', 'MISSING_EXPORT_COMPLIANCE', 'EXPIRED', 'IN_EXPORT_COMPLIANCE_REVIEW'}:
        raise Unknown('Apple reports the build requires attention: ' + state)
    if state == 'PROCESSING':
        raise Pending('Apple is preparing the build for internal testing')
    if state not in {'READY_FOR_BETA_TESTING', 'IN_BETA_TESTING'}:
        raise Unknown('Apple returned an unknown internal testing state')
    return {'group': group, 'auto': group_auto, 'build': build, 'linked': linked, 'state': state}


def add_to_group(client, state):
    if not state.get('build') or state.get('linked') is not False or state.get('auto') is not False:
        raise Unknown('Build must be valid and absent from the target group before assignment')
    group, build = state.get('group'), state.get('build')
    if not isinstance(group, str) or not ID.fullmatch(group) or not isinstance(build, str) or not ID.fullmatch(build):
        raise Unknown('Unsafe build or group identifier')
    current_main()
    client.get('/v1/builds/' + build)  # Refresh the API token immediately before the write.
    body = json.dumps({'data': [{'type': 'builds', 'id': build}]}).encode()
    request = Request(BASE + '/v1/betaGroups/' + group + '/relationships/builds', data=body, method='POST',
                      headers={'Authorization': 'Bearer ' + client.token, 'Content-Type': 'application/json'})
    try:
        with client.opener.open(request, timeout=15) as response:
            if response.status != 204:
                raise Unknown('Group assignment outcome is unknown; inspect before retrying')
    except HTTPError as exc:
        if exc.code in (400, 401, 403, 404, 409, 422):
            raise Unknown('Group assignment was rejected (HTTP %d)' % exc.code) from None
        raise Unknown('Group assignment outcome is unknown; inspect before retrying') from None
    except (URLError, TimeoutError, OSError):
        raise Unknown('Group assignment outcome is unknown; inspect before retrying') from None


def main():
    mode = os.environ.get('VERIFY_MODE', '')
    credentials = [os.environ.get(n) for n in ('ASC_ISSUER_ID', 'ASC_KEY_ID', 'ASC_PRIVATE_KEY')]
    if mode not in {'inspect', 'distribute'} or not all(credentials):
        raise Unknown('Missing credentials or an unsupported verification mode')
    current_main()
    client = Client(*credentials, deadline=time.monotonic() + 1850)
    deadline = time.monotonic() + (1800 if mode == 'distribute' else 60)
    assigned = False
    last = None
    while time.monotonic() < deadline:
        try:
            state = read_state(client)
            status = (state['build'] is not None, state['linked'], state['state'], state['auto'])
            if status != last:
                print('Build found:', status[0], 'in internal group:', status[1],
                      'internal state:', status[2], 'group auto access:', status[3], flush=True)
                last = status
            if mode == 'inspect':
                return
            if state['linked'] and state['state'] == 'IN_BETA_TESTING':
                current_main()
                print('VERIFIED: 0.0.6 (43) is available to the internal close door group', flush=True)
                return
            if state['build'] and not state['linked'] and state['auto'] is False and not assigned:
                add_to_group(client, state)
                assigned = True
                print('Added verified internal build to close door; waiting for Apple processing', flush=True)
        except (Pending, Retry) as exc:
            if str(exc) != last:
                print('Waiting:', str(exc), flush=True)
                last = str(exc)
        time.sleep(30)
    raise Unknown('Timed out waiting for internal TestFlight availability')


if __name__ == '__main__':
    try:
        main()
    except Unknown as exc:
        print('Verification failed:', str(exc), file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print('Verification failed:', type(exc).__name__, file=sys.stderr)
        sys.exit(1)
