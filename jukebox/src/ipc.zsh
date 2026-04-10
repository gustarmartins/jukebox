    _jukebox_ipc() {
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys, random
try:
    sock_path = sys.argv[2]
    rid = random.randint(1, 999999)
    cmd = json.loads(sys.argv[1])
    cmd["request_id"] = rid
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sock_path)
    s.sendall((json.dumps(cmd) + "\n").encode())
    buf = b""
    while True:
        c = s.recv(4096)
        if not c: break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            obj = json.loads(line)
            if obj.get("request_id") == rid:
                s.close()
                print(json.dumps(obj))
                sys.exit(0)
    s.close()
except Exception: pass
' "$1" "$mpvsock" 2>/dev/null
    }

    _jukebox_set() {
        _jukebox_ipc "$1" > /dev/null
    }

    _jukebox_batch_get() {
        _jukebox_log "_jukebox_batch_get called with args: $*"
        "$_JUKEBOX_PYTHON" -c '
import socket, json, sys
try:
    sock_path = sys.argv[1]
    props = sys.argv[2:]
    if not props:
        sys.exit(0)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(2)
    s.connect(sock_path)
    # Send all requests with unique request_ids
    for i, prop in enumerate(props):
        cmd = {"command": ["get_property", prop], "request_id": i + 1}
        s.sendall((json.dumps(cmd) + "\n").encode())
    # Collect all responses
    results = {}
    buf = b""
    needed = set(range(1, len(props) + 1))
    while needed:
        c = s.recv(4096)
        if not c:
            break
        buf += c
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            try:
                obj = json.loads(line)
                rid = obj.get("request_id")
                if rid in needed:
                    val = obj.get("data")
                    if val is None:
                        results[rid] = ""
                    elif isinstance(val, bool):
                        results[rid] = "true" if val else "false"
                    else:
                        results[rid] = str(val)
                    needed.discard(rid)
            except:
                pass
    s.close()
    # Output Unit Separator (\x1f) delimited values in request order
    out = []
    for i in range(len(props)):
        out.append(results.get(i + 1, ""))
    print("\x1f".join(out))
except Exception as e:
    # Output empty separators so the caller gets the right number of fields
    print("\x1f".join(["" for _ in sys.argv[2:]]))
    print(f"Exception: {e}", file=sys.stderr)
' "$mpvsock" "$@" 2>>/tmp/jukebox-py.log
    }

    _jukebox_fast_get() {
        _jukebox_batch_get "$1"
    }
