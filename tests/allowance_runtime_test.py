#!/usr/bin/env python3
"""Black-box CLI, durable-write and game-supervisor checks; no device files."""
import os
import datetime
import pathlib
import signal
import socket
import threading
import subprocess
import sys
import tempfile
import time

os.environ.setdefault('TZ', 'UTC')
binary = str(pathlib.Path(sys.argv[1]).resolve())

def call(root, profile, operation, *args, ok=True, env=None):
    result = subprocess.run([binary, '--allowance', str(root / 'ledger'), str(profile), operation, *map(str, args)],
                            capture_output=True, text=True, env=env)
    assert (result.returncode == 0) == ok, (operation, result.returncode, result.stderr)
    return result.stdout.strip()

def status(root, profile):
    return list(map(int, call(root, profile, 'status').split()))

def edit(root, profile, operation, value):
    generation = status(root, profile)[4]
    call(root, profile, operation, value, generation)

with tempfile.TemporaryDirectory() as temporary:
    root = pathlib.Path(temporary)
    ada = root / 'Ada'; ada.mkdir()
    bea = root / 'Bea'; bea.mkdir()
    call(root, ada, 'enroll'); call(root, bea, 'enroll')
    assert status(root, ada)[0] == -1
    edit(root, ada, 'confirm', 0)
    edit(root, ada, 'daily', 30)
    edit(root, bea, 'daily', 10)
    generation = status(root, ada)[4]
    call(root, ada, 'bonus', 5, generation)
    call(root, ada, 'bonus', 5, generation, ok=False)
    assert status(root, ada)[0] == 2100
    assert status(root, bea)[0] == 600
    renamed = root / 'Ada Renamed'; ada.rename(renamed); ada = renamed
    assert status(root, ada)[0] == 2100
    # Wrong, huge and truncated arguments fail without granting time.
    for value in ('-1', '999999999999999999999999', '5x', '0', '121'):
        call(root, ada, 'bonus', value, status(root, ada)[4], ok=False)
    assert status(root, ada)[0] == 2100
    # Every atomic-write failure/cut leaves a parseable committed generation.
    for point in ('open', 'write', 'fsync', 'close', 'rename', 'renamed', 'durable', 'directory-fsync', 'read-open', 'read', 'stat', 'state.v1:before', 'state.v1:renamed'):
        for kind in ('ALLOWANCE_FAULT', 'ALLOWANCE_CUT'):
            before = status(root, ada)[0]
            env = dict(os.environ, **{kind: point})
            call(root, ada, 'bonus', 5, status(root, ada)[4], ok=False, env=env)
            after_fault = status(root, ada)[0]
            assert after_fault == before + (300 if point == 'state.v1:renamed' else 0)

    brightness = root / 'brightness'; brightness.write_text('10\n')
    env = dict(os.environ, ALLOWANCE_BRIGHTNESS=str(brightness))
    script = root / 'game.sh'
    game_environment = root / 'game-environment'
    env['KIDMODE_GAME_LD_PRELOAD'] = 'libm.so.6'
    script.write_text(f'printf "%s:%s" "$LD_PRELOAD" "${{KIDMODE_GAME_LD_PRELOAD+leaked}}" > "{game_environment}"\nsleep 3\n')
    before = status(root, ada)[0]
    call(root, ada, 'run', script, env=env)
    assert game_environment.read_text() == 'libm.so.6:'
    del env['KIDMODE_GAME_LD_PRELOAD']
    after = status(root, ada)[0]
    assert 2 <= before - after <= 4, (before, after)
    # The carousel/status itself consumes no time.
    time.sleep(1.1); assert status(root, ada)[0] == after
    script.write_text('sleep 9\n')
    process = subprocess.Popen([binary, '--allowance', str(root / 'ledger'), str(ada), 'run', str(script)], env=env)
    time.sleep(2)
    call(root, ada, 'bonus', 5, 0, ok=False)  # locked while playing
    brightness.write_text('0\n'); time.sleep(5); brightness.write_text('10\n')
    assert process.wait(timeout=10) == 0
    after_sleep = status(root, ada)[0]
    assert 2 <= after - after_sleep <= 5, (after, after_sleep)
    # A stopped supervisor is how Onion implements ordinary device sleep.
    process = subprocess.Popen([binary, '--allowance', str(root / 'ledger'), str(ada), 'run', str(script)], env=env)
    time.sleep(2); process.send_signal(signal.SIGSTOP)
    time.sleep(4); process.send_signal(signal.SIGCONT)
    assert process.wait(timeout=10) == 0
    after_stop = status(root, ada)[0]
    assert 3 <= after_sleep - after_stop <= 6, (after_sleep, after_stop)
    # Abrupt restart cannot refund the persisted prepaid lease.
    pidfile = root / 'game.pid'
    script.write_text(f'echo $$ > "{pidfile}"\nsleep 60\n')
    process = subprocess.Popen([binary, '--allowance', str(root / 'ledger'), str(ada), 'run', str(script)], env=env)
    try:
        for _ in range(100):
            if pidfile.exists(): break
            time.sleep(.02)
        assert pidfile.exists()
        process.kill(); process.wait(timeout=5)
        assert after_stop - status(root, ada)[0] == 5
    finally:
        if process.poll() is None: process.kill(); process.wait()
        if pidfile.exists():
            try: os.killpg(int(pidfile.read_text()), signal.SIGKILL)
            except ProcessLookupError: pass
    # Observe midnight, backward/unknown dates and date recovery using the
    # real runtime conversion and persistence, with only the clock substituted.
    clockfile = root / 'clock'
    os.environ['ALLOWANCE_CLOCK'] = str(clockfile)
    os.environ['TZ'] = 'America/Los_Angeles'
    def clock_at(iso, trusted=True):
        timestamp = int(datetime.datetime.fromisoformat(iso).timestamp())
        clockfile.write_text(f'{timestamp} {int(trusted)}\n')
    clock_at('2026-11-09T23:59:59-08:00')
    edit(root, ada, 'confirm', 0)
    old_used = status(root, ada)[5]
    assert old_used > 0
    # Invalid offline startup followed by trusted time on the same date must
    # self-heal without erasing gameplay already charged or bonus time.
    old_status = status(root, ada)
    clockfile.write_text('0 0\n')
    assert status(root, ada)[3] == 1 and status(root, ada)[5] == old_used
    clock_at('2026-11-09T23:59:59-08:00')
    healed = status(root, ada)
    assert healed[3] == 0 and healed[0] == old_status[0] and healed[5] == old_used
    clock_at('2026-11-10T00:00:00-08:00')
    assert status(root, ada)[0] == 1800 and status(root, ada)[5] == 0
    assert status(root, bea)[0] == 600  # no cross-child grant/charge
    edit(root, ada, 'bonus', 5)
    clock_at('2026-11-09T12:00:00-08:00')
    assert status(root, ada)[3] == 1 and status(root, ada)[0] == 2100
    clock_at('2026-11-11T00:00:00-08:00')
    assert status(root, ada)[0] == 1800 and status(root, ada)[3] == 0
    # Repeated observations cannot grant repeatedly or remove today's bonus.
    edit(root, ada, 'bonus', 5)
    assert status(root, ada)[0] == 2100
    assert status(root, ada)[0] == 2100
    clock_at('2026-11-12T00:00:00-08:00')
    assert status(root, ada)[0] == 1800
    clock_at('2026-11-13T00:00:00-08:00', False)
    assert status(root, ada)[3] == 1 and status(root, ada)[0] == 1800
    clockfile.write_text('0 0\n')
    assert status(root, ada)[0] == 1800 and status(root, ada)[3] == 1
    # DST repeats an hour but never a calendar-day grant.
    clock_at('2026-11-01T01:59:59-07:00'); edit(root, ada, 'confirm', 0)
    edit(root, ada, 'bonus', 5)
    clock_at('2026-11-01T01:00:00-08:00')
    assert status(root, ada)[0] == 2100 and status(root, ada)[3] == 0
    del os.environ['ALLOWANCE_CLOCK']
    # Observe real loopback datagrams, including the normal-exit QUIT.
    # This does not substitute for seeing RetroArch render on the handheld.
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(('127.0.0.1', 0))
    receiver.settimeout(.1)
    messages = []
    drop_until = 0.0
    stop_receiver = threading.Event()
    def receive():
        while not stop_receiver.is_set():
            try: data, _ = receiver.recvfrom(2048)
            except socket.timeout: continue
            stamp = time.monotonic()
            if stamp < drop_until: continue
            messages.append((stamp, data.decode()))
            if data == b'QUIT':
                os.kill(int(pidfile.read_text()), signal.SIGUSR1)
    listener = threading.Thread(target=receive, daemon=True)
    listener.start()
    env = dict(os.environ, ALLOWANCE_BRIGHTNESS=str(brightness),
               ALLOWANCE_COMMAND_PORT=str(receiver.getsockname()[1]))
    edit(root, ada, 'confirm', 0)
    edit(root, ada, 'daily', 10)
    def set_remaining(seconds):
        ledger_path = root / 'ledger' / 'state.v1'
        rows = ledger_path.read_text().splitlines()
        child_id = (ada / '.allowance-id').read_text().strip()
        for index, row in enumerate(rows[1:-1], 1):
            fields = row.split()
            if fields[0] == child_id:
                fields[3] = str(int(fields[2]) + int(fields[4]) - seconds)
                fields[7] = '0'
                rows[index] = ' '.join(fields)
        payload = ('\n'.join(rows[:-1])+'\n').encode()
        crc = 2166136261
        for byte in payload: crc = ((crc ^ byte) * 16777619) & 0xffffffff
        ledger_path.write_bytes(payload+f'{crc}\n'.encode())
    script.write_text(f'echo $$ > "{pidfile}"\ntrap "exit 0" USR1\nwhile :; do sleep 0.1; done\n')
    set_remaining(2)
    call(root, ada, 'run', script, env=env)
    assert status(root, ada)[0] == 0
    assert any(text == 'QUIT' for _, text in messages)
    call(root, ada, 'run', script, env=env, ok=False)
    try:
        for seconds, text in ((301, 'SHOW_MSG 5 minutes left today'),
                              (61, 'SHOW_MSG 1 minute left today')):
            messages.clear()
            set_remaining(seconds)
            script.write_text('sleep 8\n')
            call(root, ada, 'run', script, env=env)
            warnings = [stamp for stamp, command in messages if command == text]
            assert len(warnings) == 3, messages
            assert all(1.5 <= b-a <= 3 for a, b in zip(warnings, warnings[1:])), warnings
        # Drop startup traffic as if RetroArch had not bound its socket yet.
        messages.clear()
        set_remaining(300)
        drop_until = time.monotonic() + 2
        script.write_text('sleep 7\n')
        call(root, ada, 'run', script, env=env)
        warnings = [stamp for stamp, command in messages if command == 'SHOW_MSG 5 minutes left today']
        assert len(warnings) == 2 and warnings[-1] - warnings[0] >= 1.5, messages
        drop_until = 0.0
    finally:
        stop_receiver.set(); listener.join(timeout=2); receiver.close()
    # A corrupt/missing ledger or malformed stable ID never becomes Off.
    ledger = root / 'ledger' / 'state.v1'
    original = ledger.read_bytes()
    ledger.write_bytes(original[:-3])
    call(root, ada, 'status', ok=False); call(root, ada, 'enroll', ok=False)
    ledger.write_bytes(original)
    ledger.unlink(); call(root, ada, 'enroll', ok=False)
    ledger.write_bytes(original)
    (ada / '.allowance-id').write_text('../not-an-id\n')
    call(root, ada, 'enroll', ok=False)
print('allowance CLI, write failures, independent profiles, sleep and restart: passed')
