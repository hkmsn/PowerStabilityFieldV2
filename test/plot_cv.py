"""
plot_cv.py

A tool to visualize Power & KE Stability (Coefficient of Variation) and 
Power output from Garmin FIT files.

Description:
    This script parses a FIT file to extract 'CV_Pwr', 'CV_KE' (developer fields)
    and 'power' data. It generates a visualization showing 
    optional raw CV points, smoothed Exponential Moving Averages (EMA), and Power 
    output. 

    The output plot filename is automatically appended with the date (YYYY-MM-DD) 
    found in the FIT data.

Usage:
    python3 test/plot_cv.py [input_file] [--output filename] [--show-raw]

Examples:
    Basic usage:
        python3 test/plot_cv.py
    
    Specify a specific FIT file and custom output name:
        python3 test/plot_cv.py path/to/ride.fit --output stability_analysis.png --show-raw

Arguments:
    input       The path to the .FIT file (default: session.fit in the script's directory).
    --output    The base name for the output plot (default: cv_plot.png).
    --tz        Timezone offset in hours (default: 7).
    --show-raw  Include raw CV data points in the visualization (default: False).
"""
import os
import matplotlib
matplotlib.use('Agg')  # Set non-interactive backend to avoid macOS persistence warnings
import fitparse
import sys
import argparse
from typing import List, Tuple
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates

# Set FIT_FILE_PATH to look for session.fit in the same directory as this script
FIT_FILE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "session.fit")

def get_first_valid(data_dict, keys):
    """Returns the first non-None value found in the dictionary for the given keys."""
    for k in keys:
        val = data_dict.get(k)
        if val is not None:
            return val
    return None

# Manual mapping for standard Garmin fields that fitparse might not recognize yet
KNOWN_GARMIN_FIELDS = {
    107: "fractional_cadence",
    134: "enhanced_speed",
    137: "torque_effectiveness",
    138: "pedal_smoothness",
    144: "performance_condition"
}

def parse_fit_file(file_path: str) -> Tuple[List, List, List, List]:
    """Parses a FIT file and extracts timestamp, Pwr CV, KE CV, and Power data."""
    timestamps, cv_pwr_values, cv_ke_values, power_values = [], [], [], []
    try:
        fitfile = fitparse.FitFile(file_path)
    except Exception as e:
        print(f"Error reading FIT file {file_path}: {e}")
        return [], [], [], []

    # 1. Map developer field definition numbers to names (from field_description messages)
    dev_field_names = {}
    for msg in fitfile.get_messages('field_description'):
        idx = msg.get_value('developer_data_index')
        f_num = msg.get_value('field_definition_number')
        name = msg.get_value('field_name')
        if idx is not None and f_num is not None:
            dev_field_names[(idx, f_num)] = name

    # 2. Parse records
    for record in fitfile.get_messages("record"):
        # Convert record to a dictionary for easier access
        data_dict = {}
        for data in record:
            name = data.name
            field_id = getattr(data, 'def_num', None)

            # Handle Developer Fields
            if hasattr(data, 'is_developer') and data.is_developer:
                d_idx = getattr(data, 'developer_data_index', None)
                name = dev_field_names.get((d_idx, field_id), name)
                # Fallback mapping for index-based detection
                if field_id == 0: data_dict['cv_pwr_dev'] = data.value
                if field_id == 1: data_dict['cv_ke_dev'] = data.value
            
            # Handle unknown Garmin fields
            elif name and name.startswith("unknown") and field_id in KNOWN_GARMIN_FIELDS:
                name = KNOWN_GARMIN_FIELDS[field_id]
            
            if name:
                data_dict[name] = data.value

        if 'timestamp' in data_dict:
            timestamps.append(data_dict['timestamp'])
            
            # Use labels defined in strings.xml and standard keys
            cv_pwr = get_first_valid(data_dict, ['CV_Pwr', 'Pwr Stability', 'Avg Pwr Stability', 'CV', 'cv', 'cv_pwr_dev'])
            cv_ke = get_first_valid(data_dict, ['CV_KE', 'KE Stability', 'Avg KE Stability', 'cv_ke', 'cv_ke_dev'])
            
            power_values.append(get_first_valid(data_dict, ['power', 'Power']))
            cv_pwr_values.append(cv_pwr)
            cv_ke_values.append(cv_ke)
            
    # Debug output for field discovery
    print(f"  - Record messages parsed: {len(timestamps)}")
    print(f"  - Pwr CV valid values: {sum(1 for v in cv_pwr_values if v is not None)}")
    print(f"  - KE CV valid values: {sum(1 for v in cv_ke_values if v is not None)}")
            
    # Filter out entries where data is entirely missing
    valid_data = [(t, cp, ck, p) for t, cp, ck, p in zip(timestamps, cv_pwr_values, cv_ke_values, power_values) 
                  if t and (cp is not None or ck is not None or p is not None)]
    if not valid_data: return [], [], [], []
    
    timestamps, cv_pwr_values, cv_ke_values, power_values = zip(*valid_data)

    return list(timestamps), list(cv_pwr_values), list(cv_ke_values), list(power_values)

def create_dataframe(timestamps: list, cv_pwr_values: list, cv_ke_values: list, power_values: list) -> pd.DataFrame:
    """Creates a Pandas DataFrame from timestamps, CVs, and power values."""
    df = pd.DataFrame({
        'timestamp': timestamps, 
        'cv_pwr': cv_pwr_values,
        'cv_ke': cv_ke_values,
        'power': power_values
    })
    df['timestamp'] = pd.to_datetime(df['timestamp'])
    df.set_index('timestamp', inplace=True)
    df.sort_index(inplace=True)

    # Force numeric conversion to avoid 'object' dtype issues in matplotlib/numpy
    # when the input data contains None or non-numeric values.
    for col in ['cv_pwr', 'cv_ke', 'power']:
        df[col] = pd.to_numeric(df[col], errors='coerce')

    return df

def plot_cv_data(df: pd.DataFrame, filename: str = 'cv_plot.png', show_raw: bool = False):
    """Plots CV data over time and saves the plot to a file."""
    fig, ax1 = plt.subplots(figsize=(12, 6))
    
    # Plot Power on secondary axis
    ax2 = ax1.twinx()
    p_data = df['power'].dropna()
    if not p_data.empty:
        ax2.fill_between(p_data.index, p_data, color='gray', alpha=0.1, label='Power (W)')
    ax2.set_ylabel('Power (Watts)', color='gray')
    ax2.tick_params(axis='y', labelcolor='gray')

    # Plot Power Stability (Pwr CV)
    if not df['cv_pwr'].isnull().all(): # Only plot if there's any data
        if show_raw:
            raw_pwr = df['cv_pwr'].dropna()
            ax1.plot(raw_pwr.index, raw_pwr, marker='o', linestyle='', markersize=3, alpha=0.4, color='blue', label='Raw Pwr CV', zorder=3)
        # Forward fill only for the smooth line calculation to bridge gaps
        smooth_pwr = df['cv_pwr'].ffill().ewm(span=30, adjust=False).mean()
        ax1.plot(smooth_pwr.index, smooth_pwr, color='blue', linewidth=1.5, label='Pwr Stability (EMA)')

    # Plot KE Stability (KE CV)
    if not df['cv_ke'].isnull().all(): # Only plot if there's any data
        if show_raw:
            raw_ke = df['cv_ke'].dropna()
            ax1.plot(raw_ke.index, raw_ke, marker='o', linestyle='', markersize=3, alpha=0.4, color='red', label='Raw KE CV', zorder=3)
        smooth_ke = df['cv_ke'].ffill().ewm(span=30, adjust=False).mean()
        ax1.plot(smooth_ke.index, smooth_ke, color='red', linewidth=1.5, label='KE Stability (EMA)')

    ax1.set_title('Power & KE Stability (CV)')
    # Move ax1 (stability lines/dots) to the front of ax2 (power background fill)
    ax1.set_zorder(ax2.get_zorder() + 1)
    ax1.patch.set_visible(False)

    ax1.set_xlabel('Session Time')
    ax1.set_ylabel('Stability Index (CV %)', color='black')
    ax1.tick_params(axis='y', labelcolor='black')
    ax1.set_ylim(0, max(df['cv_pwr'].max() or 0, df['cv_ke'].max() or 0) * 1.1)

    # Set X-axis to show only start and end times
    ax1.set_xticks([df.index[0], df.index[-1]])
    ax1.xaxis.set_major_formatter(mdates.DateFormatter('%H:%M:%S'))

    ax1.grid(True, which='both', linestyle='--', alpha=0.5)
    plt.xticks(rotation=45)
    
    # Combined legend
    lines, labels = ax1.get_legend_handles_labels()
    lines2, labels2 = ax2.get_legend_handles_labels()
    ax1.legend(lines + lines2, labels + labels2, loc='upper right')

    plt.tight_layout()
    
    # Ensure the directory for the output file exists
    output_path = Path(filename)
    if output_path.parent != Path('.'):
        output_path.parent.mkdir(parents=True, exist_ok=True)

    plt.savefig(filename)  # Save the plot to a file
    plt.close()  # Close the plot to free memory
    # print(f"CV plot saved to {filename}")

def main():
    parser = argparse.ArgumentParser(description="Visualize Power Stability (CV) from a FIT file.")
    parser.add_argument("input", nargs="?", default=FIT_FILE_PATH, help="Path to the .FIT file")
    parser.add_argument("--output", default="cv_plot.png", help="Output filename for the plot")
    parser.add_argument("--tz", type=int, default=7, help="Timezone offset in hours (default: 7)") # Default 7 for UTC+7
    parser.add_argument("--show-raw", action="store_true", help="Display raw CV data points (default: False)")
    
    args = parser.parse_args()

    print(f"Python Interpreter: {sys.executable}")
    print(f"Processing: {args.input}...")
    timestamps, cv_pwr, cv_ke, power_values = parse_fit_file(args.input)

    if not timestamps:
        print(f"Error: No data found in {args.input}. Check the file path and format.")
        return

    df = create_dataframe(timestamps, cv_pwr, cv_ke, power_values)
    
    # Adjust for local timezone
    df.index = df.index + pd.Timedelta(hours=args.tz)

    if df['cv_pwr'].isnull().all() and df['cv_ke'].isnull().all():
        print(f"Error: The FIT file {args.input} contains no stability (CV) data to plot.")
        return

    # Use the first local date in the filename (e.g., cv_plot_2024-05-20.png)
    date_str = df.index[0].strftime('%Y-%m-%d')
    args.output = f"cv_plot_{date_str}.png"

    plot_cv_data(df, filename=args.output, show_raw=args.show_raw)
    print(f"Successfully saved plot to {args.output}")

if __name__ == "__main__":
    main()