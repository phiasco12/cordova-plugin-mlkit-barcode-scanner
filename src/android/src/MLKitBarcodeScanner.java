package com.mobisys.cordova.plugins.mlkit.barcode.scanner;

import android.app.Activity;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import com.google.mlkit.vision.codescanner.GmsBarcodeScanner;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;
import com.google.mlkit.vision.barcode.common.Barcode;

/**
 * Cordova plugin entry that starts a Google Code Scanner (GMS) scan.
 * Keeps the original API:
 *   action: "startScan"
 *   success payload: [text, formatInt, valueTypeInt]
 *   error payload:   [message, "", ""]
 */
public class MLKitBarcodeScanner extends CordovaPlugin {

    private static final String ACTION_START_SCAN = "startScan";

    private CallbackContext callback;
    private volatile boolean isScanning = false;

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);
    }

    @Override
    public boolean execute(String action, final JSONArray args, final CallbackContext cb) throws JSONException {
        if (!ACTION_START_SCAN.equals(action)) return false;

        final Activity activity = cordova.getActivity();
        this.callback = cb;

        if (isScanning) {
            sendError("SCAN_IN_PROGRESS");
            return true;
        }
        isScanning = true;

        cordova.getActivity().runOnUiThread(() -> {
            try {
                // Build options (auto-zoom on). If you want to restrict formats, map your arg[0] here.
                GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
                        .enableAutoZoom()
                        .build();

                GmsBarcodeScanner scanner = GmsBarcodeScanning.getClient(activity, options);

                scanner.startScan()
                        .addOnSuccessListener(barcode -> {
                            // Success: return [text, format, valueType]
                            JSONArray result = new JSONArray();
                            result.put(barcode.getRawValue() != null ? barcode.getRawValue() : "");
                            result.put(barcode.getFormat());     // int
                            result.put(barcode.getValueType());  // int

                            sendOk(result);
                        })
                        .addOnCanceledListener(() -> {
                            // User canceled the scan
                            sendError("CANCELLED");
                        })
                        .addOnFailureListener(e -> {
                            // Other failure
                            String msg = (e != null && e.getMessage() != null) ? e.getMessage() : "SCAN_FAILED";
                            sendError(msg);
                        });

            } catch (Exception e) {
                String msg = (e.getMessage() != null) ? e.getMessage() : "INIT_FAILED";
                sendError(msg);
            }
        });

        return true;
    }

    @Override
    public void onRestoreStateForActivityResult(android.os.Bundle state, CallbackContext callbackContext) {
        this.callback = callbackContext;
    }

    // ---- helpers ----

    private void sendOk(JSONArray payload) {
        isScanning = false;
        if (callback == null) return;
        PluginResult pr = new PluginResult(PluginResult.Status.OK, payload);
        pr.setKeepCallback(false);
        callback.sendPluginResult(pr);
        callback = null;
    }

    private void sendError(String message) {
        isScanning = false;
        if (callback == null) return;
        JSONArray err = new JSONArray();
        err.put(message != null ? message : "ERROR");
        err.put("");
        err.put("");
        PluginResult pr = new PluginResult(PluginResult.Status.ERROR, err);
        pr.setKeepCallback(false);
        callback.sendPluginResult(pr);
        callback = null;
    }
}
