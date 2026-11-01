#!/usr/bin/env python3
"""Atomically install verified synthetic store into the dedicated simulator."""
import contextlib, os, shutil, sqlite3, subprocess, sys, tempfile
from pathlib import Path

source, dest, container, results, checker = map(Path, sys.argv[1:])
print(f'Synthetic store preflight: source_exists={source.is_file()}, source_readable={os.access(source, os.R_OK)}, '
      f'destination_exists={dest.is_file()}, parent_exists={dest.parent.is_dir()}, '
      f'parent_writable={os.access(dest.parent, os.W_OK)}', flush=True)
source = source.resolve(strict=True)
container = container.resolve(strict=True)
results = results.resolve(strict=True)
parent = dest.parent.resolve(strict=True)
dest = parent / dest.name
assert source.parent == results and source.name == 'old-synthetic.store'
assert parent == container / 'Library' / 'Application Support' and dest.name == 'default.store'
assert dest.is_file() and not dest.is_symlink(), 'Expected the dedicated simulator default store'
free = shutil.disk_usage(parent).free
size = source.stat().st_size
print(f'Synthetic store diagnostics: source_bytes={size}, destination_parent_exists={parent.is_dir()}, '
      f'destination_parent_writable={os.access(parent, os.W_OK)}, free_bytes={free}', flush=True)
assert free >= 2 * size + 32 * 1024 * 1024, 'Insufficient free space for staged synthetic store'
phase = 'create staging file'
stage = None
try:
    fd, stage_name = tempfile.mkstemp(prefix='.synthetic-release-stage-', suffix='.store', dir=parent)
    os.close(fd)
    stage = Path(stage_name)
    phase = 'open synthetic source read-only'
    with contextlib.closing(sqlite3.connect(source.as_uri() + '?mode=ro', uri=True)) as src:
        src.execute('PRAGMA query_only=ON')
        assert src.execute('PRAGMA integrity_check').fetchone() == ('ok',)
        phase = 'open destination staging file'
        with contextlib.closing(sqlite3.connect(stage)) as out:
            phase = 'backup synthetic source into destination staging file'
            src.backup(out)
            phase = 'check staged SQLite integrity and checkpoint'
            assert out.execute('PRAGMA integrity_check').fetchone() == ('ok',)
            mode = out.execute('PRAGMA journal_mode=DELETE').fetchone()[0]
            assert mode.lower() == 'delete', f'Unexpected stage journal mode: {mode}'
    phase = 'verify staged model data against synthetic baseline'
    subprocess.run([sys.executable, str(checker), 'verify-seed', str(stage), str(source)+'.baseline.json'], check=True)
    phase = 'replace dedicated simulator default store'
    # The simulator app has been terminated. Remove only sidecars of its old
    # empty store after the staged synthetic replacement is fully verified.
    for suffix in ('-wal', '-shm'):
        try: os.remove(str(dest) + suffix)
        except FileNotFoundError: pass
    os.replace(stage, dest)
    stage = None
    phase = 'verify installed synthetic store'
    subprocess.run([sys.executable, str(checker), 'verify-seed', str(dest), str(source)+'.baseline.json'], check=True)
    print('Installed verified synthetic store in dedicated simulator container', flush=True)
except Exception as error:
    print(f'Synthetic store install failed at phase={phase}; type={type(error).__name__}; '
          f'errno={getattr(error, "errno", None)}; sqlite_code={getattr(error, "sqlite_errorcode", None)}; '
          f'sqlite_name={getattr(error, "sqlite_errorname", None)}', file=sys.stderr, flush=True)
    raise
finally:
    if stage is not None:
        for suffix in ('', '-wal', '-shm', '-journal'):
            try: os.remove(str(stage) + suffix)
            except FileNotFoundError: pass
