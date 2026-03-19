package ca.openphotos.android.util;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.io.File;
import java.io.FileInputStream;
import java.security.MessageDigest;

/** Hashing utilities: streaming MD5, HMAC-SHA256; content_id and asset_id helpers. */
public final class Hashing {
    private Hashing() {}

    public static byte[] md5File(File f) throws Exception {
        MessageDigest md = MessageDigest.getInstance("MD5");
        try (FileInputStream fis = new FileInputStream(f)) {
            byte[] buf = new byte[1024 * 1024];
            int r;
            while ((r = fis.read(buf)) > 0) { md.update(buf, 0, r); }
        }
        return md.digest();
    }

    public static String contentIdFromFile(File f) throws Exception {
        byte[] md5 = md5File(f);
        return Base58.encode(md5);
    }

    public static String assetIdB58FromFile(File f, String userId) throws Exception {
        byte[] h = hmacSha256File(f, userId.getBytes("UTF-8"));
        byte[] first16 = new byte[16];
        System.arraycopy(h, 0, first16, 0, 16);
        return Base58.encode(first16);
    }

    public static byte[] hmacSha256File(File f, byte[] key) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(key, "HmacSHA256"));
        try (FileInputStream fis = new FileInputStream(f)) {
            byte[] buf = new byte[1024 * 1024];
            int r;
            while ((r = fis.read(buf)) > 0) { mac.update(buf, 0, r); }
        }
        return mac.doFinal();
    }
}

