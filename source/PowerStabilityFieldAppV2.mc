import Toybox.Application;
import Toybox.Lang;
import Toybox.WatchUi;

class PowerStabilityFieldAppV2 extends Application.AppBase {

    var settingsChanged as Boolean = false;

    function initialize() {
        AppBase.initialize();
    }

    // onStart() is called on application start up
    function onStart(state as Dictionary?) as Void {
    }

    // onStop() is called when your application is exiting
    function onStop(state as Dictionary?) as Void {
    }

    // Return the initial view of your application here
    function getInitialView() as [Views] or [Views, InputDelegates] {
        return [ new $.PowerStabilityFieldViewV2() ] as [Views];
    }

    function onSettingsChanged() as Void {
        settingsChanged = true;
        WatchUi.requestUpdate();
    }
}

function getApp() as PowerStabilityFieldAppV2 {
    return Application.getApp() as PowerStabilityFieldAppV2;
}