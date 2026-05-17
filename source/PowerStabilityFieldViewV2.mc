import Toybox.Activity;
import Toybox.Lang;
import Toybox.WatchUi;
import Toybox.Math;
using  Toybox.Application as App;
using  Toybox.Graphics    as Gfx;
using  Toybox.FitContributor;

class PowerStabilityFieldViewV2 extends WatchUi.DataField {
    //var mValue as Toybox.Lang.Numeric;
    const HISTORY_SIZE = 20;
    const POWER_NODATA = -1.0f;
    const LABEL_TEXT   = "3S PWR+";
    const DEBUG as Boolean  = false; // Set to false for production release
    const CV_FIELD_ID  = 0;
    private var INVALID_FLOAT = 0.0f;

    // Member variables for state
    private var mPowerHistory as Toybox.Lang.Array<Lang.Float>;
    private var mAvg3s as Lang.Float = 0.0f;
    private var mAvg10s as Lang.Float = 0.0f;
    private var mAvg20s as Lang.Float = 0.0f;
    private var mStdDev10s as Lang.Float = 0.0f;
    // private var mPowerSpread as Lang.Float = 0.0f;
    private var mCvValue as Lang.Float;
    private var mCvField as FitContributor.Field or Null;
    private var mCvSessionField as FitContributor.Field or Null;
    private var mCvSum as Lang.Float = 0.0f;
    private var mCvCount as Lang.Number = 0;
    private var mAvg3sDisplay as Lang.String = "---";
    private var mBackgroundColor as Number = Gfx.COLOR_WHITE;
    private const BAR_WIDTH = 42;
    
    // Layout cache - calculated in onLayout
    private var mLabelFont, mValueFont, mCvFont;
    private var mLabelY as Lang.Number = 0;
    private var mValueY as Lang.Number = 0;
    private var mCvX as Lang.Number = 0;
    private var mCvY as Lang.Number = 0;
    
    // User Settings
    private var mHighThreshold    as Lang.Float = 10.0f;
    private var mLowThreshold     as Lang.Float = 5.0f;
    private var mIgnorePower      as Lang.Float = 100.0f;

    private var   mSmoothingBuffer as Lang.Array<Lang.Float>;
    private const SMOOTHING_WINDOW = 3;

    function initialize() {
        DataField.initialize();

        // Calculate real NaN. 0x7FC...toFloat() results in a large valid number, not NaN.
        INVALID_FLOAT = Math.sqrt(-1.0);
        mCvValue = INVALID_FLOAT;

        // 1. Create Field FIRST. If this doesn't run, the menu option won't appear.
        mCvField = createField(
            WatchUi.loadResource(Rez.Strings.GraphLabel_CV) as String,
            CV_FIELD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            {:mesgType=>FitContributor.MESG_TYPE_RECORD, :units=>"%"}
        );  

        mCvSessionField = createField(
            WatchUi.loadResource(Rez.Strings.CV_Summary) as String, 
            1, // Use a different ID than your graph field
            FitContributor.DATA_TYPE_FLOAT, 
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION, 
                :units => "%"
            }
        );

        // 2. Then load settings (if this fails, the field is at least registered)
        loadSettings();
        
        mPowerHistory = new [HISTORY_SIZE] as Lang.Array<Lang.Float>;
        mSmoothingBuffer = new [SMOOTHING_WINDOW] as Lang.Array<Lang.Float>;
        for (var i = 0; i < HISTORY_SIZE; i++) {
            mPowerHistory[i] = POWER_NODATA;
        }
        for (var i = 0; i < SMOOTHING_WINDOW; i++) {
            mSmoothingBuffer[i] = POWER_NODATA;
        }
    }

    private function loadSettings() as Void {
        // Use `has` checks for robust type conversion from app settings.
        // This handles various numeric types (Number, Float, Double, String) gracefully.
        var high = getProperty("HighThresholdPercentageX", 10.0f);
        if (high != null && high has :toFloat) {
            mHighThreshold = high.toFloat();
        } else if (high instanceof Lang.Float) { // Fallback for older SDKs where Float may not have :toFloat
            mHighThreshold = high as Lang.Float;
        } else {
            mHighThreshold = 10.0f;
        }

        var low = getProperty("LowThresholdPercentageX", 5.0f);
        if (low != null && low has :toFloat) {
            mLowThreshold = low.toFloat();
        } else if (low instanceof Lang.Float) {
            mLowThreshold = low as Lang.Float;
        } else {
            mLowThreshold = 5.0f;
        }

        var ignore = getProperty("IgnorePowerWattsX", 50);
        if (ignore != null && ignore has :toFloat) {
            mIgnorePower = ignore.toFloat();
        } else {
            mIgnorePower = 50.0f;
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
        mCvX = width  - (BAR_WIDTH / 2);
        mCvY = height - dc.getFontHeight(mCvFont) - 2;
    }

    // Called when the activity is saved or cancelled
    function onTimerReset() as Void {
        mCvSum = 0.0f;
        mCvCount = 0;
        // Reset history to ensure a clean start for the next session
        for (var i = 0; i < HISTORY_SIZE; i++) {
            mPowerHistory[i] = POWER_NODATA;
        }
        for (var i = 0; i < SMOOTHING_WINDOW; i++) {
            mSmoothingBuffer[i] = POWER_NODATA;
        }
    }

    function compute(info as Activity.Info) as Lang.String or Null {
        // Check if settings have changed and reload them if necessary
        if (getApp().settingsChanged) {
            loadSettings();
            getApp().settingsChanged = false;
        }
        
        var timerRunning = (info has :timerState && info.timerState == Activity.TIMER_STATE_ON);
        var currentPower = info.currentPower;
        var smoothedPower = POWER_NODATA;

        // 1. Update Smoothing Buffer and Calculate Current Smoothed Power
        if (currentPower == null) {
            // No sensor data: flush smoothing buffer immediately
            for (var i = 0; i < SMOOTHING_WINDOW; i++) {
                mSmoothingBuffer[i] = POWER_NODATA;
            }
            mCvValue = INVALID_FLOAT;
            mAvg3sDisplay = "---";
        } else {
            var powerValue = (currentPower has :toFloat) ? currentPower.toFloat() : currentPower as Lang.Float;
            var smoothSum = 0.0f;
            var smoothCount = 0;

            // Shift and sum in one pass
            for (var i = 0; i < SMOOTHING_WINDOW - 1; i++) {
                var val = mSmoothingBuffer[i+1];
                mSmoothingBuffer[i] = val;
                if (val != POWER_NODATA) {
                    smoothSum += val;
                    smoothCount++;
                }
            }
            mSmoothingBuffer[SMOOTHING_WINDOW - 1] = powerValue;
            smoothSum += powerValue;
            smoothCount++;
            
            smoothedPower = smoothSum / smoothCount.toFloat();
            mAvg3sDisplay = smoothedPower.format("%.0f");
        }

        // 2. Update History Array (Decays if smoothedPower is POWER_NODATA)
        for (var i = 0; i < HISTORY_SIZE - 1; i++) {
            mPowerHistory[i] = mPowerHistory[i+1];
        }
        mPowerHistory[HISTORY_SIZE - 1] = smoothedPower;

        // 3. Single-Pass Statistics Calculation (3s, 10s, 20s Means + 10s StdDev)
        var s3 = 0.0f, c3 = 0;
        var s10 = 0.0f, sq10 = 0.0f, c10 = 0;
        var s20 = 0.0f, c20 = 0;

        for (var i = 1; i <= HISTORY_SIZE; i++) {
            var val = mPowerHistory[HISTORY_SIZE - i];
            if (val != null && val != POWER_NODATA && val == val && val > 1) {
                if (i <= 3) { s3 += val; c3++; }
                if (i <= 10) { 
                    s10 += val; 
                    sq10 += (val * val);
                    c10++; 
                }
                if (i <= 20) { s20 += val; c20++; }
            }
        }

        mAvg3s  = (c3 > 0)  ? (s3 / c3.toFloat())   : 0.0f;
        mAvg10s = (c10 > 0) ? (s10 / c10.toFloat()) : 0.0f;
        mAvg20s = (c20 > 0) ? (s20 / c20.toFloat()) : 0.0f;

        if (DEBUG) {
            System.println("Average powers 3s, 10s 20s " +  mAvg3s +  " "+  mAvg10s +  " "+  mAvg20s);
        }


        if (c10 > 1) {
            var variance = (sq10 / c10.toFloat()) - (mAvg10s * mAvg10s);
            mStdDev10s = Math.sqrt(variance < 0 ? 0 : variance).toFloat();
        } else {
            mStdDev10s = 0.0f;
        }

        // 4. Stability Metrics and FIT Recording
        if (mAvg10s >= mIgnorePower) {
            // Metric 1: Trend Stability (3s vs 10s) -> Used for Background Color
            var trendDiff = calculateDifference(mAvg3s, mAvg10s);
            updateBackgroundColor(trendDiff);
            
            // Metric 2: Delivery Stability (CV) -> Used for Graphical Bar
            if (mAvg20s >= mIgnorePower) {
                mCvValue = (mStdDev10s / mAvg10s) * 100.0f;
                if (timerRunning) {
                    mCvSum += mCvValue;
                    mCvCount++;
                }
            } else {
                mCvValue = INVALID_FLOAT;
            }
        } else {
            mCvValue = INVALID_FLOAT;
        }

        if (timerRunning) {
            if (mCvField != null && mCvValue == mCvValue) {
                mCvField.setData(mCvValue);
            }
            if (mCvSessionField != null && mCvCount > 0) {
                mCvSessionField.setData(mCvSum / mCvCount.toFloat());
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

        // 3. Draw the Power Stability (CV) bar on the right edge (Background layer)
        // Drawing this before the text ensures the main power value remains legible.
        if (mAvg10s > mIgnorePower && mCvValue == mCvValue) {
            var maxHeightValue = 50.0f;
            var fieldHeight = dc.getHeight();
            
            // Calculate height relative to 50
            var barHeight = (mCvValue / maxHeightValue) * fieldHeight;
            
            // Clamp the height to field boundaries
            if (barHeight > fieldHeight) { barHeight = fieldHeight.toFloat(); }
            if (barHeight < 0) { barHeight = 0.0f; }

            dc.setColor(Gfx.COLOR_PURPLE, Gfx.COLOR_TRANSPARENT);
            dc.fillRectangle(width - BAR_WIDTH, (fieldHeight - barHeight).toNumber(), BAR_WIDTH, barHeight.toNumber());

            // 5. Draw tick marks at CV 10, 20, and 30
            dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
            var ticks = [10, 20, 30];
            for (var i = 0; i < ticks.size(); i++) {
                var tickY = (fieldHeight - (ticks[i].toFloat() / maxHeightValue * fieldHeight)).toNumber();
                dc.drawLine(width - BAR_WIDTH, tickY, width, tickY);
            }

            // 6. Draw the CV text centered on the bar
            dc.setColor(fgColor, Gfx.COLOR_TRANSPARENT);
            dc.drawText(mCvX, mCvY, mCvFont, mCvValue.format("%.0f") + "%", Gfx.TEXT_JUSTIFY_CENTER);
        }

        // 4. Draw labels and main power value (Foreground layer)
        dc.setColor(labelColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(width / 2, mLabelY, mLabelFont, LABEL_TEXT, Gfx.TEXT_JUSTIFY_CENTER);

        dc.setColor(fgColor, Gfx.COLOR_TRANSPARENT);
        dc.drawText(width / 2, mValueY, mValueFont, mAvg3sDisplay, Gfx.TEXT_JUSTIFY_CENTER);
    }
}