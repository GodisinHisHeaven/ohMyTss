import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import URLError

PATH = Path(__file__).resolve().parents[1] / 'verify_direct_testflight.py'
SPEC = importlib.util.spec_from_file_location('direct_testflight', PATH)
direct = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(direct)


class Response:
    status = 204

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False


class Opener:
    def __init__(self):
        self.requests = []
        self.error = None

    def open(self, request, timeout):
        self.requests.append(request)
        if self.error:
            raise self.error
        return Response()


class FakeClient:
    token = 'synthetic-token'

    def __init__(self):
        self.group = {'id': 'group-1', 'attributes': {'name': direct.GROUP, 'isInternalGroup': True,
                                                     'hasAccessToAllBuilds': False}}
        self.build = {'id': 'build-1', 'attributes': {'version': direct.BUILD, 'processingState': 'VALID',
                                                     'expired': False, 'buildAudienceType': 'INTERNAL_ONLY'}}
        self.groups = [self.group]
        self.builds = [self.build]
        self.linked = []
        self.beta_state = 'READY_FOR_BETA_TESTING'
        self.pre_version = {'version': direct.VERSION, 'platform': 'IOS'}
        self.opener = Opener()

    def all(self, path):
        if path == '/v1/apps/' + direct.APP + '/betaGroups?limit=200':
            return self.groups
        if path == '/v1/apps/' + direct.APP + '/builds?limit=200':
            return self.builds
        if path == '/v1/betaGroups/group-1/builds?limit=200':
            return self.linked
        raise AssertionError(path)

    def get(self, path):
        if path == '/v1/builds/build-1/preReleaseVersion':
            return {'data': {'attributes': self.pre_version}}
        if path == '/v1/builds/build-1/buildBetaDetail':
            return {'data': {'attributes': {'internalBuildState': self.beta_state}}}
        if path == '/v1/builds/build-1':
            return {'data': self.build}
        raise AssertionError(path)


class DirectTestFlightTests(unittest.TestCase):
    def setUp(self):
        self.client = FakeClient()

    def test_missing_build_is_read_only(self):
        self.client.builds = []
        state = direct.read_state(self.client)
        self.assertIsNone(state['build'])
        self.assertEqual(state['state'], 'NOT_PROCESSED')
        self.assertFalse(self.client.opener.requests)

    def test_requires_unique_internal_group(self):
        self.client.group['attributes']['isInternalGroup'] = False
        with self.assertRaises(direct.Unknown):
            direct.read_state(self.client)
        self.assertFalse(self.client.opener.requests)

    def test_rejects_other_marketing_version_or_non_internal_audience(self):
        self.client.pre_version['version'] = '0.0.7'
        self.assertIsNone(direct.read_state(self.client)['build'])
        self.client.pre_version['version'] = direct.VERSION
        self.client.build['attributes']['buildAudienceType'] = 'APP_STORE_ELIGIBLE'
        with self.assertRaises(direct.Unknown):
            direct.read_state(self.client)
        self.assertFalse(self.client.opener.requests)

    def test_pending_processing_is_not_assigned(self):
        self.client.build['attributes']['processingState'] = 'PROCESSING'
        self.client.build['attributes']['buildAudienceType'] = None
        with self.assertRaises(direct.Pending):
            direct.read_state(self.client)
        self.assertFalse(self.client.opener.requests)

    def test_other_audience_is_only_accepted_when_explicitly_requested(self):
        self.client.build['attributes']['buildAudienceType'] = 'APP_STORE_ELIGIBLE'
        with self.assertRaises(direct.Unknown):
            direct.read_state(self.client)
        state = direct.read_state(self.client, required_audience='APP_STORE_ELIGIBLE')
        self.assertEqual(state['build'], 'build-1')
        self.assertFalse(self.client.opener.requests)

    def test_mismatched_build_detail_is_rejected(self):
        original = self.client.get
        def mismatched(path):
            if path == '/v1/builds/build-1':
                return {'data': {'id': 'different', 'attributes': self.client.build['attributes']}}
            return original(path)
        self.client.get = mismatched
        with self.assertRaises(direct.Unknown):
            direct.read_state(self.client)
        self.assertFalse(self.client.opener.requests)

    def test_valid_build_is_linked_once_to_selected_group(self):
        state = direct.read_state(self.client)
        with patch.object(direct, 'current_main'):
            direct.add_to_group(self.client, state)
        self.assertEqual(len(self.client.opener.requests), 1)
        request = self.client.opener.requests[0]
        self.assertEqual(request.full_url, direct.BASE + '/v1/betaGroups/group-1/relationships/builds')
        self.assertEqual(request.get_method(), 'POST')
        self.assertEqual(json.loads(request.data), {'data': [{'type': 'builds', 'id': 'build-1'}]})

    def test_existing_link_and_changed_main_prevent_writes(self):
        self.client.linked = [self.client.build]
        state = direct.read_state(self.client)
        with self.assertRaises(direct.Unknown):
            direct.add_to_group(self.client, state)
        self.client.linked = []
        state = direct.read_state(self.client)
        with patch.object(direct, 'current_main', side_effect=direct.Unknown('changed')):
            with self.assertRaises(direct.Unknown):
                direct.add_to_group(self.client, state)
        self.assertFalse(self.client.opener.requests)

    def test_automatic_group_access_never_attempts_manual_assignment(self):
        self.client.group['attributes']['hasAccessToAllBuilds'] = True
        state = direct.read_state(self.client)
        with self.assertRaises(direct.Unknown):
            direct.add_to_group(self.client, state)
        self.assertFalse(self.client.opener.requests)

    def test_uncertain_post_is_not_retried(self):
        state = direct.read_state(self.client)
        self.client.opener.error = URLError('synthetic failure')
        with patch.object(direct, 'current_main'):
            with self.assertRaises(direct.Unknown):
                direct.add_to_group(self.client, state)
        self.assertEqual(len(self.client.opener.requests), 1)


if __name__ == '__main__':
    unittest.main()
