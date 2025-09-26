package com.mobisys.cordova.plugins.mlkit.barcode.scanner;

import android.Manifest;
import android.content.Intent;
import android.os.Bundle;
import android.util.Log;

import com.google.android.gms.common.api.CommonStatusCodes;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;

public class MLKitBarcodeScanner extends CordovaPlugin {

    private static final String TAG = "MLKitBarcodeScanner";
    private static final int RC_BARCODE_CAPTURE = 9001;
    private static final int REQ_CAMERA = 9002;

    private CallbackContext callbackCtx;
    private JSONArray pendingArgs;
    private boolean scannerOpen = false;

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext callbackContext) throws JSONException {
        if (!"startScan".equals(action)) return false;

        this.callbackCtx = callbackContext;
        this.pendingArgs = (args != null) ? args : new JSONArray();

        if (scannerOpen) { // prevent double-launch
            sendError("SCANNER_OPEN");
            return true;
        }

        // Request CAMERA at runtime if needed
        if (!cordova.hasPermission(Manifest.permission.CAMERA)) {
            cordova.requestPermission(this, REQ_CAMERA, Manifest.permission.CAMERA);
            return true;
        }

        startScannerOnUi();
        return true;
    }

    private void startScannerOnUi() {
        cordova.getActivity().runOnUiThread(() -> {
            try {
                Intent intent = new Intent(cordova.getActivity(), CaptureActivity.class);
                int detectionTypes = pendingArgs.optInt(0, 1234);
                double detectorSize = pendingArgs.optDouble(1, 0.5);

                intent.putExtra("DetectionTypes", detectionTypes);
                intent.putExtra("DetectorSize", detectorSize);

                scannerOpen = true;
                cordova.setActivityResultCallback(this);
                cordova.startActivityForResult(this, intent, RC_BARCODE_CAPTURE);
            } catch (Exception e) {
                Log.e(TAG, "Failed to start scanner", e);
                scannerOpen = false;
                sendError("SCAN_FAILED");
            }
        });
    }

    @Override
    public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) throws JSONException {
        super.onRequestPermissionResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_CAMERA) {
            if (cordova.hasPermission(Manifest.permission.CAMERA)) {
                startScannerOnUi();
            } else {
                sendError("CAMERA_PERMISSION_REQUIRED");
            }
        }
    }

    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent data) {
        try {
            if (requestCode != RC_BARCODE_CAPTURE) return;

            if (resultCode == CommonStatusCodes.SUCCESS && data != null) {
                Integer barcodeFormat = data.getIntExtra(CaptureActivity.BarcodeFormat, 0);
                Integer barcodeType   = data.getIntExtra(CaptureActivity.BarcodeType, 0);
                String barcodeValue   = data.getStringExtra(CaptureActivity.BarcodeValue);

                JSONArray result = new JSONArray();
                result.put(barcodeValue);
                result.put(barcodeFormat);
                result.put(barcodeType);

                callbackCtx.sendPluginResult(new PluginResult(PluginResult.Status.OK, result));
                Log.d(TAG, "Barcode read: " + barcodeValue);
            } else {
                String err = (data != null) ? data.getStringExtra("err") : "USER_CANCELLED";
                sendError(err);
            }
        } finally {
            scannerOpen = false;
        }
    }

    @Override
    public void onRestoreStateForActivityResult(Bundle state, CallbackContext callbackContext) {
        this.callbackCtx = callbackContext;
    }

    @Override
    public void onReset() {
        scannerOpen = false;
        super.onReset();
    }

    private void sendError(String code) {
        try {
            JSONArray err = new JSONArray();
            err.put(code);
            err.put("");
            err.put("");
            callbackCtx.sendPluginResult(new PluginResult(PluginResult.Status.ERROR, err));
        } catch (Exception ignored) { }
    }
}
