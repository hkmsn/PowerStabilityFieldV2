# PowerStabilityFieldV2
# Power Stability Field V2

A Garmin Connect IQ Data Field that calculates and visualizes Power Stability using the Coefficient of Variation (CV).

## Features
- **Real-time 3s Power**: Main display.
- **Dynamic Background**: Changes color based on 3s vs 10s power trends.
- **CV Visualization**: A purple bar indicating power delivery stability.
- **FIT Contributions**: Records CV data into your .FIT files for post-ride analysis.

## Python Analysis Tools
Located in the `source/` directory:
- `plot_cv.py`: Generates a visualization of CV and Power from a exported FIT file.

### Usage
```bash
python3 source/plot_cv.py path/to/your/activity.fit