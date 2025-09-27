package com.mobisys.cordova.plugins.mlkit.barcode.scanner;

import android.Manifest;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.util.Log;

import androidx.core.content.ContextCompat;

import com.google.android.gms.common.ConnectionResult;
import com.google.android.gms.common.GoogleApiAvailability;
import com.google.android.gms.common.api.ApiException;
import com.google.android.gms.tasks.Task;
import com.google.mlkit.vision.barcode.common.Barcode;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanner;
import com.google.mlkit.vision.codescanner.GmsBarcodeScannerOptions;
import com.google.mlkit.vision.codescanner.GmsBarcodeScanning;
import com.google.zxing.integration.android.IntentIntegrator;
import com.google.zxing.integration.android.IntentResult;

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
    public boolean execute(String action, org.json.JSONArray args, CallbackContext cb) throws JSONException {
        if (!"startScan".equals(action)) return false;
        this.callback = cb;

        cordova.getActivity().runOnUiThread(() -> {
            if (ContextCompat.checkSelfPermission(cordova.getActivity(), Manifest.permission.CAMERA)
                    != PackageManager.PERMISSION_GRANTED) {
                cordova.requestPermission(this, REQ_CAMERA, Manifest.permission.CAMERA);
                return;
            }
            startWithBestAvailableScanner();
        });
        return true;
    }

    @Override
    public void onRequestPermissionResult(int requestCode, String[] permissions, int[] grantResults) throws JSONException {
        if (requestCode == REQ_CAMERA) {
            if (grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                cordova.getActivity().runOnUiThread(this::startWithBestAvailableScanner);
            } else {
                sendErr("CAMERA_PERMISSION_DENIED", null);
            }
        }
    }

    private void startWithBestAvailableScanner() {
        // Prefer GMS Code Scanner (no native .so in your APK; 16K friendly via GMS)
        if (isPlayServicesOk()) {
            startGmsScan();
        } else {
            // Fallback: ZXing (pure Java; 16K page size safe; no GMS required)
            startZxingFallback();
        }
    }

    private boolean isPlayServicesOk() {
        int status = GoogleApiAvailability.getInstance()
                .isGooglePlayServicesAvailable(cordova.getActivity());
        return status == ConnectionResult.SUCCESS;
    }

    // --------- Primary: GMS Code Scanner ----------
    private void startGmsScan() {
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
                    result.put(barcode.getFormat());     // int
                    result.put(barcode.getValueType());  // int
                    PluginResult ok = new PluginResult(PluginResult.Status.OK, result);
                    ok.setKeepCallback(false);
                    callback.sendPluginResult(ok);
                } catch (Exception e) {
                    sendErr("PARSE_SUCCESS", e);
                }
            }).addOnFailureListener(e -> {
                // If GMS UI closes immediately (old/outdated GMS), fall back gracefully
                if (e instanceof ApiException) {
                    // Try fallback instead of bailing out
                    startZxingFallback();
                } else {
                    startZxingFallback();
                }
            }).addOnCanceledListener(() -> sendErr("USER_CANCELED", null));
        } catch (Exception e) {
            // Any unexpected issue → fallback
            startZxingFallback();
        }
    }

    // --------- Fallback: ZXing Embedded ----------
    private void startZxingFallback() {
        try {
            IntentIntegrator integrator = new IntentIntegrator(cordova.getActivity());
            integrator.setDesiredBarcodeFormats(IntentIntegrator.ALL_CODE_TYPES);
            integrator.setPrompt("Point camera at a barcode");
            integrator.setBeepEnabled(false);
            integrator.setBarcodeImageEnabled(false);
            integrator.setOrientationLocked(false);
            this.cordova.setActivityResultCallback(this);
            integrator.initiateScan();
        } catch (Exception e) {
            sendErr("ZXING_START_FAILED", e);
        }
    }

    @Override
    public void onActivityResult(int requestCode, int resultCode, Intent intent) {
        IntentResult res = IntentIntegrator.parseActivityResult(requestCode, resultCode, intent);
        if (res != null) {
            if (res.getContents() != null) {
                try {
                    JSONArray result = new JSONArray();
                    result.put(res.getContents()); // rawValue
                    result.put(0);                 // format (unknown here) -> keep int shape
                    result.put(0);                 // valueType (not provided) -> keep int shape
                    PluginResult ok = new PluginResult(PluginResult.Status.OK, result);
                    ok.setKeepCallback(false);
                    if (callback != null) callback.sendPluginResult(ok);
                } catch (Exception e) {
                    sendErr("ZXING_PARSE_SUCCESS", e);
                }
            } else {
                sendErr("USER_CANCELED", null);
            }
        }
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
            if (callback != null) callback.sendPluginResult(fail);
        } catch (Exception ex) {
            Log.e(TAG, "sendErr failed", ex);
        }
    }
}
