import fitparse
import sys
import argparse
from typing import List, Tuple
from pathlib import Path
import pandas as pd
import matplotlib.pyplot as plt
import matplotlib.dates as mdates
from datetime import timedelta

DEFAULT_FIT_PATH = "source/session1.fit"

def parse_fit_file(file_path: str) -> Tuple[List, List, List]:
    """Parses a FIT file and extracts timestamp and CV data."""
    timestamps, cv_values, power_values = [], [], []
    try:
        fitfile = fitparse.FitFile(file_path)
    except FileNotFoundError:
        return [], [], []

    for record in fitfile.get_messages("record"):
        # Convert record to a dictionary for easier access
        data_dict = {}
        for data in record:
            data_dict[data.name] = data.value
            # Explicitly map developer field index 0 to 'cv_dev' if name is missing
            if getattr(data, 'field_def_num', None) == 0:
                data_dict['cv_dev'] = data.value
        
        if 'timestamp' in data_dict:
            timestamps.append(data_dict['timestamp'])
            # Look for named field or the developer field index 0
            cv = data_dict.get('CV') or data_dict.get('cv') or data_dict.get('cv_dev')
            cv_values.append(cv)
            power_values.append(data_dict.get('power') or data_dict.get('Power'))
            
    # Filter out entries where both CV and Power are missing
    valid_data = [(t, c, p) for t, c, p in zip(timestamps, cv_values, power_values) if t and (c is not None or p is not None)]
    if not valid_data: return [], [], []
    
    timestamps, cv_values, power_values = zip(*valid_data)

    return list(timestamps), list(cv_values), list(power_values)

def create_dataframe(timestamps: list, cv_values: list, power_values: list) -> pd.DataFrame:
    """Creates a Pandas DataFrame from timestamps, CV, and power values."""
    df = pd.DataFrame({
        'timestamp': timestamps, 
        'cv': cv_values,
        'power': power_values
    })
    df['timestamp'] = pd.to_datetime(df['timestamp'])
    df.set_index('timestamp', inplace=True)
    # Fill missing values to ensure smooth rolling calculations
    df = df.ffill().bfill()
    return df

def plot_cv_data(df: pd.DataFrame, filename: str = 'cv_plot1.png'):
    """Plots CV data over time and saves the plot to a file."""
    fig, ax1 = plt.subplots(figsize=(12, 6))
    
    # Plot Power on secondary axis
    ax2 = ax1.twinx()
    ax2.fill_between(df.index, df['power'], color='gray', alpha=0.1, label='Power (W)')
    ax2.set_ylabel('Power (Watts)', color='gray')
    ax2.tick_params(axis='y', labelcolor='gray')

    # Plot raw data points with reduced transparency
    ax1.plot(df.index, df['cv'], marker='.', linestyle='-', markersize=2, linewidth=0.5, alpha=0.3, label='Raw CV', color='blue')
    
    # Add an Exponential Moving Average for smoother visualization
    df['cv_smooth'] = df['cv'].ewm(span=30, adjust=False).mean()
    ax1.plot(df.index, df['cv_smooth'], color='red', linewidth=1.5, label='Smoothed CV (EMA)')

    ax1.set_title('Power Stability (CV) and Power Output')
    ax1.set_xlabel('Session Time')
    ax1.set_ylabel('CV (%)', color='blue')
    ax1.tick_params(axis='y', labelcolor='blue')

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

    plt.savefig(filename)  # Save the plot to a file
    plt.close()  # Close the plot to free memory
    # print(f"CV plot saved to {filename}")

def main():
    parser = argparse.ArgumentParser(description="Visualize Power Stability (CV) from a FIT file.")
    parser.add_argument("input", nargs="?", default=DEFAULT_FIT_PATH, help="Path to the .FIT file")
    parser.add_argument("--output", default="cv_plot1.png", help="Output filename for the plot")
    
    args = parser.parse_args()

    print(f"Processing: {args.input}...")
    timestamps, cv_values, power_values = parse_fit_file(args.input)

    if not timestamps:
        print(f"Error: No data found in {args.input}. Check the file path and format.")
        return

    df = create_dataframe(timestamps, cv_values, power_values)
    
    if df['cv'].isnull().all():
        print(f"Error: The FIT file {args.input} contains no CV data to plot.")
        return

    plot_cv_data(df, filename=args.output)
    print(f"Successfully saved plot to {args.output}")

if __name__ == "__main__":
    main()