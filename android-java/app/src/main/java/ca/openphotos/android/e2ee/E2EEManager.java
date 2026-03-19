package ca.openphotos.android.e2ee;

import android.content.Context;
import android.util.Base64;

import androidx.annotation.Nullable;
import androidx.biometric.BiometricPrompt;

import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.concurrent.TimeUnit;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;

/**
 * E2EEManager handles UMK lifecycle, envelope storage, and quick unlock.
 * - Argon2id via libsodium (LazySodium) will be wired in a later step.
 * - HKDF and AES-GCM are implemented in PAE3 and helpers.
 */
public class E2EEManager {
    private static final String ENVELOPE_FILE = "e2ee_envelope.json";
    private static final String LAST_HASH_PREF = "e2ee.last_hash";

    private final Context app;
    private byte[] umk;
    private long unlockedAtMs;
    private long ttlMs = TimeUnit.HOURS.toMillis(1);
    // Global session UMK so new instances can see the unlocked state
    private static volatile byte[] GLOBAL_UMK;
    private static volatile long GLOBAL_UNLOCKED_AT_MS;

    public E2EEManager(Context app) { this.app = app.getApplicationContext(); }

    public void setTtlHours(int hours) { this.ttlMs = TimeUnit.HOURS.toMillis(hours); }
    public boolean hasValidUMK() {
        long now = System.currentTimeMillis();
        if (umk != null && (now - unlockedAtMs) < ttlMs) return true;
        if (GLOBAL_UMK != null && (now - GLOBAL_UNLOCKED_AT_MS) < ttlMs) return true;
        return false;
    }
    public @Nullable byte[] getUmk() {
        long now = System.currentTimeMillis();
        if (umk != null && (now - unlockedAtMs) < ttlMs) return umk;
        if (GLOBAL_UMK != null && (now - GLOBAL_UNLOCKED_AT_MS) < ttlMs) return GLOBAL_UMK;
        return null;
    }
    public void clearUmk() { umk = null; unlockedAtMs = 0; }

    public void setUmk(byte[] key) { umk = key; unlockedAtMs = System.currentTimeMillis(); GLOBAL_UMK = key; GLOBAL_UNLOCKED_AT_MS = unlockedAtMs; }

    /** Install a newly generated UMK for first-time PIN setup. */
    public void installNewUmk(byte[] key) { setUmk(key); }

    // --- Unlock using server-stored envelope and user PIN ---
    /**
     * Fetches the crypto envelope from the server and unwraps the UMK using the provided 8-char PIN.
     * Returns true on success and stores the UMK in memory for this session.
     */
    public boolean unlockWithPin(String pin) {
        try {
            JSONObject env = fetchEnvelopeFromServer();
            if (env != null) {
                try { saveEnvelopeLocal(env); } catch (Exception ignored) {}
            }
            if (env == null) env = loadEnvelopeLocal();
            if (env == null) { try { android.util.Log.w("OpenPhotos","[E2EE] No envelope available"); } catch (Exception ignored) {} return false; }
            // Envelope fields tolerate either *_b64url or plain keys for robustness
            byte[] salt = b64urld(env.optString("salt_b64url", env.optString("salt", "")));
            int m = env.optInt("m", 128); // MiB
            int t = env.optInt("t", 3);
            int p = env.optInt("p", 1);
            String info = env.optString("info", "umk-wrap:v1");
            byte[] iv = b64urld(env.optString("wrap_iv_b64url", env.optString("wrap_iv", "")));
            byte[] ct = b64urld(env.optString("umk_wrapped_b64url", env.optString("umk_wrapped", "")));
            try { android.util.Log.i("OpenPhotos", "[E2EE] Envelope m="+m+" t="+t+" p="+p+" salt="+salt.length+" iv="+iv.length+" ct="+ct.length); } catch (Exception ignored) {}
            if (salt.length==0 || iv.length==0 || ct.length==0) { try { android.util.Log.w("OpenPhotos","[E2EE] Envelope missing fields"); } catch (Exception ignored) {} return false; }
            // Derive password-wrapping key
            byte[] pwk = derivePWKArgon2id(pin.getBytes(java.nio.charset.StandardCharsets.UTF_8), salt, m, t, p);
            // Decrypt UMK (AAD = "umk:v1")
            javax.crypto.Cipher c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
            c.init(javax.crypto.Cipher.DECRYPT_MODE, new javax.crypto.spec.SecretKeySpec(pwk, "AES"), new javax.crypto.spec.GCMParameterSpec(128, iv));
            c.updateAAD("umk:v1".getBytes());
            byte[] umkPlain = c.doFinal(ct);
            setUmk(umkPlain);
            try { android.util.Log.i("OpenPhotos", "[E2EE] UMK unlocked len="+umkPlain.length); } catch (Exception ignored) {}
            return true;
        } catch (Exception e) { try { android.util.Log.e("OpenPhotos","[E2EE] unlockWithPin failed: "+e.getMessage(), e); } catch (Exception ignored) {} return false; }
    }

    private static byte[] b64urld(String s) {
        if (s == null || s.isEmpty()) return new byte[0];
        String t = s.replace('-', '+').replace('_', '/');
        int pad = (4 - (t.length() % 4)) % 4; if (pad > 0) t += "=".repeat(pad);
        return android.util.Base64.decode(t, android.util.Base64.DEFAULT);
    }

    private static String b64urle(byte[] v) {
        return Base64.encodeToString(v, Base64.NO_WRAP)
                .replace("+", "-")
                .replace("/", "_")
                .replace("=", "");
    }

    /** Wrap UMK with PIN-derived key and persist envelope locally in server-compatible shape. */
    public JSONObject wrapUMKForPassword(
            byte[] umk,
            String pin,
            @Nullable String accountId,
            @Nullable String userId,
            int mMiB,
            int t,
            int p
    ) throws Exception {
        byte[] salt = new byte[16];
        new SecureRandom().nextBytes(salt);
        byte[] pwk = derivePWKArgon2id(pin.getBytes(StandardCharsets.UTF_8), salt, mMiB, t, p);

        byte[] iv = new byte[12];
        new SecureRandom().nextBytes(iv);

        javax.crypto.Cipher c = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding");
        c.init(javax.crypto.Cipher.ENCRYPT_MODE, new javax.crypto.spec.SecretKeySpec(pwk, "AES"), new javax.crypto.spec.GCMParameterSpec(128, iv));
        c.updateAAD("umk:v1".getBytes(StandardCharsets.UTF_8));
        byte[] wrapped = c.doFinal(umk);

        JSONObject env = new JSONObject();
        env.put("kdf", "argon2id");
        env.put("salt_b64url", b64urle(salt));
        env.put("m", mMiB);
        env.put("t", t);
        env.put("p", p);
        env.put("info", "umk-wrap:v1");
        env.put("wrap_iv_b64url", b64urle(iv));
        env.put("umk_wrapped_b64url", b64urle(wrapped));
        env.put("version", 1);
        if (accountId != null && !accountId.isEmpty()) env.put("accountId", accountId);
        if (userId != null && !userId.isEmpty()) env.put("userId", userId);

        saveEnvelopeLocal(env);
        try {
            setLastEnvelopeHash(sha256Hex(env.toString().getBytes(StandardCharsets.UTF_8)));
        } catch (Exception ignored) {
        }
        return env;
    }

    // --- Envelope (local) ---
    public void saveEnvelopeLocal(JSONObject env) throws Exception {
        File dir = new File(app.getFilesDir(), "e2ee");
        if (!dir.exists()) dir.mkdirs();
        File f = new File(dir, ENVELOPE_FILE);
        try (FileOutputStream fos = new FileOutputStream(f)) {
            fos.write(env.toString().getBytes(StandardCharsets.UTF_8));
        }
    }

    public @Nullable JSONObject loadEnvelopeLocal() {
        try {
            File f = new File(new File(app.getFilesDir(), "e2ee"), ENVELOPE_FILE);
            if (!f.exists()) return null;
            String s = new String(java.nio.file.Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
            return new JSONObject(s);
        } catch (Exception e) { return null; }
    }

    public void setLastEnvelopeHash(String hex) {
        android.content.SharedPreferences sp = app.getSharedPreferences("e2ee.prefs", Context.MODE_PRIVATE);
        sp.edit().putString(LAST_HASH_PREF, hex).apply();
    }
    public @Nullable String getLastEnvelopeHash() {
        return app.getSharedPreferences("e2ee.prefs", Context.MODE_PRIVATE).getString(LAST_HASH_PREF, null);
    }
    public static String sha256Hex(byte[] data) throws Exception {
        MessageDigest d = MessageDigest.getInstance("SHA-256");
        byte[] h = d.digest(data);
        StringBuilder sb = new StringBuilder();
        for (byte b : h) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    // --- Derivations ---
    public static byte[] hkdfSha256(byte[] ikm, byte[] info, int outLen) throws Exception {
        // RFC5869: extract
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(new byte[32], "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);
        // expand
        byte[] okm = new byte[outLen];
        byte[] t = new byte[0];
        int pos = 0;
        for (int i = 1; pos < outLen; i++) {
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            mac.update(t);
            mac.update(info);
            mac.update((byte) i);
            t = mac.doFinal();
            int copy = Math.min(t.length, outLen - pos);
            System.arraycopy(t, 0, okm, pos, copy);
            pos += copy;
        }
        return okm;
    }

    /** Placeholder Argon2id derivation. Wire with LazySodium in a later step. */
    public static byte[] derivePWKArgon2id(byte[] password, byte[] salt, int mMiB, int t, int p) throws Exception {
        // Use BouncyCastle Argon2id to derive 32-byte key, then HKDF to PWK with info "umk-wrap:v1".
        org.bouncycastle.crypto.params.Argon2Parameters params = new org.bouncycastle.crypto.params.Argon2Parameters.Builder(org.bouncycastle.crypto.params.Argon2Parameters.ARGON2_id)
                .withSalt(salt)
                .withMemoryAsKB(mMiB * 1024)
                .withIterations(t)
                .withParallelism(p)
                .build();
        org.bouncycastle.crypto.generators.Argon2BytesGenerator gen = new org.bouncycastle.crypto.generators.Argon2BytesGenerator();
        gen.init(params);
        byte[] out = new byte[32];
        gen.generateBytes(password, out, 0, out.length);
        return hkdfSha256(out, "umk-wrap:v1".getBytes(), 32);
    }

    // --- Server sync helpers ---
    public @Nullable JSONObject fetchEnvelopeFromServer() {
        try {
            return CryptoAPI.fetchEnvelope(app);
        } catch (Exception e) {
            try {
                android.util.Log.e("OpenPhotos", "[E2EE] fetchEnvelopeFromServer failed: " + e.getClass().getSimpleName() + ": " + e.getMessage(), e);
            } catch (Exception ignored) {}
            return null;
        }
    }
    public boolean saveEnvelopeToServer(JSONObject env) {
        try { return CryptoAPI.saveEnvelope(app, env); } catch (Exception e) { return false; }
    }
}
