package ca.openphotos.android.e2ee;

import android.content.Context;

import androidx.security.crypto.EncryptedFile;
import androidx.security.crypto.MasterKey;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;

/** Encrypted cache for decrypted media. */
public final class DecryptedCache {
    private final Context app;
    public DecryptedCache(Context app) { this.app = app.getApplicationContext(); }

    public File writeEncrypted(String key, File plaintext) throws Exception {
        MasterKey mk = new MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build();
        File out = new File(app.getFilesDir(), "dec_" + key);
        EncryptedFile ef = new EncryptedFile.Builder(app, out, mk, EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB).build();
        try (InputStream is = new FileInputStream(plaintext); java.io.OutputStream os = ef.openFileOutput()) {
            byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) os.write(buf, 0, r);
        }
        return out;
    }

    public File readDecrypted(String key) throws Exception {
        // For displaying via libraries that accept File, we have to decrypt to a temp file
        MasterKey mk = new MasterKey.Builder(app).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build();
        File enc = new File(app.getFilesDir(), "dec_" + key);
        if (!enc.exists()) return null;
        EncryptedFile ef = new EncryptedFile.Builder(app, enc, mk, EncryptedFile.FileEncryptionScheme.AES256_GCM_HKDF_4KB).build();
        File tmp = File.createTempFile("dec_plain_", ".bin", app.getCacheDir());
        try (InputStream is = ef.openFileInput(); FileOutputStream fos = new FileOutputStream(tmp)) {
            byte[] buf = new byte[8192]; int r; while ((r = is.read(buf)) > 0) fos.write(buf, 0, r);
        }
        return tmp;
    }

    public void wipeAll() {
        File dir = app.getFilesDir();
        File[] files = dir.listFiles((d, name) -> name.startsWith("dec_"));
        if (files != null) for (File f : files) f.delete();
    }
}

