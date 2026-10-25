#!/usr/bin/env python3
import subprocess
import time
import os
import sys
import shutil
import re

REPO_DIR = "/Volumes/My Data/Development/NX Native"
BUILD_DIR = "/Volumes/My Data/Development/Games/TOTK/0100F2C0115B6000_build"
DMHOST_BIN = f"{REPO_DIR}/dm/host/dmhost"

def run_benchmark(save_name, run_seconds=25, screenshot_name=None):
    save_src = f"{REPO_DIR}/test_saves/{save_name}"
    if not os.path.isdir(save_src):
        print(f"Error: Save source {save_src} does not exist!")
        return None

    save_work = f"/tmp/totk_bench_save_{save_name}"
    if os.path.exists(save_work):
        shutil.rmtree(save_work)
    shutil.copytree(save_src, save_work)

    ctl_file = f"/tmp/totk_bench_ctl.txt"
    log_file = f"/tmp/totk_bench_{save_name}.log"

    for f in [ctl_file, log_file]:
        if os.path.exists(f):
            os.remove(f)

    with open(ctl_file, "w") as f:
        f.write("# CTL init\n")

    env = os.environ.copy()
    env.update({
        "DM_ROOT": BUILD_DIR,
        "DM_ROMFS": f"{BUILD_DIR}/extract/v720896/RomFS",
        "DM_SAVE": save_work,
        "DM_TEMP": f"{BUILD_DIR}/run/temp",
        "DM_MSL_DIR": f"{BUILD_DIR}/shader/mac_shaders",
        "DM_FONT_DIR": f"{BUILD_DIR}/font",
        "DM_NVN_SHMAP": f"{REPO_DIR}/dm/games/0100F2C0115B6000/shader_map.tsv",
        "DM_LANG": "en-US",
        "DM_WINDOW": "1",
        "DM_AUDIO": "0",
        "DM_KEEP_FOCUS": "1",
        "DM_FPS_TARGET": "60",
        "DM_TEST_NO_BC": "1",
        "DM_KEYS": "15:A*30/1.5",
        "DM_CTL": ctl_file,
        "DM_TEST_MEM_STAT": "1",
        "DM_TEST_MEM_STAT_FREQ": "60",
    })

    log_fp = open(log_file, "w")
    print(f"[{save_name}] Khởi động dmhost (DM_TEST_NO_BC=1)...")
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

    # Wait for game to enter main world
    start_t = time.time()
    in_game = False
    print(f"[{save_name}] Đang chờ game nạp thế giới (PID={proc.pid})...")
    
    last_pos = 0
    while time.time() - start_t < 50:
        if proc.poll() is not None:
            print(f"[{save_name}] Cảnh báo: dmhost đã dừng sớm với mã thoát {proc.returncode}!")
            break
        time.sleep(1.5)
        if os.path.exists(log_file):
            with open(log_file, "r") as f:
                f.seek(last_pos)
                new_data = f.read()
                last_pos = f.tell()
                if "save commit" in new_data or "frame 600" in new_data or "frame 900" in new_data:
                    in_game = True
                    print(f"[{save_name}] Đã nạp thành công vào thế giới game sau {time.time() - start_t:.1f}s!")
                    break

    if not in_game and proc.poll() is None:
        print(f"[{save_name}] Tiếp tục chờ thêm 10s...")
        time.sleep(10)

    # Perform movement actions
    if proc.poll() is None:
        print(f"[{save_name}] Thực hiện chuỗi di chuyển & camera ({run_seconds}s)...")
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
            shot_path = f"/tmp/{screenshot_name}"
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
                            print(f"[{save_name}] Đã chụp màn hình thành công -> {shot_path}")
                            break
            if not shot_done:
                print(f"[{save_name}] Chưa thấy xác nhận screenshot trong log.")

    # Graceful shutdown
    print(f"[{save_name}] Kết thúc phiên đo đạc, đóng tiến trình...")
    proc.terminate()
    try:
        proc.wait(timeout=5)
    except:
        proc.kill()
    log_fp.close()

    # Parse results
    metrics = {
        "save": save_name,
        "return_code": proc.returncode,
        "peak_rss_mb": 0,
        "peak_gpu_mb": 0,
        "alias_mapped_gb": 0.0,
        "bc_unpacked_mb": 0,
        "astc_standin_mb": 0,
        "headroom_mb": None,
        "jetsam_kill": False,
        "lines": []
    }

    if os.path.exists(log_file):
        with open(log_file, "r") as f:
            for line in f:
                if "simulated Jetsam kill" in line or "resident" in line and "over simulated device limit" in line:
                    metrics["jetsam_kill"] = True
                m_rss = re.search(r"resident (\d+) MB", line)
                if m_rss:
                    rss = int(m_rss.group(1))
                    if rss > metrics["peak_rss_mb"]:
                        metrics["peak_rss_mb"] = rss
                m_gpu = re.search(r"GPU allocated (\d+) MB", line)
                if m_gpu:
                    gpu = int(m_gpu.group(1))
                    if gpu > metrics["peak_gpu_mb"]:
                        metrics["peak_gpu_mb"] = gpu
                m_alias = re.search(r"alias region mapped ([\d\.]+) GB", line)
                if m_alias:
                    metrics["alias_mapped_gb"] = max(metrics["alias_mapped_gb"], float(m_alias.group(1)))
                m_bc = re.search(r"decompressed BC textures made so far: (\d+) MB", line)
                if m_bc:
                    metrics["bc_unpacked_mb"] = max(metrics["bc_unpacked_mb"], int(m_bc.group(1)))
                m_astc = re.search(r"ASTC 4x4 stand-ins: (\d+) MB", line)
                if m_astc:
                    metrics["astc_standin_mb"] = max(metrics["astc_standin_mb"], int(m_astc.group(1)))
                m_head = re.search(r"headroom to the system memory limit (\d+) MB", line)
                if m_head:
                    metrics["headroom_mb"] = int(m_head.group(1))
                if "[mem]" in line or "memory up to frame" in line or "simulated Jetsam" in line:
                    metrics["lines"].append(line.strip())

    print(f"\n--- KẾT QUẢ ĐO ĐẠC [{save_name}] ---")
    print(f"Peak RSS: {metrics['peak_rss_mb']} MB")
    print(f"Peak GPU: {metrics['peak_gpu_mb']} MB")
    print(f"Alias Mapped: {metrics['alias_mapped_gb']:.2f} GB")
    print(f"BC Decompressed: {metrics['bc_unpacked_mb']} MB")
    print(f"ASTC Stand-ins: {metrics['astc_standin_mb']} MB")
    print(f"Headroom còn lại: {metrics['headroom_mb']} MB")
    print(f"Bị Jetsam kill: {metrics['jetsam_kill']}")
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
        print("TỔNG HỢP KẾT QUẢ BENCHMARK A16 BIONIC (3GB CEILING) TOÀN BỘ 7 MAPS:")
        print("="*80)
        print(f"{'Map Name':<30} | {'Peak RSS':<10} | {'Peak GPU':<10} | {'Headroom':<10} | {'Jetsam Kill':<12} | {'Status'}")
        print("-" * 85)
        for r in results:
            status = "PASS" if not r["jetsam_kill"] and r["peak_rss_mb"] <= 3072 else "FAIL"
            hr = f"{r['headroom_mb']} MB" if r['headroom_mb'] is not None else "N/A"
            print(f"{r['save']:<30} | {r['peak_rss_mb']:<4} MB   | {r['peak_gpu_mb']:<4} MB   | {hr:<10} | {str(r['jetsam_kill']):<12} | {status}")
        print("="*80 + "\n")
    else:
        shot = sys.argv[3] if len(sys.argv) > 3 else f"shot_{target}.png"
        run_benchmark(target, sec, shot)
