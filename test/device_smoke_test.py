"""
device_smoke_test.py

An automated validation tool to verify build integrity and runtime stability across 
all supported Garmin devices defined in the project manifest.

Description:
    This script automates the 'smoke testing' process by:
    1. Resolving the Connect IQ SDK path from VS Code settings.
    2. Validating the SDK installation integrity (checking api.db size).
    3. Identifying all target devices from manifest.xml.
    4. Compiling the app for each device using the Java-based monkeybrains compiler.
    5. Launching the Connect IQ Simulator and side-loading the app via monkeydo.
    6. Monitoring the simulator for a set period to detect early runtime crashes.

    It provides a summary report at the end, highlighting incompatible SDKs, 
    missing device definitions, build errors, or runtime failures.

Usage:
    python3 test/device_smoke_test.py

Prerequisites:
    - Connect IQ SDK installed and path set in .vscode/settings.json.
    - Java Runtime Environment (JRE) installed and available in PATH.
    - Developer Key (developer_key.der) in the project root.

Configuration:
    - SIM_WAIT_TIME: Adjust this value to change how long the script waits 
      to detect a crash (default: 8 seconds).
    - ROOT_DIR: Automatically calculated relative to this script's location.
"""
import os
import subprocess
import time
import xml.etree.ElementTree as ET
import sys
import signal
from pathlib import Path
import re
import json

# --- Configuration ---
# Use absolute paths relative to the script location for reliability
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
ROOT_DIR = os.path.dirname(SCRIPT_DIR)
DEV_KEY = os.path.join(ROOT_DIR, "developer_key.der")
MANIFEST_PATH = os.path.join(ROOT_DIR, "manifest.xml")
JUNGLE_PATH = os.path.join(ROOT_DIR, "monkey.jungle")
OUTPUT_PRG = os.path.join(ROOT_DIR, "bin", "smoke_test.prg")
SIM_WAIT_TIME = 8  # Seconds to let the app run and check for crashes

def get_sdk_bin_path():
    """
    Reads the SDK path from VS Code settings to ensure consistency between CLI and IDE.
    
    Handles JSON with comments and trailing commas common in VS Code settings.
    Returns:
        Tuple[str, str]: (Path to SDK bin directory, Description of the source).
    """
    settings_path = os.path.join(ROOT_DIR, ".vscode", "settings.json")
    if not os.path.exists(settings_path):
        return "", f"System Environment (PATH) - settings.json not found at {settings_path}"

    try:
        with open(settings_path, 'r') as f:
            content = f.read()
            # Strip comments (// and /* */)
            content = re.sub(r'//.*?\n|/\*.*?\*/', '', content, flags=re.S)
            # Strip trailing commas
            content = re.sub(r',\s*([\]}])', r'\1', content)
            
            data = json.loads(content)
            path = data.get("monkeyC.sdkBinPath")
            if path:
                if os.path.exists(path):
                    # If the path points directly to a file (like 'monkeyc'), use its containing directory
                    if os.path.isfile(path):
                        path = os.path.dirname(path)
                    return path, f"VS Code Settings ({path})"
                else:
                    return "", f"!!! WARNING: Path in settings.json NOT FOUND on disk: {path}"
            return "", "FALLBACK to System Path (Reason: 'monkeyC.sdkBinPath' key missing in settings.json)"
    except Exception as e:
        return "", f"FALLBACK to System Path (Reason: JSON Error parsing settings.json: {e})"
    return "", "System Environment (PATH)"

# Resolve Tool Paths
SDK_BIN_PATH, SDK_SOURCE = get_sdk_bin_path()
MONKEYC = os.path.join(SDK_BIN_PATH, "monkeyc") if SDK_BIN_PATH else "monkeyc"
MONKEYDO = os.path.join(SDK_BIN_PATH, "monkeydo") if SDK_BIN_PATH else "monkeydo"
CONNECTIQ = os.path.join(SDK_BIN_PATH, "connectiq") if SDK_BIN_PATH else "connectiq"
MONKEYBRAINS_JAR = os.path.join(SDK_BIN_PATH, "monkeybrains.jar") if SDK_BIN_PATH else "monkeybrains.jar"

def get_devices():
    """
    Parses manifest.xml to find all supported product IDs.
    Returns:
        List[str]: A list of device IDs (e.g., ['edge1040', 'edge540']).
    """
    try:
        tree = ET.parse(MANIFEST_PATH)
        root = tree.getroot()
        ns = {'iq': 'http://www.garmin.com/xml/connectiq'}
        products = root.findall('.//iq:product', ns)
        return [p.get('id') for p in products]
    except Exception as e:
        print(f"Error parsing manifest: {e}")
        return []

def kill_simulator():
    """
    Force closes the Connect IQ Simulator process based on the operating system.
    Used to ensure a clean slate before testing a new device.
    """
    if sys.platform == "darwin": # macOS
        subprocess.run(["pkill", "-f", "ConnectIQ"], stderr=subprocess.DEVNULL)
    elif sys.platform == "win32": # Windows
        subprocess.run(["taskkill", "/F", "/IM", "simulator.exe"], stderr=subprocess.DEVNULL)
    time.sleep(2)

def get_sdk_info():
    """
    Determines the current Connect IQ SDK version, API level, and installation health.
    
    Returns:
        Tuple[str, str, str]: (Display string, Absolute compiler path, Raw version string).
    """
    sdk_compiler_version = "Unknown"
    sdk_api_level = "Unknown"
    db_status = ""

    # Ensure the SDK bin directory is in the PATH for this subprocess call too
    env_patch = {"PATH": f"{SDK_BIN_PATH}:{os.environ.get('PATH', '')}"} if SDK_BIN_PATH else {}

    try:
        # 1. Get compiler version from monkeyc --version
        ver_res = subprocess.run([MONKEYC, "--version"], capture_output=True, text=True, check=False, timeout=5, env=env_patch)
        if ver_res.returncode == 0:
            match = re.search(r"Connect IQ Compiler version: ([\d.]+)", ver_res.stdout)
            if match:
                sdk_compiler_version = match.group(1)
            else:
                print(f"DEBUG: Could not parse compiler version from: {ver_res.stdout.strip()}")
        else:
            print(f"DEBUG: monkeyc --version failed. Return code: {ver_res.returncode}")
            print(f"DEBUG: stdout: {ver_res.stdout.strip()}")
            print(f"DEBUG: stderr: {ver_res.stderr.strip()}")

        # 2. Get API Level from sdk.version file
        if SDK_BIN_PATH:
            sdk_root = os.path.dirname(SDK_BIN_PATH)
            version_file = os.path.join(sdk_root, "sdk.version")
            if os.path.exists(version_file):
                with open(version_file, 'r') as f:
                    sdk_api_level = f.read().strip()
            else:
                print(f"DEBUG: sdk.version file not found at {version_file}")
                sdk_api_level = "MISSING"

        # 3. Check api.db status
        api_db_path = os.path.join(SDK_BIN_PATH, "api.db")
        if api_db_path and os.path.exists(api_db_path):
            if os.path.exists(api_db_path):
                size_mb = os.path.getsize(api_db_path) / (1024 * 1024)
                db_status = f" | api.db: {size_mb:.2f}MB"
                if size_mb < 0.5:
                    db_status += " [!] CORRUPT"
                # A full 8.x SDK api.db is usually >1MB. Let's use 1MB as a threshold.
                if size_mb < 1.0:
                    db_status += " [!] POTENTIALLY CORRUPT (too small)"
        else:
            db_status = " | [!] api.db MISSING"

        if "CORRUPT" in db_status or "MISSING" in db_status:
            db_status += " -> REINSTALL REQUIRED"

        # Check for devices folder relative to SDK for newer versions
        devices_dir = os.path.join(os.path.dirname(SDK_BIN_PATH), "share", "devices")
        if not os.path.exists(devices_dir):
             db_status += " | [!] share/devices MISSING"

        display_version = f"Compiler: {sdk_compiler_version} (API Level: {sdk_api_level}){db_status}"
        return display_version, os.path.abspath(MONKEYC), sdk_compiler_version # Return compiler version as raw info

    except Exception as e:
        print(f"DEBUG: Exception in get_sdk_info: {e}")
        return f"Error: {str(e)}", str(MONKEYC), "Unknown"

def run_command(cmd, description, env_extra=None):
    """
    Runs a shell command and captures its output.
    Args:
        cmd (List[str]): The command and arguments.
        description (str): Human-readable name of the task.
        env_extra (dict): Extra environment variables (e.g., PATH) to merge.
    Returns:
        Tuple[bool, str]: (Success status, Error output if failed).
    """
    print(f"  > {description}...")
    
    # Merge environment variables to ensure monkeyc can find its sibling tools
    current_env = os.environ.copy()
    if env_extra:
        current_env.update(env_extra)
    
    result = subprocess.run(cmd, capture_output=True, text=True, env=current_env)
    if result.returncode != 0:
        return False, result.stderr.strip()
    return True, ""

def smoke_test_device(device_id, sdk_display_ver, sdk_raw_ver):
    """
    Performs a build and runtime check for a specific device.
    Args:
        device_id (str): The Garmin device ID.
        sdk_display_ver (str): Formatted SDK info.
        sdk_raw_ver (str): Raw compiler version.
    Returns:
        str: Result status (e.g., SUCCESS, BUILD_ERROR, RUNTIME_CRASH).
    """
    # 0. Early check for modern devices on old SDKs
    modern_devices = ["edge540", "edge840", "edge1040", "fr265", "fr965", "fenix7"]
    if device_id in modern_devices and sdk_raw_ver.startswith("5."):
        print(f"\n--- Testing Device: {device_id} ---")
        print(f"  [SKIPPED] Potential API Mismatch.")
        print(f"  HINT: {device_id} usually requires SDK 6.0.0+. Current SDK is {sdk_raw_ver}.")
        return "SDK_OUTDATED"

    # 1. Verify device metadata exists on this machine
    # Garmin devices are usually in ~/Library/Application Support/Garmin/ConnectIQ/Devices/
    device_config_path = os.path.expanduser(f"~/Library/Application Support/Garmin/ConnectIQ/Devices/{device_id}")
    if not os.path.exists(device_config_path):
        print(f"\n--- Testing Device: {device_id} ---")
        print(f"  [ERROR] Device definition not found at: {device_config_path}")
        print(f"  HINT: Download this device using the Connect IQ SDK Manager.")
        return "DEVICE_MISSING"

    print(f"\n--- Testing Device: {device_id} ---")
    
    # 2. Compile
    build_cmd = [
        "java",
        "-Xms1g",
        "-Dfile.encoding=UTF-8",
        "-Dapple.awt.UIElement=true",
        "-jar", MONKEYBRAINS_JAR,
        "-o", OUTPUT_PRG,
        "-f", JUNGLE_PATH,
        "-d", f"{device_id}_sim",
        "-y", DEV_KEY,
        "-w"
    ]
    
    # Ensure the SDK bin directory is in the PATH so monkeyc can find api.db
    env_patch = {"PATH": f"{SDK_BIN_PATH}:{os.environ.get('PATH', '')}"} if SDK_BIN_PATH else {}
    
    success, error_output = run_command(build_cmd, "Compiling", env_extra=env_patch)
    if not success:
        if "requires API Level" in error_output:
            print(f"  [SKIPPED] {device_id} is incompatible with this SDK version.")
            print(f"  Reason: {error_output.strip()}")
            
            # Extract the reported API Level from the compiler's error message
            match = re.search(r"supports up to API Level '([\d.]+)'", error_output)
            compiler_reported_api_level = match.group(1) if match else "Unknown"

            print(f"  HINT: The compiler (version {sdk_raw_ver} from {os.path.basename(MONKEYC)}) is reporting API Level support up to '{compiler_reported_api_level}', but the device requires API Level '6.0.0'.")
            print(f"        This indicates a shallow or corrupted SDK installation. Reinstall steps:")
            print(f"        1. Open the Connect IQ SDK Manager.")
            print(f"        2. Delete and re-download the {sdk_raw_ver} SDK.")
            print(f"        3. Verify that 'api.db' in the bin directory is larger than 1MB.")
            print(f"        5. Check macOS 'Full Disk Access' for the SDK Manager in System Settings.")
            return "SDK_INCOMPATIBLE"
        
        print(f"  [ERROR] Compiling failed!")
        print(f"  {error_output[:200]}...") # Truncate long errors
        return "BUILD_ERROR"

    # 3. Ensure Simulator is running
    # Note: connectiq usually needs to be started manually or via background process
    # We attempt to launch it if not visible
    subprocess.Popen([CONNECTIQ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(2)

    # 4. Run in Simulator
    try:
        run_proc = subprocess.Popen(
            [MONKEYDO, OUTPUT_PRG, device_id],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        
        # Wait to see if it stays alive or crashes
        time.sleep(SIM_WAIT_TIME)
        
        if run_proc.poll() is not None:
            # Process exited early, likely a crash
            _, stderr = run_proc.communicate()
            print(f"  [CRASH] Simulator exited early for {device_id}")
            print(f"  Logs: {stderr}")
            return "RUNTIME_CRASH"
        
        print(f"  [SUCCESS] {device_id} loaded successfully.")
        run_proc.terminate()
        return "SUCCESS"

    except Exception as e:
        print(f"  [EXCEPTION] {e}")
        return "EXCEPTION"
    finally:
        # Clean up the PRG after each run to prevent the VS Code Language Server
        # from attempting to index a file that is rapidly changing.
        if os.path.exists(OUTPUT_PRG):
            try:
                os.remove(OUTPUT_PRG)
            except Exception:
                pass

def main():
    """
    Main execution loop. Validates prerequisites, iterates through devices, 
    and prints the final summary report.
    """
    # Verify critical files exist before starting the suite
    for path, name in [(DEV_KEY, "Developer Key"), (MANIFEST_PATH, "Manifest"), (JUNGLE_PATH, "Jungle file")]:
        if not os.path.exists(path):
            print(f"Error: {name} not found at {path}")
            return

    devices = get_devices()
    if not devices:
        print("No devices found to test.")
        return

    sdk_display, sdk_path, sdk_raw_info = get_sdk_info()
    print("="*30)
    print(f"SMOKE TEST STARTING")
    print(f"SDK Version: {sdk_display}")
    print(f"SDK Path:    {sdk_path}")
    print(f"MONKEYC:     {MONKEYC}")
    print(f"MONKEYDO:    {MONKEYDO}")
    print(f"SDK Source:  {SDK_SOURCE}")
    print("="*30)

    results = {}
    os.makedirs("bin", exist_ok=True)

    try:
        for device in devices:
            # We kill and restart to ensure a clean slate for resource loading
            kill_simulator()
            status = smoke_test_device(device, sdk_display, sdk_raw_info)
            results[device] = status
    except KeyboardInterrupt:
        print("\n\n[!] Smoke test interrupted by user. Cleaning up...")
    finally:
        # Ensure the simulator is closed on exit
        kill_simulator()

    print("\n" + "="*30)
    print("SMOKE TEST SUMMARY")
    print("="*30)
    for dev, res in results.items():
        print(f"{dev:<20}: {res}")

if __name__ == "__main__":
    main()