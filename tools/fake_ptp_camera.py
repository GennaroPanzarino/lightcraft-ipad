"""A stand-in Sony camera speaking PTP/IP on 127.0.0.1:15740 (no SSH): the Sony handshake, the
0x9209 properties (0xD215 pending, 0xD222 destination, 0xD268 size sent), 0x9205 sets, and shots
waiting under 0xFFFFC001, sent by GetObject at RATE bytes/s like the camera's Wi-Fi.
Usage: fake_ptp_camera.py RAW1 [RAW2 ...]   (one shot every SHOT_EVERY seconds after connecting)"""
import socket
import struct
import sys
import threading
import time

import os
RATE = int(os.environ.get('FAKE_RATE', '5000000'))
SHOT_FIRST = 3.0
SHOT_EVERY = float(os.environ.get('FAKE_EVERY', '12'))
PAIRS = os.environ.get('FAKE_PAIRS') == '1'
STALL = float(os.environ.get('FAKE_STALL', '0'))  # seconds of silence half way through each GetObject
files = sys.argv[1:]
t0 = time.perf_counter()


def log(msg):
    print(f"[cam {time.perf_counter() - t0:8.3f}] {msg}", flush=True)


def pkt(typ, payload=b""):
    return struct.pack("<II", 8 + len(payload), typ) + payload


def recv_exact(s, n):
    b = b""
    while len(b) < n:
        c = s.recv(n - len(b))
        if not c:
            raise ConnectionError("closed")
        b += c
    return b


def recv_pkt(s):
    n, typ = struct.unpack("<II", recv_exact(s, 8))
    return typ, recv_exact(s, n - 8)


def ptpstr(t):
    if not t:
        return b"\x00"
    u = (t + "\x00").encode("utf-16-le")
    return bytes([len(t) + 1]) + u


def u16arr(v):
    return struct.pack("<I", len(v)) + b"".join(struct.pack("<H", x) for x in v)


props = {0xD215: [4, 0], 0xD222: [4, 0x10], 0xD268: [2, 2]}  # code: [type, value]


def prop_bytes():
    out = struct.pack("<Q", len(props))
    for code, (typ, val) in props.items():
        fmt = "<H" if typ == 4 else "<B"
        out += struct.pack("<HHBB", code, typ, 1, 1) + struct.pack(fmt, 0) + struct.pack(fmt, val) + b"\x00"
    return out


def respond(s, code, tid, params=()):
    s.sendall(pkt(7, struct.pack("<HI", code, tid) + b"".join(struct.pack("<I", p) for p in params)))


def send_data(s, tid, data, rate=None):
    s.sendall(pkt(9, struct.pack("<IQ", tid, len(data))))
    if rate is None:
        s.sendall(pkt(12, struct.pack("<I", tid) + data))
        return
    chunk = 1 << 20
    off = 0
    start = time.perf_counter()
    stalled = False
    while off < len(data):
        if STALL and not stalled and off >= len(data) // 2:
            stalled = True
            log(f"Wi-Fi stall: {STALL:.0f} s of silence at {off / 1e6:.1f} MB")
            time.sleep(STALL)
            start += STALL
        piece = data[off:off + chunk]
        last = off + len(piece) >= len(data)
        header = struct.pack("<II", 8 + 4 + len(piece), 12 if last else 10) + struct.pack("<I", tid)
        s.sendall(header)
        for i in range(0, len(piece), 64 * 1024):
            s.sendall(piece[i:i + 64 * 1024])
            due = start + (off + i + 64 * 1024) / rate
            delay = due - time.perf_counter()
            if delay > 0:
                time.sleep(delay)
        off += len(piece)


queue = []
shot_no = [9300]


def shooter():
    time.sleep(SHOT_FIRST)
    for f in files:
        data = open(f, "rb").read()
        shot_no[0] += 1
        queue.append((f"DSC{shot_no[0]:05d}.ARW", data))
        props[0xD215][1] = 0x8000 | len(queue)
        log(f"SHUTTER: {queue[-1][0]} ({len(data) / 1e6:.1f} MB) waiting")
        # pairs: a second shot half a second after the first, then a pause
        time.sleep(0.5 if PAIRS and shot_no[0] % 2 == 1 else SHOT_EVERY)


srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", 15740))
srv.listen(4)
log("listening on 127.0.0.1:15740")
cmd, _ = srv.accept()
typ, p = recv_pkt(cmd)
assert typ == 1, typ
log(f"InitCommandRequest from {p[16:].decode('utf-16-le', 'ignore').split(chr(0))[0]}")
cmd.sendall(pkt(2, struct.pack("<I", 1) + b"\x11" * 16 + "ILCE-7M4\x00".encode("utf-16-le") + struct.pack("<I", 0x10000)))
evt, _ = srv.accept()
typ, p = recv_pkt(evt)
assert typ == 3, typ
evt.sendall(pkt(4))
log("event connection open")
threading.Thread(target=shooter, daemon=True).start()
ops = [0x1001, 0x1002, 0x1003, 0x1008, 0x1009, 0x9201, 0x9202, 0x9205, 0x9209]
while True:
    try:
        typ, p = recv_pkt(cmd)
    except ConnectionError:
        log("command connection closed")
        break
    assert typ == 6, typ
    phase, op, tid = struct.unpack("<IHI", p[:10])
    params = struct.unpack(f"<{(len(p) - 10) // 4}I", p[10:])
    sent = None
    if phase == 2:
        _, start = recv_pkt(cmd)
        _, end = recv_pkt(cmd)
        sent = end[4:]
    if op == 0x1001:
        di = struct.pack("<HIH", 100, 0x11, 100) + ptpstr("") + struct.pack("<H", 0) + u16arr(ops) + u16arr([]) + u16arr([]) + u16arr([]) + u16arr([])
        di += ptpstr("Sony Corporation") + ptpstr("ILCE-7M4") + ptpstr("2.00") + ptpstr("")
        send_data(cmd, tid, di)
        respond(cmd, 0x2001, tid)
    elif op in (0x1002, 0x1003, 0x9201):
        log(f"op 0x{op:04X} {params}")
        respond(cmd, 0x2001, tid)
    elif op == 0x9202:
        send_data(cmd, tid, struct.pack("<H", 0x12C) + u16arr([0xD215, 0xD222, 0xD268]) + u16arr([0xD2C1]))
        respond(cmd, 0x2001, tid)
    elif op == 0x9209:
        send_data(cmd, tid, prop_bytes())
        respond(cmd, 0x2001, tid)
    elif op == 0x9205:
        code = params[0]
        typ_ = props[code][0]
        props[code][1] = struct.unpack("<H" if typ_ == 4 else "<B", sent)[0]
        log(f"set 0x{code:04X} = 0x{props[code][1]:X}")
        respond(cmd, 0x2001, tid)
    elif op == 0x1008:
        name, data = queue[0]
        oi = struct.pack("<IHHI", 0x10001, 0xB101, 0, len(data)) + struct.pack("<H", 0) + struct.pack("<6I", 0, 0, 0, 0, 0, 0)
        oi += struct.pack("<IHII", 0, 0, 0, 0) + ptpstr(name) + ptpstr("") + ptpstr("") + ptpstr("")
        send_data(cmd, tid, oi)
        respond(cmd, 0x2001, tid)
    elif op == 0x1009:
        name, data = queue[0]
        log(f"GetObject {name}: sending {len(data) / 1e6:.1f} MB at {RATE / 1e6:.0f} MB/s")
        send_data(cmd, tid, data, RATE)
        respond(cmd, 0x2001, tid)
        queue.pop(0)
        props[0xD215][1] = (0x8000 | len(queue)) if queue else 0
        log(f"GetObject {name}: done")
        if not queue and shot_no[0] - 9300 >= len(files):
            log("all shots sent")
    else:
        log(f"op 0x{op:04X} not supported")
        respond(cmd, 0x2005, tid)
