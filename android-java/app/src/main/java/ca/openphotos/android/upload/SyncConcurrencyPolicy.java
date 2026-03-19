package ca.openphotos.android.upload;

import android.app.ActivityManager;
import android.content.Context;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.os.PowerManager;

/**
 * Computes safe sync/upload concurrency without exposing UI settings.
 */
public final class SyncConcurrencyPolicy {
    private static final int MIB = 1024 * 1024;
    private static final int CHUNK_1 = 9 * MIB;
    private static final int CHUNK_2 = 6 * MIB;
    private static final int CHUNK_3 = 4 * MIB;

    private SyncConcurrencyPolicy() {}

    public static Snapshot resolve(Context context) {
        Context app = context.getApplicationContext();

        boolean wifiOrEthernet = false;
        boolean cellular = false;
        boolean metered = true;
        try {
            ConnectivityManager cm = (ConnectivityManager) app.getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm != null) {
                Network active = cm.getActiveNetwork();
                NetworkCapabilities nc = active != null ? cm.getNetworkCapabilities(active) : null;
                if (nc != null) {
                    boolean wifi = nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI);
                    boolean eth = nc.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET);
                    cellular = nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR);
                    wifiOrEthernet = wifi || eth;
                    metered = !nc.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                            && !wifiOrEthernet;
                }
            }
        } catch (Exception ignored) {
        }

        boolean powerSave = false;
        try {
            PowerManager pm = (PowerManager) app.getSystemService(Context.POWER_SERVICE);
            powerSave = pm != null && pm.isPowerSaveMode();
        } catch (Exception ignored) {
        }

        boolean lowRam = false;
        int memoryClass = 128;
        try {
            ActivityManager am = (ActivityManager) app.getSystemService(Context.ACTIVITY_SERVICE);
            if (am != null) {
                lowRam = am.isLowRamDevice();
                memoryClass = am.getMemoryClass();
            }
        } catch (Exception ignored) {
        }

        int cpus = Math.max(1, Runtime.getRuntime().availableProcessors());

        int uploadParallelism;
        if (cellular || metered || lowRam || powerSave) {
            uploadParallelism = 1;
        } else if (wifiOrEthernet && memoryClass >= 256 && cpus >= 8) {
            uploadParallelism = 3;
        } else {
            uploadParallelism = 2;
        }
        uploadParallelism = clamp(uploadParallelism, 1, 3);

        int preprocessParallelism = (lowRam || powerSave || cpus <= 2) ? 1 : 2;
        preprocessParallelism = clamp(preprocessParallelism, 1, 2);

        int lockedParallelism = (uploadParallelism >= 2 && !lowRam && !powerSave && cpus >= 6) ? 2 : 1;
        lockedParallelism = clamp(lockedParallelism, 1, Math.min(2, uploadParallelism));

        int chunkSize;
        if (uploadParallelism <= 1) chunkSize = CHUNK_1;
        else if (uploadParallelism == 2) chunkSize = CHUNK_2;
        else chunkSize = CHUNK_3;

        String networkClass;
        if (wifiOrEthernet) networkClass = "wifi_or_ethernet";
        else if (cellular || metered) networkClass = "cellular_or_metered";
        else networkClass = "unknown";

        return new Snapshot(
                uploadParallelism,
                preprocessParallelism,
                lockedParallelism,
                chunkSize,
                networkClass,
                cpus,
                memoryClass,
                lowRam,
                powerSave
        );
    }

    private static int clamp(int v, int min, int max) {
        return Math.max(min, Math.min(max, v));
    }

    public static final class Snapshot {
        public final int uploadParallelism;
        public final int preprocessParallelism;
        public final int lockedParallelism;
        public final int tusChunkSizeBytes;
        public final String networkClass;
        public final int availableProcessors;
        public final int memoryClassMb;
        public final boolean lowRamDevice;
        public final boolean powerSaveMode;

        private Snapshot(
                int uploadParallelism,
                int preprocessParallelism,
                int lockedParallelism,
                int tusChunkSizeBytes,
                String networkClass,
                int availableProcessors,
                int memoryClassMb,
                boolean lowRamDevice,
                boolean powerSaveMode
        ) {
            this.uploadParallelism = uploadParallelism;
            this.preprocessParallelism = preprocessParallelism;
            this.lockedParallelism = lockedParallelism;
            this.tusChunkSizeBytes = tusChunkSizeBytes;
            this.networkClass = networkClass;
            this.availableProcessors = availableProcessors;
            this.memoryClassMb = memoryClassMb;
            this.lowRamDevice = lowRamDevice;
            this.powerSaveMode = powerSaveMode;
        }

        public String summary() {
            return "network=" + networkClass
                    + ",cpu=" + availableProcessors
                    + ",memoryClassMb=" + memoryClassMb
                    + ",lowRam=" + lowRamDevice
                    + ",powerSave=" + powerSaveMode
                    + ",uploadParallelism=" + uploadParallelism
                    + ",preprocessParallelism=" + preprocessParallelism
                    + ",lockedParallelism=" + lockedParallelism
                    + ",chunkBytes=" + tusChunkSizeBytes;
        }
    }
}
