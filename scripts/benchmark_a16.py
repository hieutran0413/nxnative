#!/usr/bin/env python3
import subprocess
import time
import os
import sys
import shutil
import re
import csv
import secrets
import select

REPO_DIR = "/Volumes/My Data/Development/NX Native"
BUILD_DIR = "/Volumes/My Data/Development/Games/TOTK/0100F2C0115B6000_build"
DMHOST_BIN = f"{REPO_DIR}/dm/host/dmhost"
WORK_DIR = f"{os.path.dirname(BUILD_DIR)}/0100F2C0115B6000-work/benchmark"

def directory_bytes(path):
    total = 0
    if not os.path.isdir(path):
        return 0
    for root, _, files in os.walk(path):
        for name in files:
            try:
                total += os.path.getsize(os.path.join(root, name))
            except OSError:
                pass
    return total

def run_benchmark(save_name, run_seconds=25, screenshot_name=None):
    save_src = f"{REPO_DIR}/test_saves/{save_name}"
    if not os.path.isdir(save_src):
        print(f"Error: save source does not exist: {save_src}")
        return None

    os.makedirs(WORK_DIR, exist_ok=True)
    run_id = f"{time.strftime('%Y%m%dT%H%M%S')}_{secrets.token_hex(4)}"
    run_dir = os.path.join(WORK_DIR, f"{save_name}_{run_id}")
    os.makedirs(run_dir, exist_ok=False)
    cache_dir = os.path.join(os.environ.get("DM_TEXTURE_CACHE", WORK_DIR), "texture-cache")
    cache_disk_start = directory_bytes(cache_dir)
    save_work = os.path.join(run_dir, "save")
    shutil.copytree(save_src, save_work)

    ctl_file = os.path.join(run_dir, "control.txt")
    log_file = os.path.join(run_dir, "dmhost.log")
    memstat_file = os.path.join(run_dir, "memory.tsv")
    fast_memstat_file = f"{memstat_file}.fast.tsv"
    watch_memstat_file = f"{memstat_file}.watch.tsv"
    timing_file = os.path.join(run_dir, "timing.tsv")

    for f in [ctl_file, log_file, memstat_file, fast_memstat_file, watch_memstat_file, timing_file]:
        if os.path.exists(f):
            os.remove(f)

    with open(ctl_file, "w") as f:
        f.write("# CTL init\n")

    env = os.environ.copy()
    render_scale = os.environ.get("DM_RENDER_SCALE", "0.5")
    diagnostic_limit_mb = int(os.environ.get("DM_BENCH_DIAGNOSTIC_LIMIT_MB", "3072"))
    if diagnostic_limit_mb < 3072:
        raise ValueError("DM_BENCH_DIAGNOSTIC_LIMIT_MB must be at least the fixed 3072 MiB acceptance ceiling")
    env.update({
        "DM_ROOT": BUILD_DIR,
        "DM_ROMFS": f"{BUILD_DIR}/extract/v720896/RomFS",
        "DM_SAVE": save_work,
        "DM_TEMP": f"{BUILD_DIR}/run/temp",
        "DM_TEXTURE_CACHE": os.environ.get("DM_TEXTURE_CACHE", WORK_DIR),
        "DM_MSL_DIR": f"{BUILD_DIR}/shader/mac_shaders",
        "DM_FONT_DIR": f"{BUILD_DIR}/font",
        "DM_NVN_SHMAP": f"{REPO_DIR}/dm/games/0100F2C0115B6000/shader_map.tsv",
        "DM_LANG": "en-US",
        "DM_WINDOW": "1",
        "DM_AUDIO": "0",
        "DM_KEEP_FOCUS": "1",
        "DM_FPS_TARGET": "60",
        "DM_RENDER_SCALE": render_scale,
        # The simulated-Jetsam watchdog normally enforces the acceptance
        # ceiling. A separately named diagnostic override can let a menu/load
        # investigation continue past that ceiling; result classification
        # below remains fixed at 3072 MiB and can never turn that run into PASS.
        "DM_TEST_MEM_LIMIT_MB": str(diagnostic_limit_mb),
        # Optional diagnostic cap for testing Horizon's application-pool
        # pressure behavior. Keep the profile default unless explicitly set.
        "DM_APP_POOL_LIMIT_MB": os.environ.get("DM_APP_POOL_LIMIT_MB", "3285"),
        # Diagnostic guest-visible total; independent of the host's MapPhysicalMemory ceiling.
        "DM_NVN_TEST_TOTAL_MEM_MB": os.environ.get("DM_NVN_TEST_TOTAL_MEM_MB", ""),
        "DM_CTL": ctl_file,
        "DM_MEMSTAT": memstat_file,
        "DM_MEMSTAT_FAST_HZ": "60",
        "DM_MEMSTAT_WATCH_MB": str(diagnostic_limit_mb),
        "DM_ALIAS_TRACE": os.environ.get("DM_ALIAS_TRACE", "0"),
        "DM_MEMSTAT_DUMP_ON_CROSS": os.environ.get("DM_MEMSTAT_DUMP_ON_CROSS", "0"),
        # Stable screenshot gates need the direct drawable path; the display
        # link can go silent in this Mac windowed harness.
        "DM_PRESENT_LINK": os.environ.get("DM_PRESENT_LINK", "0"),
        "DM_NVN_TSV": timing_file,
        "DM_NVN_TSV_CALLS": "0",
        "DM_SLOWFRAME": "1",
        # Shader-key diagnostics follow a draw class across load-time frame
        # shifts, unlike DM_NVN_PASSDUMP's fixed frame range.
        "DM_NVN_KEYDUMP": os.environ.get("DM_NVN_KEYDUMP", ""),
        # Pass through opt-in renderer experiments for controlled Mac A/B runs.
        "DM_NVN_TEST_PKG_EVICT_MB": os.environ.get("DM_NVN_TEST_PKG_EVICT_MB", ""),
        # Simulate iOS pressure against the acceptance budget while keeping a
        # higher diagnostic watchdog so a run can show whether reclamation helps.
        "DM_NVN_TEST_PRESSURE_LIMIT_MB": os.environ.get("DM_NVN_TEST_PRESSURE_LIMIT_MB", ""),
        "DM_NVN_TREG_ID": os.environ.get("DM_NVN_TREG_ID", ""),
        "DM_NVN_TEXINFO": os.environ.get("DM_NVN_TEXINFO", ""),
        "DM_NVN_PASSDUMP": os.environ.get("DM_NVN_PASSDUMP", ""),
        "DM_NVN_TEXSNAP": os.environ.get("DM_NVN_TEXSNAP", ""),
        # Narrow, one-frame render-target snapshots are diagnostic only. Keep
        # the default run free of PNG/readback overhead unless requested.
        "DM_NVN_TEXDUMP": os.environ.get("DM_NVN_TEXDUMP", ""),
        "DM_NVN_TEXSNAP_SERIAL": os.environ.get("DM_NVN_TEXSNAP_SERIAL", ""),
    })
    # The host enables BC1 upload verification by getenv() presence, so an
    # empty value still turns on diagnostics and contaminates benchmark timing.
    # Keep these opt-in controls absent unless the operator explicitly sets them.
    for name in ("DM_BC1A_VERIFY", "DM_BC1A_VERIFY_SERIAL", "DM_BC1A_VERIFY_BASE_SIZE"):
        if name in os.environ and os.environ[name]:
            env[name] = os.environ[name]
        else:
            env.pop(name, None)
    if os.environ.get("DM_BENCH_MODE", "no-bc") == "no-bc":
        env["DM_TEST_NO_BC"] = "1"
    else:
        env.pop("DM_TEST_NO_BC", None)

    log_fp = open(log_file, "w")
    mode = "no-BC" if env.get("DM_TEST_NO_BC") == "1" else "BC-capable"
    diagnostic_note = "" if diagnostic_limit_mb == 3072 else f" (diagnostic watchdog {diagnostic_limit_mb} MiB; acceptance remains 3072 MiB)"
    print(f"[{save_name}] Starting dmhost in {mode} mode with a 3072 MiB acceptance ceiling{diagnostic_note} and {render_scale} render scale.")
    proc = subprocess.Popen(
        [DMHOST_BIN, f"{BUILD_DIR}/patched_v720896"],
        cwd=f"{BUILD_DIR}/run",
        env=env,
        stdout=log_fp,
        stderr=subprocess.STDOUT
    )

    def send_cmd(cmd):
        with open(ctl_file, "a") as f:
            f.write(cmd + "\n")
            f.flush()

    # Gameplay is confirmed from an image, with optional step-by-step controls
    # so a tester can load the save and inspect each resulting screen.
    start_t = time.time()
    in_game = False
    load_started_at = None
    region_load_seconds = None
    screenshot_index = 0
    gate_token = None
    pending_gate_path = None
    gameplay_timing_start_frame = None
    print(f"[{save_name}] Running with PID {proc.pid}; waiting for a reviewed gameplay screenshot.")

    def capture_gate_image(force_new=False):
        nonlocal screenshot_index, gate_token, pending_gate_path
        if force_new or pending_gate_path is None:
            screenshot_index += 1
            gate_token = secrets.token_hex(4)
            # A run-specific path prevents a previous run's PNG from satisfying
            # this gate before the game's asynchronous screenshot request finishes.
            pending_gate_path = os.path.join(run_dir, f"gate_{screenshot_index}_{gate_token}.png")
            if os.path.exists(pending_gate_path):
                os.remove(pending_gate_path)
            send_cmd(f"shot {pending_gate_path}")
        shot_path = pending_gate_path
        deadline = time.time() + 8
        while time.time() < deadline and proc.poll() is None:
            if os.path.isfile(shot_path) and os.path.getsize(shot_path) > 0:
                print(f"[{save_name}] Review this screenshot: {shot_path} (confirmation code {gate_token})")
                return shot_path
            time.sleep(0.2)
        if proc.poll() is None:
            print(f"[{save_name}] No new present processed screenshot {screenshot_index}; request remains pending at {shot_path}.")
        return None

    def read_operator_command(prompt):
        print(prompt, end="", flush=True)
        while proc.poll() is None:
            try:
                ready, _, _ = select.select([sys.stdin], [], [], 0.5)
            except (OSError, ValueError):
                return None
            if ready:
                line = sys.stdin.readline()
                return line.strip() if line else "stop"
        return None

    # Allow the initial screen to render, then ask for interactive input. A
    # non-interactive run ends incomplete instead of guessing from log markers.
    time.sleep(min(8, max(0, 50 - (time.time() - start_t))))
    gate_shot = capture_gate_image(force_new=True) if proc.poll() is None else None
    while proc.poll() is None:
        if gate_shot is None:
            gate_shot = capture_gate_image()   # retry the same queued request; never enqueue one screenshot per timeout
            if proc.poll() is not None:
                break
        prompt = (f"Inspect {gate_shot}; enter 'gameplay:{gate_token}' only if this image shows live gameplay. "
                  if gate_shot else "No fresh screenshot; gameplay confirmation is disabled. ")
        command = read_operator_command(f"{prompt}Use 'button:<buttons>', 'load:<buttons>', 'wait:<seconds>', or 'stop': ")
        if command is None:
            break
        if gate_shot and command.lower() == f"gameplay:{gate_token}":
            in_game = True
            if load_started_at is not None:
                region_load_seconds = time.time() - load_started_at
            if os.path.exists(timing_file):
                try:
                    with open(timing_file, newline="") as f:
                        rows = csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t")
                        gameplay_timing_start_frame = max((int(row["frame"]) for row in rows if row.get("frame")), default=None)
                except (OSError, KeyError, TypeError, ValueError):
                    gameplay_timing_start_frame = None
            break
        if command.lower() == "stop":
            break
        if command.lower().startswith("wait:"):
            try:
                delay = float(command.split(":", 1)[1].strip())
            except ValueError:
                delay = 0
            if not 0.1 <= delay <= 60:
                print(f"[{save_name}] Wait must be between 0.1 and 60 seconds.")
                continue
            had_fresh_image = gate_shot is not None
            time.sleep(delay)
            gate_shot = capture_gate_image(force_new=had_fresh_image)
            continue
        is_load = command.lower().startswith("load:")
        if is_load or command.lower().startswith("button:"):
            button_command = command.split(":", 1)[1].strip()
            if not re.fullmatch(r"[A-Za-z0-9+_.~-]+", button_command):
                print(f"[{save_name}] Invalid button command; screenshot remains unconfirmed.")
                continue
            if is_load:
                load_started_at = time.time()
            had_fresh_image = gate_shot is not None
            if button_command:
                send_cmd(button_command)
                time.sleep(1.0)
            gate_shot = capture_gate_image(force_new=had_fresh_image)
            continue
        if command.lower().startswith("gameplay:"):
            print(f"[{save_name}] Gameplay cannot be confirmed without the current fresh screenshot and matching code.")
        else:
            print(f"[{save_name}] Use button:<buttons>, load:<buttons>, wait:<seconds>, or stop.")

    # Perform movement actions
    if proc.poll() is None and in_game:
        print(f"[{save_name}] Running the movement and camera route for {run_seconds} seconds...")
        actions = [
            ("LUp~3.0", 3.0),
            ("RRight~2.0", 2.0),
            ("B+LUp~4.0", 4.0),
            ("X~0.5", 1.0),
            ("RLeft~2.0", 2.0),
            ("B+LUp~4.0", 4.0),
        ]
        
        act_start = time.time()
        a_idx = 0
        while time.time() - act_start < run_seconds:
            if proc.poll() is not None:
                break
            cmd, wait = actions[a_idx % len(actions)]
            send_cmd(cmd)
            time.sleep(min(wait, run_seconds - (time.time() - act_start)))
            a_idx += 1

        if screenshot_name:
            time.sleep(1.0)
            shot_path = os.path.join(run_dir, screenshot_name)
            if os.path.exists(shot_path):
                os.remove(shot_path)
            send_cmd(f"shot {shot_path}")
            send_cmd("A~0.1")
            shot_done = False
            for _ in range(40):
                time.sleep(0.3)
                if os.path.exists(log_file):
                    with open(log_file, "r") as f:
                        data = f.read()
                        if "screenshot" in data and f"{screenshot_name} ok" in data:
                            shot_done = True
                            print(f"[{save_name}] Screenshot captured: {shot_path}")
                            break
            if not shot_done:
                print(f"[{save_name}] Screenshot completion was not confirmed in the log.")

    # Graceful shutdown
    print(f"[{save_name}] Ending benchmark session...")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except:
        proc.kill()
    log_fp.close()
    cache_disk_end = directory_bytes(cache_dir)

    # Parse results
    metrics = {
        "save": save_name,
        "return_code": proc.returncode,
        "peak_rss_mb": None,
        "peak_gpu_mb": None,
        "alias_mapped_gb": 0.0,
        "bc_unpacked_mb": 0,
        "astc_standin_mb": 0,
        "system_headroom_mb": None,
        "region_load_seconds": region_load_seconds,
        "jetsam_kill": False,
        "gameplay_confirmed": in_game,
        "gameplay_timing_start_frame": gameplay_timing_start_frame,
        "timing_lines": [],
        "timing_samples": {},
        "memory_peaks": {},
        "footprint_fast_samples": 0,
        "texture_cache_disk_start_bytes": cache_disk_start,
        "texture_cache_disk_end_bytes": cache_disk_end,
        "texture_cache_disk_delta_bytes": cache_disk_end - cache_disk_start,
        "lines": []
    }

    if os.path.exists(log_file):
        with open(log_file, "r") as f:
            for line in f:
                if ("simulated Jetsam kill" in line or
                    "resident" in line and "over simulated device limit" in line or
                    "memory watchdog:" in line):
                    metrics["jetsam_kill"] = True
                m_watchdog = re.search(r"memory watchdog: phys_footprint (\d+) MiB (?:exceeds|reached or exceeded)", line)
                if m_watchdog:
                    rss = int(m_watchdog.group(1))
                    metrics["peak_rss_mb"] = rss if metrics["peak_rss_mb"] is None else max(metrics["peak_rss_mb"], rss)
                m_rss = re.search(r"resident (\d+) MB", line)
                if m_rss:
                    rss = int(m_rss.group(1))
                    if metrics["peak_rss_mb"] is None or rss > metrics["peak_rss_mb"]:
                        metrics["peak_rss_mb"] = rss
                m_gpu = re.search(r"GPU allocated (\d+) MB", line)
                if m_gpu:
                    gpu = int(m_gpu.group(1))
                    if metrics["peak_gpu_mb"] is None or gpu > metrics["peak_gpu_mb"]:
                        metrics["peak_gpu_mb"] = gpu
                m_alias = re.search(r"alias region mapped ([\d\.]+) GB", line)
                if m_alias:
                    metrics["alias_mapped_gb"] = max(metrics["alias_mapped_gb"], float(m_alias.group(1)))
                m_alias_peak = re.search(r"alias map ledger: mapped (\d+) MB, peak (\d+) MB", line)
                if m_alias_peak:
                    metrics["alias_mapped_gb"] = max(metrics["alias_mapped_gb"], int(m_alias_peak.group(2)) / 1024)
                m_bc = re.search(r"decompressed BC textures made so far: (\d+) MB", line)
                if m_bc:
                    metrics["bc_unpacked_mb"] = max(metrics["bc_unpacked_mb"], int(m_bc.group(1)))
                m_astc = re.search(r"ASTC 4x4 stand-ins: (\d+) MB", line)
                if m_astc:
                    metrics["astc_standin_mb"] = max(metrics["astc_standin_mb"], int(m_astc.group(1)))
                m_head = re.search(r"headroom to the system memory limit (\d+) MB", line)
                if m_head:
                    metrics["system_headroom_mb"] = int(m_head.group(1))
                if "[mem]" in line or "memory up to frame" in line or "simulated Jetsam" in line or "tracked live staging" in line:
                    metrics["lines"].append(line.strip())
                if "[dm] [nvn] timing up to frame" in line or "[slowframe]" in line:
                    metrics["timing_lines"].append(line.strip())

    # phys_footprint is the kernel-accounted total; do not use missing watchdog
    # text as zero. Per-class columns retain the guest/GPU/staging breakdown.
    if os.path.exists(memstat_file):
        with open(memstat_file, newline="") as f:
            rows = (row for row in csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t"))
            for row in rows:
                try:
                    rss = int(row["phys_footprint"])
                    gpu = int(row["metal_alloc"])
                    metrics["peak_rss_mb"] = rss if metrics["peak_rss_mb"] is None else max(metrics["peak_rss_mb"], rss)
                    metrics["peak_gpu_mb"] = gpu if metrics["peak_gpu_mb"] is None else max(metrics["peak_gpu_mb"], gpu)
                    for name in ("guest", "guest_heap", "guest_alias", "guest_stack", "guest_other", "gpu", "malloc", "other", "unattributed"):
                        if name == "unattributed":
                            value = int(row[name])
                        else:
                            parts = row[name].split("/")
                            value = int(parts[1]) if len(parts) == 3 else 0
                        metrics["memory_peaks"][name] = max(metrics["memory_peaks"].get(name, 0), value)
                except (KeyError, TypeError, ValueError):
                    continue

    # A brief texture upload may exceed the limit between one-second VM walks.
    # Merge the light task_info/Metal samples into the footprint high-water.
    if os.path.exists(fast_memstat_file):
        with open(fast_memstat_file, newline="") as f:
            for row in csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t"):
                try:
                    rss = int(row["phys_footprint"])
                    gpu = int(row["metal_alloc"])
                    metrics["peak_rss_mb"] = rss if metrics["peak_rss_mb"] is None else max(metrics["peak_rss_mb"], rss)
                    metrics["peak_gpu_mb"] = gpu if metrics["peak_gpu_mb"] is None else max(metrics["peak_gpu_mb"], gpu)
                    metrics["footprint_fast_samples"] += 1
                except (KeyError, TypeError, ValueError):
                    continue

    # The background watchdog samples at the same 60 Hz and persists its
    # final sample before exiting, including a peak that raced the fast TSV.
    if os.path.exists(watch_memstat_file):
        with open(watch_memstat_file, newline="") as f:
            for row in csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t"):
                try:
                    rss = int(row["phys_footprint"])
                    metrics["peak_rss_mb"] = rss if metrics["peak_rss_mb"] is None else max(metrics["peak_rss_mb"], rss)
                except (KeyError, TypeError, ValueError):
                    continue

    timing_names = {
        "@frame_ms": "frame",
        "@work_ms": "work",
        "@proc_cpu_ms": "process_cpu",
        "@gpu_ms": "gpu",
        "@cpu_ms": "main_thread_cpu",
        "@upload_ms": "upload_cpu",
        "@upload_gpu_ms": "upload_gpu",
        "@upload_mb": "upload_mib",
    }
    if os.path.exists(timing_file):
        with open(timing_file, newline="") as f:
            rows = (row for row in csv.DictReader((line for line in f if not line.startswith("#")), delimiter="\t"))
            for row in rows:
                metric = timing_names.get(row.get("name"))
                if not metric:
                    continue
                try:
                    value = float(row["value"])
                except (KeyError, TypeError, ValueError):
                    continue
                if metrics["gameplay_confirmed"] and metrics["gameplay_timing_start_frame"] is not None:
                    try:
                        if int(row["frame"]) <= metrics["gameplay_timing_start_frame"]:
                            continue
                    except (KeyError, TypeError, ValueError):
                        continue
                if value >= 0:
                    metrics["timing_samples"].setdefault(metric, []).append(value)

    def percentiles(values):
        ordered = sorted(values)
        if not ordered:
            return "unavailable"
        def at(p):
            return ordered[min(len(ordered) - 1, int((len(ordered) - 1) * p))]
        return f"p50/p95/p99 {at(.50):.2f}/{at(.95):.2f}/{at(.99):.2f}"

    print(f"\n--- Benchmark results [{save_name}] ---")
    print(f"Peak phys_footprint: {metrics['peak_rss_mb'] if metrics['peak_rss_mb'] is not None else 'N/A'} MiB")
    print(f"Fast footprint samples: {metrics['footprint_fast_samples']} at up to 60 Hz")
    headroom = 3072 - metrics["peak_rss_mb"] if metrics["peak_rss_mb"] is not None else None
    print(f"Headroom to simulated 3072 MiB budget: {headroom if headroom is not None else 'N/A'} MiB")
    print(f"Peak Metal allocation: {metrics['peak_gpu_mb'] if metrics['peak_gpu_mb'] is not None else 'N/A'} MiB")
    print(f"Alias mapped high-water: {metrics['alias_mapped_gb']:.2f} GiB")
    print(f"BC decompressed: {metrics['bc_unpacked_mb']} MiB")
    print(f"ASTC stand-ins: {metrics['astc_standin_mb']} MiB")
    print(f"Last host system-limit headroom: {metrics['system_headroom_mb']} MiB")
    print(f"Save/region load time: {metrics['region_load_seconds']} s")
    print(f"Simulated watchdog kill: {metrics['jetsam_kill']}")
    print(f"Gameplay operator-confirmed: {metrics['gameplay_confirmed']}")
    if metrics["jetsam_kill"] or metrics["peak_rss_mb"] is None or metrics["peak_rss_mb"] > 3072:
        status = "FAIL"
    elif not metrics["gameplay_confirmed"]:
        status = "INCOMPLETE"
    elif not metrics["timing_samples"].get("frame"):
        status = "INCOMPLETE"
    elif metrics["peak_rss_mb"] >= 3072:
        status = "FAIL"
    elif sorted(metrics["timing_samples"]["frame"])[int((len(metrics["timing_samples"]["frame"]) - 1) * 0.95)] > 16.67:
        status = "FAIL"
    else:
        status = "REVIEW"
    print(f"Acceptance status: {status}")
    for metric, values in metrics["timing_samples"].items():
        unit = "MiB/frame" if metric == "upload_mib" else "ms"
        print(f"{metric}: {percentiles(values)} {unit} ({len(values)} samples)")
    for category, peak in metrics["memory_peaks"].items():
        print(f"Peak {category}: {peak} MiB")
    staging_lines = [line for line in metrics["lines"] if "tracked live staging" in line]
    if staging_lines:
        print(f"Upload staging: {staging_lines[-1].split('tracked live staging ', 1)[1]}")
    else:
        print("Upload staging: no allocator diagnostic emitted during this run")
    print(f"ASTC disk cache bytes (start/end/net): {metrics['texture_cache_disk_start_bytes']}/{metrics['texture_cache_disk_end_bytes']}/{metrics['texture_cache_disk_delta_bytes']}")
    for line in metrics["timing_lines"][-4:]:
        print(line)
    print("----------------------------------------\n")
    return metrics

if __name__ == "__main__":
    MAPS = [
        "01_Great_Sky_Island",
        "02_Sky_Islands_Lanayru",
        "03_Wind_Temple_Snow",
        "04_Surface_Dueling_Peaks",
        "05_Surface_Great_Plateau_100",
        "06_Depths_Twins_Mountain",
        "07_Depths_Zonai_Central_Mine",
    ]
    target = sys.argv[1] if len(sys.argv) > 1 else "all"
    sec = int(sys.argv[2]) if len(sys.argv) > 2 else 20
    
    if target == "all":
        results = []
        for m in MAPS:
            shot = f"shot_{m}.png"
            res = run_benchmark(m, sec, shot)
            results.append(res)
            time.sleep(2)
        
        print("\n" + "="*80)
        print("TOTK 3072 MiB benchmark summary (seven saves):")
        print("="*80)
        print(f"{'Save':<30} | {'Peak footprint':<15} | {'Peak Metal':<12} | {'Headroom':<10} | {'Watchdog':<10} | {'Status'}")
        print("-" * 85)
        for r in results:
            if r is None:
                status = "NO DATA"
                print(f"{'(missing)':<30} | {'N/A':<15} | {'N/A':<12} | {'N/A':<10} | {'N/A':<10} | {status}")
                continue
            if r["jetsam_kill"] or r["peak_rss_mb"] is None or r["peak_rss_mb"] > 3072:
                status = "FAIL"
            elif not r["gameplay_confirmed"]:
                status = "INCOMPLETE"
            elif not r["timing_samples"].get("frame"):
                status = "INCOMPLETE"
            elif r["peak_rss_mb"] >= 3072:
                status = "FAIL"
            elif sorted(r["timing_samples"]["frame"])[int((len(r["timing_samples"]["frame"]) - 1) * 0.95)] > 16.67:
                status = "FAIL"
            else:
                status = "REVIEW"
            rss = f"{r['peak_rss_mb']} MiB" if r["peak_rss_mb"] is not None else "N/A"
            gpu = f"{r['peak_gpu_mb']} MiB" if r["peak_gpu_mb"] is not None else "N/A"
            hr = f"{3072 - r['peak_rss_mb']} MiB" if r["peak_rss_mb"] is not None else "N/A"
            print(f"{r['save']:<30} | {rss:<15} | {gpu:<12} | {hr:<10} | {str(r['jetsam_kill']):<10} | {status}")
        print("="*80 + "\n")
    else:
        shot = sys.argv[3] if len(sys.argv) > 3 else f"shot_{target}.png"
        run_benchmark(target, sec, shot)
