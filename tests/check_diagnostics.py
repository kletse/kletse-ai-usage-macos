#!/usr/bin/env python3
"""Run after swift build: python3 tests/check_diagnostics.py [path/to/AIUsage]."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else '.build/debug/AIUsage').resolve()
with tempfile.TemporaryDirectory(prefix='ai-usage-privacy-') as directory:
    root = Path(directory)
    config = root / 'accounts.json'
    # Loading this config must fail. Diagnostics must succeed without touching it.
    config.write_text('PRIVATE_CONFIG_SENTINEL: invalid JSON')
    env = {**os.environ, 'AI_USAGE_CONFIG': str(config)}

    def run(*args, code=0):
        result = subprocess.run([str(binary), *args], env=env, capture_output=True,
                                text=True, timeout=30)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert 'PRIVATE_CONFIG_SENTINEL' not in result.stdout + result.stderr
        assert str(config) not in result.stdout + result.stderr
        return result.stdout

    output = run('--dump')
    assert 'Sample data only' in output
    assert 'you@company.com' in output and 'you@example.com' in output
    assert output == run('--dump', '--sample')
    for command in ('--render-panel', '--render-menubar'):
        for extra in ([], ['--sample', '--dark']):
            image = root / (command + str(len(extra)) + '.png')
            run(command, str(image), *extra)
            assert image.read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
        run(command, code=2)
        run(command, '--dark', code=2)
        # Failed exports must not disclose the destination in their error output.
        destination = root / 'PRIVATE_PATH_SENTINEL' / 'out.png'
        failure = run(command, str(destination), code=1)
        assert failure == 'Could not write sample image.\n'
    run('--unknown', code=2)
    run('--dump', '--render-panel', 'out.png', code=2)
    assert config.read_text() == 'PRIVATE_CONFIG_SENTINEL: invalid JSON'
    config.unlink()
    run('--dump')
    assert not config.exists(), 'Diagnostics created a live account config'
print('Diagnostic privacy checks passed.')
