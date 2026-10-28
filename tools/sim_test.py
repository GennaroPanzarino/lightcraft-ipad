"""The iPad app in the iOS Simulator (GitHub's macOS runner) against the stand-in camera: settings
seeded, shots arriving, the workspace in landscape and portrait with each tool group, the browser,
the app's log."""
import json
import os
import subprocess
import sys
import time

APP = sys.argv[1]
RAWS = sys.argv[2:]
OUT = "screens"
BUNDLE = "com.lightcraft.tether"
os.makedirs(OUT, exist_ok=True)


def sh(*a, check=True, **kw):
    print("+", " ".join(a), flush=True)
    return subprocess.run(a, check=check, capture_output=True, text=True, **kw)


def ipad():
    devices = json.loads(sh("xcrun", "simctl", "list", "devices", "available", "-j").stdout)["devices"]
    for runtime, ds in sorted(devices.items(), reverse=True):
        if "iOS" not in runtime:
            continue
        for d in ds:
            if "iPad Pro" in d["name"] and "11" in d["name"]:
                return d["udid"], d["name"], runtime
        for d in ds:
            if "iPad" in d["name"]:
                return d["udid"], d["name"], runtime
    raise SystemExit("no iPad simulator")


udid, name, runtime = ipad()
print("simulator:", name, runtime, flush=True)
sh("xcrun", "simctl", "boot", udid, check=False)
sh("xcrun", "simctl", "bootstatus", udid, "-b")
sh("xcrun", "simctl", "install", udid, APP)


def shot(n):
    path = os.path.join(OUT, f"{n}.png")
    sh("xcrun", "simctl", "io", udid, "screenshot", path, check=False)


def launch(*args):
    sh("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    time.sleep(1)
    sh("xcrun", "simctl", "launch", udid, BUNDLE, *args)


# 1. first run: the connect screen
launch()
time.sleep(6)
shot("01_connect")

# 2. the test login (plain PTP to the stand-in camera on this Mac), a style on every shot
settings = {
    "login": {"ssid": "", "wifiPassword": "", "user": "", "password": "", "fingerprint": "", "plain": "127.0.0.1:15740"},
    "raw": True, "preset": "lc.warm-film", "presetAmount": 100, "followNewest": True, "keepAwake": True,
    "exportQuality": 92, "exportEdge": 0,
}
hexdata = json.dumps(settings).encode().hex()
sh("xcrun", "simctl", "spawn", udid, "defaults", "write", BUNDLE, "settings", "-data", hexdata)
env = dict(os.environ, FAKE_RATE="20000000", FAKE_EVERY="12")
cam = subprocess.Popen([sys.executable, "tools/fake_ptp_camera.py", *RAWS], stdout=open(os.path.join(OUT, "camera.log"), "w"), stderr=subprocess.STDOUT, env=env)
time.sleep(1)
t0 = time.time()
launch("-screen", "workspace", "-tool", "exposure")
for t in [4, 9, 14, 20, 28, 36]:
    while time.time() - t0 < t:
        time.sleep(0.2)
    shot(f"02_live_t{t:02d}")
cam.terminate()

# 3. each tool group, the browser, portrait
for tool in ["color", "details", "adjustments", "metadata", "capture"]:
    launch("-screen", "workspace", "-tool", tool)
    time.sleep(9)
    shot(f"03_{tool}")
launch()
time.sleep(8)
shot("04_browser_at_start")
for t, tool in [("crop", "composition"), ("radial", "local"), ("spots", "details"), ("lensblur", "lens")]:
    launch("-screen", "workspace", "-tool", tool, "-testTool", t)
    time.sleep(16)
    shot(f"07_{t}")
launch("-screen", "workspace", "-tool", "exposure", "-benchmark", "YES")
time.sleep(24)
shot("05_benchmark")
# every export of the shot on screen (Photos allowed beforehand)
sh("xcrun", "simctl", "privacy", udid, "grant", "photos-add", BUNDLE, check=False)
sh("xcrun", "simctl", "privacy", udid, "grant", "photos", BUNDLE, check=False)
launch("-screen", "workspace", "-exportTest", "YES")
time.sleep(70)
shot("06_after_exports")

log = sh("xcrun", "simctl", "spawn", udid, "log", "show", "--last", "8m", "--style", "compact", "--predicate", 'process == "LightCraftTether"', check=False).stdout
open(os.path.join(OUT, "app.log"), "w").write(log)
crashes = sh("bash", "-c", "ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i lightcraft || true").stdout
print("crash reports:", crashes or "none")
for line in log.splitlines():
    if "lightcraft" in line.lower() and any(k in line for k in ("renderer", "editor", "bench", "export", "lensblur", "error", "Error")):
        print(line[:300])
