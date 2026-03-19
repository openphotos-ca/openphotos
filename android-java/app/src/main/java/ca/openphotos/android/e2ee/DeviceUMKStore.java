package ca.openphotos.android.e2ee;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;

import java.security.KeyStore;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Stores UMK encrypted under an Android Keystore key which requires user authentication
 * (biometrics/device credentials). Decryption requires presenting a BiometricPrompt with
 * the Cipher returned by createDecryptCipher().
 */
public final class DeviceUMKStore {
    private static final String KS_ALIAS = "umk_device_key";
    private static final String ANDROID_KEYSTORE = "AndroidKeyStore";
    private static final String PREF = "umk.store";
    private static final String K_CT = "ct";
    private static final String K_IV = "iv";

    private final Context app;
    private final SharedPreferences sp;

    public DeviceUMKStore(Context app) { this.app = app.getApplicationContext(); this.sp = this.app.getSharedPreferences(PREF, Context.MODE_PRIVATE); }

    public void ensureKey() throws Exception {
        KeyStore ks = KeyStore.getInstance(ANDROID_KEYSTORE);
        ks.load(null);
        if (ks.containsAlias(KS_ALIAS)) return;
        KeyGenerator kg = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE);
        KeyGenParameterSpec spec = new KeyGenParameterSpec.Builder(KS_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(true)
                .setUserAuthenticationValidityDurationSeconds(-1) // require every time
                .build();
        kg.init(spec);
        kg.generateKey();
    }

    public Cipher createEncryptCipher() throws Exception {
        ensureKey();
        KeyStore ks = KeyStore.getInstance(ANDROID_KEYSTORE);
        ks.load(null);
        SecretKey k = (SecretKey) ks.getKey(KS_ALIAS, null);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, k);
        return c;
    }

    public Cipher createDecryptCipher() throws Exception {
        ensureKey();
        byte[] iv = readB64(K_IV);
        if (iv == null) throw new IllegalStateException("No UMK stored");
        KeyStore ks = KeyStore.getInstance(ANDROID_KEYSTORE);
        ks.load(null);
        SecretKey k = (SecretKey) ks.getKey(KS_ALIAS, null);
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, k, new GCMParameterSpec(128, iv));
        return c;
    }

    public void saveUMK(byte[] umk, Cipher encryptCipher) throws Exception {
        byte[] ct = encryptCipher.doFinal(umk);
        byte[] iv = encryptCipher.getIV();
        sp.edit().putString(K_CT, android.util.Base64.encodeToString(ct, android.util.Base64.NO_WRAP))
                .putString(K_IV, android.util.Base64.encodeToString(iv, android.util.Base64.NO_WRAP))
                .apply();
    }

    public byte[] decryptUMK(Cipher decryptCipher) throws Exception {
        byte[] ct = readB64(K_CT);
        if (ct == null) return null;
        return decryptCipher.doFinal(ct);
    }

    public void clear() { sp.edit().clear().apply(); }

    private byte[] readB64(String key) {
        String s = sp.getString(key, null);
        if (s == null) return null;
        return android.util.Base64.decode(s, android.util.Base64.NO_WRAP);
    }
}

