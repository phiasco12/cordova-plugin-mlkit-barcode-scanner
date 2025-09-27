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
    private static final int REQ_CAMERA = 1001;

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
            if (ContextCompat.checkSelfPermission(cordova.getContext(), Manifest.permission.CAMERA)
                    != PackageManager.PERMISSION_GRANTED) {
                // Request permission instead of failing
                cordova.requestPermission(this, REQ_CAMERA, Manifest.permission.CAMERA);
                return;
            }
            startScanInternal();
        });

        return true;
    }

    @Override
    public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) throws JSONException {
        if (requestCode == REQ_CAMERA) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                cordova.getActivity().runOnUiThread(this::startScanInternal);
            } else {
                sendErr("CAMERA_PERMISSION_DENIED", null);
            }
        }
    }

    private void startScanInternal() {
        try {
            GmsBarcodeScannerOptions options = new GmsBarcodeScannerOptions.Builder()
                    .setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
                    .enableAutoZoom()
                    .build();

            GmsBarcodeScanner scanner = GmsBarcodeScanning.getClient(cordova.getActivity(), options);

            Task<Barcode> task = scanner.startScan();
            task.addOnSuccessListener(barcode -> {
                try {
                    JSONArray result = new JSONArray();
                    result.put(barcode.getRawValue() == null ? "" : barcode.getRawValue());
                    result.put(barcode.getFormat());
                    result.put(barcode.getValueType());
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
            }).addOnCanceledListener(() -> sendErr("USER_CANCELED", null));
        } catch (Exception e) {
            sendErr("START_SCAN_ERROR", e);
        }
    }

    private void sendErr(String code, Exception e) {
        try {
            if (e != null) Log.w(TAG, code, e);
            JSONArray err = new JSONArray();
            err.put(code);
            err.put("");
            err.put("");
            PluginResult fail = new PluginResult(PluginResult.Status.ERROR, err);
            fail.setKeepCallback(false);
            if (callback != null) callback.sendPluginResult(fail);
        } catch (Exception ex) {
            Log.e(TAG, "sendErr failed", ex);
        }
    }
}
