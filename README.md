# Power Stability Field V2

A Garmin Connect IQ Data Field that calculates and visualizes Power Stability using the Coefficient of Variation (CV).

## Features
- **Real-time 3s Power**: Main display.
- **Dynamic Background**: Changes color based on 3s vs 10s power trends.
- **CV Visualization**: Purple bars indicating power and Kinetic Energy (KE) stability as the rolling 10s Coefficients of Variation CV.
- **FIT Contributions**: Records CV data into .FIT files for post-ride analysis.

## Python Analysis Tools
Located in the `test/` directory:
- `plot_cv.py`: Generates a visualization of CVs  from a exported FIT file.
- `fitparse_run.py`: lists the formatted contents of FIT file

## Testing
### Device Smoke Test
To verify that the app builds and loads on all supported devices without resource errors:
```bash
python3 test/device_smoke_test.py
```

### Usage

see source, there are several debug options