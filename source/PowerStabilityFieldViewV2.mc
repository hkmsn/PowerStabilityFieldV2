import Toybox.Activity;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Math;
using  Toybox.Application as App;
using  Toybox.Graphics    as Gfx;
using  Toybox.FitContributor;

class PowerStabilityFieldViewV2 extends WatchUi.DataField {
    //var mValue as Toybox.Lang.Numeric;
    const HISTORY_SIZE = 10;
    const POWER_NODATA = -1.0f; 
    const LABEL_TEXT   = "KE              3S PWR+               Pwr";
    const DEBUG as Boolean  = false; // Set to false for production release
    const CV_PWR_FIELD_ID     = 0;
    const CV_PWR_SUM_FIELD_ID = 1;
    const CV_KE_FIELD_ID      = 2;
    const CV_KE_SUM_FIELD_ID  = 3;
    private var INVALID_FLOAT = 0.0f;

    // Member variables for state
    private var mPowerHistory as Toybox.Lang.Array<Lang.Float>;
    private var mKEHistory    as Toybox.Lang.Array<Lang.Float>;
    private var mLastSpeedSq  as Lang.Float = 0.0f;
    private var mAvg3s  as Lang.Float = 0.0f;
    private var mAvg10s as Lang.Float = 0.0f;
    private var mStdDev10s as Lang.Float = 0.0f;
    // private var mPowerSpread as Lang.Float = 0.0f;
    private var mCvPwrValue as Lang.Float;

    // Kalman Filter state for KE Stability
    private var mKalmanInitialized as Boolean = false;
    private var mCvKE_P as Lang.Float = 1.0f;

    private var mCvKEValue as Lang.Float;
    private var mCvPwrField as FitContributor.Field or Null;
    private var mCvKEField as FitContributor.Field or Null;
    private var mCvKESessionField as FitContributor.Field or Null;
    private var mCvPwrSessionField as FitContributor.Field or Null; // Corrected declaration
    private var mCvPwrSum   as Lang.Float = 0.0f;
    private var mCvPwrCount as Lang.Number = 0;
    private var mCvKESum as Lang.Float = 0.0f;
    private var mCvKECount as Lang.Number = 0;
    private var mAvg3sDisplay as Lang.String = "---";
    private var mBackgroundColor as Number = Gfx.COLOR_WHITE;
    private const BAR_WIDTH = 42;
    
    // Layout cache - calculated in onLayout
    private var mLabelFont, mValueFont, mCvFont;
    private var mLabelY as Lang.Number = 0;
    private var mValueY as Lang.Number = 0;
    private var mCvX as Lang.Number = 0;
    private var mCvKEX as Lang.Number = 0;
    private var mCvY as Lang.Number = 0;
    
    // User Settings
    private var mHighThreshold    as Lang.Float = 20.0f;
    private var mLowThreshold     as Lang.Float = 10.0f;
    private var mIgnorePower      as Lang.Float = 100.0f;

    function initialize() {
        DataField.initialize();

        // Calculate real NaN. 0x7FC...toFloat() results in a large valid number, not NaN.
        INVALID_FLOAT = Math.sqrt(-1.0);
        mCvPwrValue   = INVALID_FLOAT;
        mCvKEValue    = INVALID_FLOAT;

        // 1. Create Field FIRST. If this doesn't run, the menu option won't appear.
        mCvPwrField = createField(
            WatchUi.loadResource(Rez.Strings.GraphLabel_CV_Pwr) as String,
            CV_PWR_FIELD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>"%"}
        );  

        mCvKEField = createField(
            WatchUi.loadResource(Rez.Strings.GraphLabel_CV_KE) as String,
            CV_KE_FIELD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>"%"}
        );

        mCvKESessionField = createField(
            WatchUi.loadResource(Rez.Strings.CV_KE_Summary) as String, 
            CV_KE_SUM_FIELD_ID,
            FitContributor.DATA_TYPE_FLOAT, 
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION, 
                :units => "%"
            }
        );

        mCvPwrSessionField = createField(
            WatchUi.loadResource(Rez.Strings.CV_Pwr_Summary) as String,
            CV_PWR_SUM_FIELD_ID,
            FitContributor.DATA_TYPE_FLOAT, 
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION, 
                :units => "%"
            }
        );

        // 2. Then load settings (if this fails, the field is at least registered)
        loadSettings();
        
        mPowerHistory    = new [HISTORY_SIZE]     as Lang.Array<Lang.Float>;
        mKEHistory       = new [HISTORY_SIZE]     as Lang.Array<Lang.Float>;
        for (var i = 0; i < HISTORY_SIZE; i++) {
            mPowerHistory[i] = POWER_NODATA;
            mKEHistory[i]    = 0.0f;
        }
        mLastSpeedSq = 0.0f;
        mKalmanInitialized = false;
    }

    private function loadSettings() as Void {
        // Use `has` checks for robust type conversion from app settings.
        // This handles various numeric types (Number, Float, Double, String) gracefully.
        var high = getProperty("HighThresholdPercentageX", 20.0f);
        if (high != null && high has :toFloat) {
            mHighThreshold = high.toFloat();
        } else if (high instanceof Lang.Float) { // Fallback for older SDKs where Float may not have :toFloat
            mHighThreshold = high as Lang.Float;
        } else {
            mHighThreshold = 20.0f;
        }
        var low = getProperty("LowThresholdPercentageX", 10.0f);
        if (low != null && low has :toFloat) {
            mLowThreshold = low.toFloat();
        } else if (low instanceof Lang.Float) {
            mLowThreshold = low as Lang.Float;
        } else {
            mLowThreshold = 10.0f;
        }

        var ignore = getProperty("IgnorePowerWattsX", 100);
        if (ignore != null && ignore has :toFloat) {
            mIgnorePower = ignore.toFloat();
        } else {
            mIgnorePower = 100.0f;
        }
    }

    // Safely retrieve a property with a default value
    private function getProperty(key as String, defaultValue as Object) as Object {
        try {
            var value  = App.Properties.getValue(key);
            var result = defaultValue;
            if (value != null) {
                result = value as Object;
            }
            return result;
        } catch (ex) {
            return defaultValue;
        }
    }

    private function calculateDifference(avg3s as Lang.Float, avg10s as Lang.Float) as Lang.Float {
        var percentage = 0.0f;
        // Only calculate the difference if the 10s average is above the user-defined threshold.
        // This also prevents any potential division by zero.
        if (avg10s > mIgnorePower) {
            var diff = avg3s - avg10s;
            percentage = (diff.abs() / avg10s) * 100.0f;
        }
        return percentage;
    }
    
    private function updateBackgroundColor(percentageDiff as Lang.Float) as Void {
          if (percentageDiff >= mHighThreshold) {
            mBackgroundColor = Gfx.COLOR_RED ;
        } else if (percentageDiff <= mLowThreshold) {
            mBackgroundColor = Gfx.COLOR_BLUE;
        } else {
            mBackgroundColor = Gfx.COLOR_GREEN; 
        }
    }

    // The layout is variable, so we just need to position our strings
    // This is called when the data field is placed on the screen, and then
    // again if the user changes the layout.
    function onLayout(dc as Gfx.Dc) as Void {
        var width  = dc.getWidth();
        var height = dc.getHeight();

        // 2. Scale Fonts Based on Height
        // Standard Garmin layouts use Tiny/Small for labels and Number fonts for values
        if (height >= 120) {
            mValueFont = Gfx.FONT_NUMBER_HOT;   // Large full-screen fields
            mLabelFont = Gfx.FONT_SMALL;
        } else if (height >= 90) {
            mValueFont = Gfx.FONT_NUMBER_MEDIUM; // Standard 2-4 field layouts
            mLabelFont = Gfx.FONT_TINY;
        } else if (height >= 60) {
            mValueFont = Gfx.FONT_NUMBER_MILD;   // Smaller 6-field layouts
            mLabelFont = Gfx.FONT_XTINY;
        } else if (height >= 40) {
            mValueFont = Gfx.FONT_MEDIUM;        // Tight layouts (e.g. 10 fields)
            mLabelFont = Gfx.FONT_XTINY;
        } else {
            mValueFont = Gfx.FONT_SMALL;         // Very small fields
            mLabelFont = Gfx.FONT_XTINY;
        }
        mCvFont = Gfx.FONT_SMALL;

        // 3. Dynamic Positioning
        // Manually calculate the 'y' coordinate for the top of the text.
        // Desired center for the label (top 15% of the screen)
        var labelCenterY = height * 0.15;
        // Desired center for the value (in the middle of the remaining space)
        var valueCenterY = (height + labelCenterY) / 2;

        // Adjust Y coordinates to be the top of the text box for drawing
        mLabelY = (labelCenterY - (dc.getFontHeight(mLabelFont) / 2)).toNumber();
        mValueY = (valueCenterY - (dc.getFontHeight(mValueFont) / 2)).toNumber();

        // Position CV in bottom right
        mCvX   = width  - (BAR_WIDTH / 2);
        mCvKEX = BAR_WIDTH / 2;
        mCvY   = height - dc.getFontHeight(mCvFont) - 2;
    }

    // Called when the activity is saved or cancelled
    function onTimerReset() as Void {
        mCvPwrSum = 0.0f;
        mCvPwrCount = 0;
        mCvKESum = 0.0f;
        mCvKECount = 0;
        // Reset history to ensure a clean start for the next session
        for (var i = 0; i < HISTORY_SIZE; i++) {
            mPowerHistory[i] = POWER_NODATA;
            mKEHistory[i]    = 0.0f;
        }
        mLastSpeedSq = 0.0f;
        mKalmanInitialized = false;
    }

     private function calculateStats(history as Array<Float>, size as Number, noDataValue as Float, ignorePower as Float, invalidValue as Float) as Array<Float> {
        var s3 = 0.0f,  c3 = 0;
        var s10 = 0.0f, sq10 = 0.0f, c10 = 0;

        for (var i = 1; i <= size; i++) {
            var val = history[size - i];
            // Check for null, nodata, and NaN (val == val is false for NaN)
            if (val != null && val != noDataValue && val == val && val > 1) {
                if (i <= 3) { s3 += val; c3++; }
                if (i <= 10) { 
                    s10 += val; 
                    sq10 += (val * val);
                    c10++; 
                }
            }
        }

        var avg3s  = (c3 > 0)  ? (s3 / c3.toFloat())   : 0.0f;
        var avg10s = (c10 > 0) ? (s10 / c10.toFloat()) : 0.0f;
        var stdDev = 0.0f;
        var cv     = invalidValue;

        if (c10 > 1) {
            var variance = (sq10 / c10.toFloat()) - (avg10s * avg10s);
            stdDev = Math.sqrt(variance < 0 ? 0 : variance).toFloat();
        }

        if (avg10s >= ignorePower && avg10s > 0) {
            cv = (stdDev / avg10s) * 100.0f;
        }
        
        return [avg3s, avg10s, stdDev, cv] as Array<Float>;
    }

    function compute(info as Activity.Info) as Lang.String or Null {
        // Check if settings have changed and reload them if necessary
        if (getApp().settingsChanged) {
            loadSettings();
            getApp().settingsChanged = false;
        }
        
        var timerRunning = (info has :timerState && info.timerState == Activity.TIMER_STATE_ON);
        var currentPower = info.currentPower;
        var powerValue = POWER_NODATA;
        
        var currentSpeedSq = 0.0f;
        if (info has :currentSpeed && info.currentSpeed != null) {
            var s = info.currentSpeed.toFloat();
            currentSpeedSq = s * s;
        }
        var speedSqDelta = (currentSpeedSq - mLastSpeedSq).abs();
        mLastSpeedSq     = currentSpeedSq;

        if (currentPower == null) {
            mCvPwrValue = INVALID_FLOAT;
            mAvg3sDisplay = "---";
        } else {
            powerValue = (currentPower has :toFloat) ? currentPower.toFloat() : currentPower as Lang.Float;
        }

        // 1. Update History Arrays (Decays if values are POWER_NODATA or 0)
        for (var i = 0; i < HISTORY_SIZE - 1; i++) {
            mPowerHistory[i] = mPowerHistory[i+1];
            mKEHistory[i]    = mKEHistory[i+1];
        }
        mPowerHistory[HISTORY_SIZE - 1] = powerValue;
        mKEHistory[HISTORY_SIZE    - 1] = speedSqDelta;

        // 2. Single-Pass Statistics Calculation
        var statsPwr = calculateStats(mPowerHistory, HISTORY_SIZE, POWER_NODATA, mIgnorePower, INVALID_FLOAT);
        mAvg3s     = statsPwr[0];
        mAvg10s    = statsPwr[1];
        mStdDev10s = statsPwr[2];
        mCvPwrValue = statsPwr[3];

        
        var statsKE = calculateStats(mKEHistory, HISTORY_SIZE, 0.0, -1.0, INVALID_FLOAT);
        var measurementKE = statsKE[3];

        // Apply Simple Kalman Filter to KE Stability
        if (measurementKE == measurementKE) { // Check if not NaN
            if (!mKalmanInitialized) {
                mCvKEValue = measurementKE;
                mCvKE_P = 1.0f;
                mKalmanInitialized = true;
            } else {
                // Predict (Q = 0.05: Process noise, how much we trust the model to change)
                mCvKE_P = mCvKE_P + 0.05f;
                // Update (R = 0.8: Measurement noise, higher means more smoothing/less trust in raw data)
                var K = mCvKE_P / (mCvKE_P + 0.5f); //0.8 changed to 0.5
                mCvKEValue = mCvKEValue + K * (measurementKE - mCvKEValue);
                mCvKE_P = (1.0f - K) * mCvKE_P;
            }
        } else {
            mCvKEValue = INVALID_FLOAT;
            mKalmanInitialized = false;
        }

        if (currentPower != null) {
            mAvg3sDisplay = mAvg3s.format("%.0f");
        }

        if (DEBUG) {
            System.println("mAvg3s:     " + mAvg3s);
            System.println("mAvg10s:    " + mAvg10s);
            System.println("mStdDev10s: " + mStdDev10s);
            System.println("mCvPwrValue: " + mCvPwrValue);
            System.println("mCvKEValue: " + mCvKEValue);
        }

        // 3. Stability Metrics and FIT Recording
        if (mAvg10s >= mIgnorePower) {
            // Metric 1: Trend Stability (3s vs 10s) -> Used for Background Color
            var trendDiff = calculateDifference(mAvg3s, mAvg10s);
            updateBackgroundColor(trendDiff);
            
            // Metric 2: Delivery Stability (CV) -> Used for Graphical Bar
            if (timerRunning) {
                if (mCvPwrValue == mCvPwrValue) { // Check if not NaN
                    mCvPwrSum += mCvPwrValue;
                    mCvPwrCount++;
                }
                if (mCvKEValue == mCvKEValue) {
                    mCvKESum += mCvKEValue;
                    mCvKECount++;
                }
            }
        }

        if (timerRunning) {

            if (mCvPwrField != null && mCvPwrValue == mCvPwrValue) {
                mCvPwrField.setData(mCvPwrValue);
            }
            if (mCvKEField != null && mCvKEValue == mCvKEValue) {
                mCvKEField.setData(mCvKEValue);
            }
            if (mCvPwrSessionField != null && mCvPwrCount > 0) { // Use the correctly named field
                mCvPwrSessionField.setData(mCvPwrSum / mCvPwrCount.toFloat());
            }
            if (mCvKESessionField != null && mCvKECount > 0) {
                mCvKESessionField.setData(mCvKESum / mCvKECount.toFloat());
            }
        }
        return mAvg3sDisplay;
    }

    function onUpdate(dc as Gfx.Dc) as Void {
        var width  = dc.getWidth();
        // 1. Determine Background and Text Colors based on device theme
        var bgColor;
        if (mAvg10s >= mIgnorePower) {
            bgColor = mBackgroundColor; // Use the pre-calculated status color (red/green/blue)
        } else {
            bgColor = getBackgroundColor(); // Use the default system theme background color
        }
        var fgColor = (bgColor == Gfx.COLOR_BLACK || bgColor == Gfx.COLOR_DK_GRAY) ? Gfx.COLOR_WHITE : Gfx.COLOR_BLACK;
        var labelColor = (bgColor == Gfx.COLOR_BLACK || bgColor == Gfx.COLOR_DK_GRAY) ? Gfx.COLOR_LT_GRAY : Gfx.COLOR_DK_GRAY;

        // 2. Clear screen and set drawing colors
        dc.setColor(Gfx.COLOR_TRANSPARENT, bgColor);
        dc.clear();

        var maxHeightValue = 50.0f;
        var fieldHeight = dc.getHeight();
        var ticks = [10, 20, 30];

        // 3a. Draw Kinetic Energy Stability Bar (Left Side)
        if (mAvg10s > mIgnorePower && mCvKEValue == mCvKEValue) {
            var barHeightKE = (mCvKEValue / maxHeightValue) * fieldHeight;
            if (barHeightKE > fieldHeight) { barHeightKE = fieldHeight.toFloat(); }
            if (barHeightKE < 0) { barHeightKE = 0.0f; }

            dc.setColor(Gfx.COLOR_PURPLE, Gfx.COLOR_TRANSPARENT);
            dc.fillRectangle(0, (fieldHeight - barHeightKE).toNumber(), BAR_WIDTH, barHeightKE.toNumber());

            // Ticks
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            for (var i = 0; i < ticks.size(); i++) {
                var tickY = (fieldHeight - (ticks[i].toFloat() / maxHeightValue * fieldHeight)).toNumber();
                dc.drawLine(0, tickY, BAR_WIDTH, tickY);
            }

            // Text
            dc.setColor(fgColor, Gfx.COLOR_TRANSPARENT);
            dc.drawText(mCvKEX, mCvY, mCvFont, mCvKEValue.format("%.0f") + "%", Gfx.TEXT_JUSTIFY_CENTER);
        }

        // 3. Draw the Power Stability (CV) bar on the right edge (Background layer)
        // Drawing this before the text ensures the main power value remains legible.
        if (mAvg10s > mIgnorePower && mCvPwrValue == mCvPwrValue) {
            
            // Calculate height relative to 50
            var barHeight = (mCvPwrValue / maxHeightValue) * fieldHeight;
            
            // Clamp the height to field boundaries
            if (barHeight > fieldHeight) { barHeight = fieldHeight.toFloat(); }
            if (barHeight < 0) { barHeight = 0.0f; }

            dc.setColor(Gfx.COLOR_PURPLE, Gfx.COLOR_TRANSPARENT);
            dc.fillRectangle(width - BAR_WIDTH, (fieldHeight - barHeight).toNumber(), BAR_WIDTH, barHeight.toNumber());

            // 5. Draw tick marks at CV 10, 20, and 30
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            for (var i = 0; i < ticks.size(); i++) {
                var tickY = (fieldHeight - (ticks[i].toFloat() / maxHeightValue * fieldHeight)).toNumber();
                dc.drawLine(width - BAR_WIDTH, tickY, width, tickY);
            }

            // 6. Draw the CV text centered on the bar
            dc.setColor(fgColor, Gfx.COLOR_TRANSPARENT);
            dc.drawText(mCvX, mCvY, mCvFont, mCvPwrValue.format("%.0f") + "%", Gfx.TEXT_JUSTIFY_CENTER);
        }

        // 4. Draw labels and main power value (Foreground layer)
        dc.setColor(labelColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(width / 2, mLabelY, mLabelFont, LABEL_TEXT, Gfx.TEXT_JUSTIFY_CENTER);

        dc.setColor(fgColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(width / 2, mValueY, mValueFont, mAvg3sDisplay, Gfx.TEXT_JUSTIFY_CENTER);
    }
}