import fitparse
from datetime import timedelta
import argparse
from pathlib import Path

def examine_fit_records(file_path: str, tz_offset: int = 7):
    if not Path(file_path).exists():
        print(f"Error: File {file_path} not found.")
        return

    fitfile = fitparse.FitFile(file_path)

    for record in fitfile.get_messages("record"):
        print("-" * 20)
        for data in record:
            if data.name == 'timestamp' and data.value:
                local_ts = data.value + timedelta(hours=tz_offset)
                print(f"{'Time (UTC)':<15}: {data.value}")
                print(f"{'Time (Local)':<15}: {local_ts}")
            else:
                print(f"{str(data.name):<15}: {data.value}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Inspect raw FIT file records.")
    parser.add_argument("input", nargs="?", default="source/session1.fit", help="Path to the .FIT file")
    parser.add_argument("--tz", type=int, default=7, help="Timezone offset in hours (default: 7)")
    
    args = parser.parse_args()
    examine_fit_records(args.input, tz_offset=args.tz)
