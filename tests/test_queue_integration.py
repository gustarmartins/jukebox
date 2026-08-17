import subprocess
import time
import socket
import json
import os
import tempfile
import pytest


@pytest.fixture
def mpv_instance():
    sock = tempfile.mktemp(suffix=".sock", prefix="test-mpv-")
    p = subprocess.Popen([
        "mpv",
        f"--input-ipc-server={sock}",
        "--no-video",
        "--no-terminal",
        "--idle=yes"
    ])
    
    # Wait for socket
    waited = 0
    while not os.path.exists(sock) and waited < 30:
        time.sleep(0.1)
        waited += 1

    assert os.path.exists(sock), "mpv failed to start IPC socket"

    yield sock

    p.terminate()
    try:
        p.wait(timeout=2)
    except subprocess.TimeoutExpired:
        p.kill()
    if os.path.exists(sock):
        try:
            os.unlink(sock)
        except OSError:
            pass


def send_ipc(sock_path, cmd_dict):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(3)
    s.connect(sock_path)
    cmd_dict["request_id"] = 9999
    s.sendall(json.dumps(cmd_dict).encode() + b"\n")
    buf = b""
    res = None
    while True:
        c = s.recv(4096)
        if not c:
            break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                obj = json.loads(line)
                if obj.get("request_id") == 9999:
                    res = obj
                    break
            except Exception:
                pass
        if res is not None:
            break
    s.close()
    return res


def test_mpv_ipc_shuffle_upcoming(mpv_instance):
    # 1. Create a playlist with 8 tracks
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".m3u") as f:
        for i in range(8):
            f.write(f"avformat://lavfi:sine=frequency={300 + i*50}:duration=30\n")
        pl_name = f.name

    try:
        # Load playlist
        send_ipc(mpv_instance, {"command": ["loadlist", pl_name, "replace"]})
        time.sleep(0.3)

        # Set playing track to index 2
        send_ipc(mpv_instance, {"command": ["set_property", "playlist-pos", 2]})
        time.sleep(0.3)

        # Query playlist before shuffle
        res = send_ipc(mpv_instance, {"command": ["get_property", "playlist"]})
        pl_data = res.get("data", [])
        assert len(pl_data) == 8
        orig_order = [e.get("id") for e in pl_data]

        # Execute the exact python code used in _jukebox_shuffle_upcoming
        python_code = '''
import socket, json, sys, os, random
sock_path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sock_path)
s.sendall(b"{\\"command\\":[\\"get_property\\",\\"playlist\\"], \\"request_id\\": 888}\\n")
buf = b""
pl_data = None
while True:
    c = s.recv(65536)
    if not c: break
    buf += c
    while b"\\n" in buf:
        line, buf = buf.split(b"\\n", 1)
        try: obj = json.loads(line)
        except: continue
        if obj.get("request_id") == 888:
            pl_data = obj.get("data", [])
            break
    if pl_data is not None: break

cur_pos = 2
n = len(pl_data)
current_order = [e.get("id") for e in pl_data]
upcoming_ids = list(current_order[cur_pos + 1:])
random.shuffle(upcoming_ids)
target_order = current_order[:cur_pos + 1] + upcoming_ids

state = list(current_order)
moves = []
for target_pos in range(cur_pos + 1, n):
    target_id = target_order[target_pos]
    curr_pos_of_id = state.index(target_id)
    if curr_pos_of_id != target_pos:
        moves.append({"command": ["playlist-move", curr_pos_of_id, target_pos]})
        item = state.pop(curr_pos_of_id)
        state.insert(target_pos, item)

if moves:
    for m_idx, m in enumerate(moves):
        m["request_id"] = 2000 + m_idx
    last_req_id = moves[-1]["request_id"]
    payload = "".join(json.dumps(m) + "\\n" for m in moves).encode()
    s.sendall(payload)
    while True:
        c = s.recv(65536)
        if not c: break
        buf += c
        done = False
        while b"\\n" in buf:
            line, buf = buf.split(b"\\n", 1)
            try: obj = json.loads(line)
            except: continue
            if obj.get("request_id") == last_req_id:
                done = True
                break
        if done: break

s.close()
'''
        subprocess.run(["python3", "-c", python_code, mpv_instance], check=True)
        time.sleep(0.2)

        # Check playlist after shuffle
        res2 = send_ipc(mpv_instance, {"command": ["get_property", "playlist"]})
        pl_data2 = res2.get("data", [])
        new_order = [e.get("id") for e in pl_data2]

        # Tracks 0, 1, 2 must be identical
        assert new_order[:3] == orig_order[:3]
        # Upcoming tracks 3..7 must be a permutation
        assert set(new_order[3:]) == set(orig_order[3:])

    finally:
        if os.path.exists(pl_name):
            os.unlink(pl_name)


def test_mpv_ipc_clear_upcoming(mpv_instance):
    with tempfile.NamedTemporaryFile("w", delete=False, suffix=".m3u") as f:
        for i in range(6):
            f.write(f"avformat://lavfi:sine=frequency={300 + i*50}:duration=30\n")
        pl_name = f.name

    try:
        send_ipc(mpv_instance, {"command": ["loadlist", pl_name, "replace"]})
        time.sleep(0.3)
        send_ipc(mpv_instance, {"command": ["set_property", "playlist-pos", 1]})
        time.sleep(0.3)

        # Clear upcoming: remove indices 5 down to 2
        clear_code = '''
import socket, json, sys
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(3)
s.connect(sys.argv[1])
s.sendall(b"{\\"command\\":[\\"get_property\\",\\"playlist\\"], \\"request_id\\": 777}\\n")
buf = b""
pl_data = None
while True:
    c = s.recv(65536)
    if not c: break
    buf += c
    while b"\\n" in buf:
        line, buf = buf.split(b"\\n", 1)
        try: obj = json.loads(line)
        except: continue
        if obj.get("request_id") == 777:
            pl_data = obj.get("data", [])
            break
    if pl_data is not None: break

cur_pos = 1
n = len(pl_data)
removes = []
last_req_id = None
for idx in range(n - 1, cur_pos, -1):
    last_req_id = 1000 + idx
    removes.append({"command": ["playlist-remove", idx], "request_id": last_req_id})

if removes:
    payload = "".join(json.dumps(r) + "\\n" for r in removes).encode()
    s.sendall(payload)
    if last_req_id:
        while True:
            c = s.recv(65536)
            if not c: break
            buf += c
            done = False
            while b"\\n" in buf:
                line, buf = buf.split(b"\\n", 1)
                try: obj = json.loads(line)
                except: continue
                if obj.get("request_id") == last_req_id:
                    done = True
                    break
            if done: break
s.close()
'''
        subprocess.run(["python3", "-c", clear_code, mpv_instance], check=True)
        time.sleep(0.2)

        res = send_ipc(mpv_instance, {"command": ["get_property", "playlist"]})
        pl_data = res.get("data", [])
        # Only tracks 0 and 1 should remain
        assert len(pl_data) == 2

    finally:
        if os.path.exists(pl_name):
            os.unlink(pl_name)
