package com.mobisys.cordova.plugins.mlkit.barcode.scanner;

import android.Manifest;
import android.content.pm.PackageManager;
import android.util.Log;

import androidx.core.content.ContextCompat;

import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;

import org.apache.cordova.CallbackContext;
import org.apache.cordova.CordovaInterface;
import org.apache.cordova.CordovaPlugin;
import org.apache.cordova.CordovaWebView;
import org.apache.cordova.PluginResult;
import org.json.JSONArray;
import org.json.JSONException;

public class MLKitBarcodeScanner extends CordovaPlugin {

    private static final String TAG = "MLKitBarcodeScanner";
    private CallbackContext callback;

    @Override
    public void initialize(CordovaInterface cordova, CordovaWebView webView) {
        super.initialize(cordova, webView);
    }

    @Override
    public boolean execute(String action, JSONArray args, CallbackContext cb) throws JSONException {
        if (!"startScan".equals(action)) return false;

        this.callback = cb;

        cordova.getActivity().runOnUiThread(() -> {
            // 1. Check CAMERA permission
            if (ContextCompat.checkSelfPermission(
                    cordova.getContext(), Manifest.permission.CAMERA)
                    != PackageManager.PERMISSION_GRANTED) {
                sendErr("CAMERA_PERMISSION_REQUIRED", null);
                return;
            }

            // 2. Build scanner options
            GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
                    .enableAutoZoom()
                    .build();

            GmsBarcodeScanner scanner =
                    GmsBarcodeScanning.getClient(cordova.getActivity(), options);

            // 3. Start scan
            Task<Barcode> task = scanner.startScan();
            task.addOnSuccessListener(barcode -> {
                try {
                    JSONArray result = new JSONArray();
                    result.put(barcode.getRawValue() == null ? "" : barcode.getRawValue());
                    result.put(barcode.getFormat());     // int
                    result.put(barcode.getValueType());  // int
                    PluginResult ok = new PluginResult(PluginResult.Status.OK, result);
                    ok.setKeepCallback(false);
                    callback.sendPluginResult(ok);
                } catch (Exception e) {
                    sendErr("PARSE_SUCCESS", e);
                }
            }).addOnFailureListener(e -> {
                if (e instanceof ApiException) {
                    ApiException api = (ApiException) e;
                    sendErr("API_EXCEPTION_" + api.getStatusCode(), api);
                } else {
                    sendErr("SCAN_FAILED", e);
                }
            }).addOnCanceledListener(() -> sendErr("USER_CANCELLED", null));
        });

        return true;
    }

    private void sendErr(String code, Exception e) {
        try {
            if (e != null) Log.w(TAG, code, e);
            JSONArray err = new JSONArray();
            err.put(code);
            err.put(""); // format
            err.put(""); // type
            PluginResult fail = new PluginResult(PluginResult.Status.ERROR, err);
            fail.setKeepCallback(false);
            callback.sendPluginResult(fail);
        } catch (Exception ex) {
            Log.e(TAG, "sendErr failed", ex);
        }
    }
}
