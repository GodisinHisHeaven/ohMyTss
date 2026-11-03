"""Read only the current app's TestFlight build numbers and internal group."""
import os
import sys
import time
from verify_testflight import Client, Unknown, attributes, resource_id


def main():
    keys = [os.environ.get(name) for name in ('ASC_ISSUER_ID', 'ASC_KEY_ID', 'ASC_PRIVATE_KEY')]
    if not all(keys):
        raise Unknown('App Store Connect credentials are missing')
    client = Client(*keys, deadline=time.monotonic() + 300)
    app_id = '6755509363'
    groups = client.all('/v1/apps/' + app_id + '/betaGroups?limit=200')
    matching = [g for g in groups if attributes(g).get('name') == 'close door']
    if len(matching) != 1 or attributes(matching[0]).get('isInternalGroup') is not True:
        raise Unknown('Expected exactly one internal close door group')
    print('Internal TestFlight group: verified')
    uploads = client.all('/v1/apps/' + app_id + '/buildUploads?limit=200')
    ios = []
    for upload in uploads:
        a = attributes(upload)
        if a.get('cfBundleShortVersionString') == '0.0.6' and a.get('platform') == 'IOS':
            ios.append((a.get('cfBundleVersion'), a.get('state'), a.get('uploadedDate'), a.get('createdDate'), upload))
    if not ios or any(not isinstance(x[0], str) or not x[0].isdigit() for x in ios):
        raise Unknown('Could not establish numeric build numbers for iOS 0.0.6')
    print('Highest iOS 0.0.6 build number:', max(int(x[0]) for x in ios))
    for number, state, uploaded, created, row in ios[:8]:
        print('Build:', number, 'state:', state, 'uploaded:', uploaded, 'created:', created)
        if number == '43' and isinstance(state, dict) and state.get('state') == 'AWAITING_UPLOAD':
            files = client.all('/v1/buildUploads/' + resource_id(row) + '/buildUploadFiles?limit=200')
            statuses = [(attributes(f).get('assetDeliveryState') or {}).get('state') for f in files]
            print('Pending Build 43 reserved file count:', len(files), 'delivery states:', statuses)


if __name__ == '__main__':
    try:
        main()
    except Unknown as exc:
        print('Inventory failed:', str(exc), file=sys.stderr)
        sys.exit(1)
    except Exception as exc:
        print('Inventory failed:', type(exc).__name__, file=sys.stderr)
        sys.exit(1)
