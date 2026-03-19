package ca.openphotos.android.e2ee;

import android.content.Context;
import android.content.SharedPreferences;
import android.util.Base64;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import ca.openphotos.android.core.AuthManager;
import ca.openphotos.android.server.ServerPhotosService;
import ca.openphotos.android.server.ShareModels;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.math.BigInteger;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.AlgorithmParameters;
import java.security.KeyFactory;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.PrivateKey;
import java.security.PublicKey;
import java.security.SecureRandom;
import java.security.interfaces.ECPublicKey;
import java.security.spec.ECGenParameterSpec;
import java.security.spec.ECParameterSpec;
import java.security.spec.ECPoint;
import java.security.spec.ECPublicKeySpec;
import java.security.spec.PKCS8EncodedKeySpec;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;

import javax.crypto.Cipher;
import javax.crypto.KeyAgreement;
import javax.crypto.Mac;
import javax.crypto.spec.GCMParameterSpec;
import javax.crypto.spec.SecretKeySpec;

import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;

/**
 * E2EE helper for EE sharing:
 * - Identity pubkey bootstrap
 * - Share SMK envelope unwrap
 * - Share wraps fetch and locked media decrypt
 * - Public-link and internal-share wrap generation for owner flows
 */
public final class ShareE2EEManager {
    private static final String PREFS = "ee.share.e2ee";
    private static final String KEY_PRIVATE_PKCS8_B64 = "id.private.pkcs8";
    private static final String KEY_PUBLIC_RAW_B64 = "id.public.raw";
    private static final String KEY_PUBKEY_UPLOADED = "id.pub.uploaded";

    private static final byte[] MAGIC = new byte[] {'P', 'A', 'E', '3'};
    private static final int TRAILER_SIZE = 4 + 2 + 2 + 32;

    private static volatile ShareE2EEManager INSTANCE;

    private final Context app;
    private final ServerPhotosService svc;
    private final Map<String, byte[]> smkCache = new ConcurrentHashMap<>();
    private final Map<String, Map<String, ShareModels.DekWrap>> wrapCache = new ConcurrentHashMap<>();
    private final SecureRandom random = new SecureRandom();

    private ShareE2EEManager(Context app) {
        this.app = app.getApplicationContext();
        this.svc = new ServerPhotosService(this.app);
    }

    public static ShareE2EEManager get(Context app) {
        if (INSTANCE == null) {
            synchronized (ShareE2EEManager.class) {
                if (INSTANCE == null) INSTANCE = new ShareE2EEManager(app);
            }
        }
        return INSTANCE;
    }

    public static final class PublicLinkKeys {
        public final byte[] smk;
        public final byte[] vk;

        PublicLinkKeys(byte[] smk, byte[] vk) {
            this.smk = smk;
            this.vk = vk;
        }

        public String vkB64Url() { return b64url(vk); }
    }

    public synchronized void clearShareCache(String shareId) {
        smkCache.remove(shareId);
        wrapCache.remove(shareId + ":thumb");
        wrapCache.remove(shareId + ":orig");
    }

    public synchronized void clearAllCaches() {
        smkCache.clear();
        wrapCache.clear();
    }

    /** Ensures identity keypair exists and uploads current pubkey to server. */
    public synchronized void ensureIdentityKeyPair() throws Exception {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String pubB64 = sp.getString(KEY_PUBLIC_RAW_B64, null);
        String privB64 = sp.getString(KEY_PRIVATE_PKCS8_B64, null);
        if (pubB64 == null || privB64 == null) {
            KeyPair kp = generateP256KeyPair();
            String privatePkcs8B64 = Base64.encodeToString(kp.getPrivate().getEncoded(), Base64.NO_WRAP);
            String publicRawB64 = Base64.encodeToString(publicKeyToRaw65((ECPublicKey) kp.getPublic()), Base64.NO_WRAP);
            sp.edit()
                    .putString(KEY_PRIVATE_PKCS8_B64, privatePkcs8B64)
                    .putString(KEY_PUBLIC_RAW_B64, publicRawB64)
                    .putBoolean(KEY_PUBKEY_UPLOADED, false)
                    .apply();
            pubB64 = publicRawB64;
        }
        boolean uploaded = sp.getBoolean(KEY_PUBKEY_UPLOADED, false);
        if (!uploaded && pubB64 != null) {
            svc.setEeIdentityPubkey(pubB64);
            sp.edit().putBoolean(KEY_PUBKEY_UPLOADED, true).apply();
        }
    }

    @NonNull
    private PrivateKey loadPrivateKey() throws Exception {
        SharedPreferences sp = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String privB64 = sp.getString(KEY_PRIVATE_PKCS8_B64, null);
        if (privB64 == null || privB64.isEmpty()) throw new IllegalStateException("Missing identity private key");
        byte[] raw = Base64.decode(privB64, Base64.DEFAULT);
        return KeyFactory.getInstance("EC").generatePrivate(new PKCS8EncodedKeySpec(raw));
    }

    @NonNull
    public byte[] fetchAndUnwrapSmk(String shareId) throws Exception {
        byte[] cached = smkCache.get(shareId);
        if (cached != null && cached.length == 32) return cached;

        ensureIdentityKeyPair();
        PrivateKey privateKey = loadPrivateKey();
        JSONObject resp = svc.getMyShareSmkEnvelope(shareId);
        JSONObject env = resp.optJSONObject("env");
        if (env == null) throw new IllegalStateException("SMK envelope missing");

        String smkHex = env.optString("smk_hex", "");
        if (!smkHex.isEmpty()) {
            byte[] smk = hexToBytes(smkHex);
            if (smk.length == 32) {
                smkCache.put(shareId, smk);
                return smk;
            }
        }

        String epk = env.optString("ephemeral_pubkey_b64", env.optString("epk_b64url", ""));
        String ivB64 = env.optString("iv_b64url", "");
        if (epk.isEmpty() || ivB64.isEmpty()) throw new IllegalStateException("Invalid SMK envelope");

        byte[] epkRaw = decodeB64MaybeUrl(epk);
        byte[] iv = decodeB64MaybeUrl(ivB64);

        byte[] wrapped;
        byte[] tag;
        String ctCombined = env.optString("ct_b64url", "");
        if (!ctCombined.isEmpty()) {
            byte[] combined = decodeB64MaybeUrl(ctCombined);
            if (combined.length <= 16) throw new IllegalStateException("Invalid SMK envelope ciphertext");
            wrapped = new byte[combined.length - 16];
            tag = new byte[16];
            System.arraycopy(combined, 0, wrapped, 0, wrapped.length);
            System.arraycopy(combined, wrapped.length, tag, 0, 16);
        } else {
            wrapped = decodeB64MaybeUrl(env.optString("smk_wrapped_b64url", ""));
            tag = decodeB64MaybeUrl(env.optString("tag_b64url", ""));
            if (wrapped.length == 0 || tag.length != 16) throw new IllegalStateException("Invalid SMK envelope fields");
        }

        PublicKey ephemeralPub = raw65ToPublicKey(epkRaw);
        byte[] shared = ecdh(privateKey, ephemeralPub);
        byte[] kEnv = hkdfSha256(shared, "share:smk:env:v1".getBytes(StandardCharsets.UTF_8), 32);

        byte[] combined = new byte[wrapped.length + tag.length];
        System.arraycopy(wrapped, 0, combined, 0, wrapped.length);
        System.arraycopy(tag, 0, combined, wrapped.length, tag.length);
        byte[] smk = aesGcmDecryptCombined(kEnv, iv, null, combined);
        if (smk.length != 32) throw new IllegalStateException("Unexpected SMK length");
        smkCache.put(shareId, smk);
        return smk;
    }

    @NonNull
    public List<ShareModels.DekWrap> fetchShareWraps(String shareId, List<String> assetIds, String variant) throws Exception {
        if (assetIds == null || assetIds.isEmpty()) return new ArrayList<>();
        String cacheKey = shareId + ":" + variant;
        Map<String, ShareModels.DekWrap> variantCache = wrapCache.get(cacheKey);
        if (variantCache == null) variantCache = new HashMap<>();

        List<String> miss = new ArrayList<>();
        for (String aid : assetIds) if (!variantCache.containsKey(aid)) miss.add(aid);
        if (!miss.isEmpty()) {
            List<ShareModels.DekWrap> fetched = svc.getShareWraps(shareId, miss, variant);
            for (ShareModels.DekWrap w : fetched) variantCache.put(w.assetId, w);
            wrapCache.put(cacheKey, variantCache);
        }

        List<ShareModels.DekWrap> out = new ArrayList<>();
        for (String aid : assetIds) {
            ShareModels.DekWrap w = variantCache.get(aid);
            if (w != null) out.add(w);
        }
        return out;
    }

    /**
     * Decrypt a share thumb/original PAE3 container using share SMK + DEK wraps.
     * Returns original bytes when payload is not PAE3.
     */
    public byte[] decryptShareContainer(String shareId, String assetId, String variant, byte[] encrypted) throws Exception {
        if (encrypted == null || encrypted.length < 4) return encrypted;
        if (!isPae3(encrypted)) return encrypted;

        byte[] smk = fetchAndUnwrapSmk(shareId);
        List<ShareModels.DekWrap> wraps = fetchShareWraps(shareId, java.util.Collections.singletonList(assetId), variant);
        if (wraps.isEmpty()) {
            throw new IllegalStateException("No wrap available");
        }
        ShareModels.DekWrap wrap = wraps.get(0);
        return decryptPae3WithWrap(encrypted, smk, wrap.wrapIvB64, wrap.dekWrappedB64);
    }

    public PublicLinkKeys generatePublicLinkKeys() {
        byte[] smk = new byte[32];
        byte[] vk = new byte[32];
        random.nextBytes(smk);
        random.nextBytes(vk);
        return new PublicLinkKeys(smk, vk);
    }

    public JSONObject createPublicLinkEnvelope(byte[] smk, byte[] vk) throws Exception {
        byte[] kEnv = hkdfSha256(vk, "env:v1".getBytes(StandardCharsets.UTF_8), 32);
        byte[] iv = new byte[12];
        random.nextBytes(iv);
        byte[] wrapped = aesGcmEncryptCombined(kEnv, iv, null, smk);
        byte[] ct = new byte[wrapped.length - 16];
        byte[] tag = new byte[16];
        System.arraycopy(wrapped, 0, ct, 0, ct.length);
        System.arraycopy(wrapped, ct.length, tag, 0, 16);

        JSONObject env = new JSONObject();
        env.put("iv_b64url", b64url(iv));
        env.put("smk_wrapped_b64url", b64url(ct));
        env.put("tag_b64url", b64url(tag));
        return env;
    }

    public void uploadPublicLinkEnvelope(String linkId, JSONObject env) throws Exception {
        svc.uploadPublicLinkSmkEnvelope(linkId, env);
    }

    public void uploadPublicLinkWraps(String linkId, List<ShareModels.DekWrap> wraps) throws Exception {
        JSONArray items = new JSONArray();
        for (ShareModels.DekWrap w : wraps) items.put(w.toJson());
        svc.uploadPublicLinkWrapsBatch(linkId, items);
    }

    public void uploadShareRecipientEnvelopes(String shareId, List<String> recipientUserIds, byte[] smk) throws Exception {
        ensureIdentityKeyPair();
        JSONArray items = new JSONArray();
        for (String uid : new LinkedHashSet<>(recipientUserIds)) {
            if (uid == null || uid.isEmpty()) continue;
            JSONObject env = makeRecipientEnvelope(uid, smk);
            JSONObject row = new JSONObject();
            row.put("recipient_user_id", uid);
            row.put("env", env);
            items.put(row);
        }
        if (items.length() > 0) svc.uploadShareRecipientEnvelopes(shareId, items);
    }

    public void uploadShareWraps(String shareId, List<ShareModels.DekWrap> wraps) throws Exception {
        JSONArray items = new JSONArray();
        for (ShareModels.DekWrap w : wraps) items.put(w.toJson());
        if (items.length() > 0) svc.uploadShareWrapsBatch(shareId, items);
    }

    public List<ShareModels.DekWrap> buildWrapsForShare(List<String> assetIds, byte[] umk, byte[] smk, String variant, String ownerUserId) {
        List<ShareModels.DekWrap> out = new ArrayList<>();
        if (assetIds == null || assetIds.isEmpty()) return out;
        OkHttpClient client = ca.openphotos.android.core.AuthorizedHttpClient.get(app).raw();
        ServerPhotosService service = new ServerPhotosService(app);
        for (String aid : assetIds) {
            try {
                if (aid == null || aid.isEmpty()) continue;
                String endpoint = "thumb".equals(variant) ? service.thumbnailUrl(aid) : service.imageUrl(aid);
                byte[] container = fetchBytes(client, endpoint);
                if (!isPae3(container)) continue;
                WrapRekeyResult rekey = rekeyWrapFromContainer(container, umk, smk);
                out.add(new ShareModels.DekWrap(aid, variant, rekey.wrapIvB64, rekey.dekWrappedB64, ownerUserId));
            } catch (Exception ignored) {
            }
        }
        return out;
    }

    public List<ShareModels.DekWrap> buildWrapsForPublicLink(List<String> assetIds, byte[] umk, byte[] smk, String ownerUserId) {
        List<ShareModels.DekWrap> out = new ArrayList<>();
        out.addAll(buildWrapsForShare(assetIds, umk, smk, "thumb", ownerUserId));
        out.addAll(buildWrapsForShare(assetIds, umk, smk, "orig", ownerUserId));
        return out;
    }

    @NonNull
    private JSONObject makeRecipientEnvelope(String recipientUserId, byte[] smk) throws Exception {
        JSONObject recipient = svc.getEeIdentityPubkey(recipientUserId);
        String pubB64 = recipient.optString("pubkey_b64", "");
        if (pubB64.isEmpty()) {
            JSONObject env = new JSONObject();
            env.put("smk_hex", bytesToHex(smk));
            return env;
        }
        byte[] recipientPubRaw = Base64.decode(pubB64, Base64.DEFAULT);
        if (recipientPubRaw.length != 65 || recipientPubRaw[0] != 0x04) {
            JSONObject env = new JSONObject();
            env.put("smk_hex", bytesToHex(smk));
            return env;
        }

        KeyPair ephemeral = generateP256KeyPair();
        byte[] ephemeralPubRaw = publicKeyToRaw65((ECPublicKey) ephemeral.getPublic());

        PublicKey recipientPub = raw65ToPublicKey(recipientPubRaw);
        byte[] shared = ecdh(ephemeral.getPrivate(), recipientPub);
        byte[] kEnv = hkdfSha256(shared, "share:smk:env:v1".getBytes(StandardCharsets.UTF_8), 32);

        byte[] iv = new byte[12];
        random.nextBytes(iv);
        byte[] ctCombined = aesGcmEncryptCombined(kEnv, iv, null, smk);
        byte[] ct = new byte[ctCombined.length - 16];
        byte[] tag = new byte[16];
        System.arraycopy(ctCombined, 0, ct, 0, ct.length);
        System.arraycopy(ctCombined, ct.length, tag, 0, tag.length);

        JSONObject env = new JSONObject();
        env.put("alg", "ECIES-P256-AESGCM");
        env.put("ephemeral_pubkey_b64", b64url(ephemeralPubRaw));
        env.put("epk_b64url", b64url(ephemeralPubRaw));
        env.put("iv_b64url", b64url(iv));
        env.put("smk_wrapped_b64url", b64url(ct));
        env.put("tag_b64url", b64url(tag));
        env.put("ct_b64url", b64url(ctCombined));
        return env;
    }

    private static final class WrapRekeyResult {
        final String wrapIvB64;
        final String dekWrappedB64;

        WrapRekeyResult(String wrapIvB64, String dekWrappedB64) {
            this.wrapIvB64 = wrapIvB64;
            this.dekWrappedB64 = dekWrappedB64;
        }
    }

    @NonNull
    private WrapRekeyResult rekeyWrapFromContainer(byte[] containerData, byte[] umk, byte[] smk) throws Exception {
        ParsedOuterHeader header = parseOuterHeader(containerData);
        byte[] wrapKeyOld = hkdfSha256(umk, "hkdf:wrap:v3".getBytes(StandardCharsets.UTF_8), 32);
        byte[] aadWrap = concat("wrap:v3".getBytes(StandardCharsets.UTF_8), header.assetId16);
        byte[] dek = aesGcmDecryptCombined(wrapKeyOld, header.wrapIv, aadWrap, header.dekWrappedCombined);

        byte[] wrapKeyNew = hkdfSha256(smk, "hkdf:wrap:v3".getBytes(StandardCharsets.UTF_8), 32);
        byte[] newIv = new byte[12];
        random.nextBytes(newIv);
        byte[] wrappedCombined = aesGcmEncryptCombined(wrapKeyNew, newIv, aadWrap, dek);
        return new WrapRekeyResult(b64url(newIv), b64url(wrappedCombined));
    }

    private static final class ParsedOuterHeader {
        final byte[] assetId16;
        final byte[] baseIv;
        final byte[] wrapIv;
        final byte[] headerIv;
        final byte[] headerCtCombined;
        final byte[] dekWrappedCombined;
        final int headerEndOffset;

        ParsedOuterHeader(
                byte[] assetId16,
                byte[] baseIv,
                byte[] wrapIv,
                byte[] headerIv,
                byte[] headerCtCombined,
                byte[] dekWrappedCombined,
                int headerEndOffset
        ) {
            this.assetId16 = assetId16;
            this.baseIv = baseIv;
            this.wrapIv = wrapIv;
            this.headerIv = headerIv;
            this.headerCtCombined = headerCtCombined;
            this.dekWrappedCombined = dekWrappedCombined;
            this.headerEndOffset = headerEndOffset;
        }
    }

    @NonNull
    private ParsedOuterHeader parseOuterHeader(byte[] pae3) throws Exception {
        if (!isPae3(pae3)) throw new IllegalStateException("Invalid PAE3 header");
        int headerLen = be32(pae3, 6);
        int headerStart = 10;
        int headerEnd = headerStart + headerLen;
        if (headerLen <= 0 || headerEnd > pae3.length) throw new IllegalStateException("Invalid PAE3 header length");

        JSONObject header = new JSONObject(new String(pae3, headerStart, headerLen, StandardCharsets.UTF_8));
        byte[] assetId16 = decodeB64MaybeUrl(header.optString("asset_id", ""));
        byte[] baseIv = decodeB64MaybeUrl(header.optString("base_iv", ""));
        byte[] wrapIv = decodeB64MaybeUrl(header.optString("wrap_iv", ""));
        byte[] headerIv = decodeB64MaybeUrl(header.optString("header_iv", ""));
        byte[] headerCtCombined = decodeB64MaybeUrl(header.optString("header_ct", ""));
        byte[] dekWrappedCombined = decodeB64MaybeUrl(header.optString("dek_wrapped", ""));
        if (assetId16.length != 16 || baseIv.length != 12 || wrapIv.length != 12 || headerIv.length != 12 || headerCtCombined.length <= 16 || dekWrappedCombined.length <= 16) {
            throw new IllegalStateException("Malformed PAE3 outer header");
        }
        return new ParsedOuterHeader(assetId16, baseIv, wrapIv, headerIv, headerCtCombined, dekWrappedCombined, headerEnd);
    }

    @NonNull
    private byte[] decryptPae3WithWrap(byte[] pae3, byte[] smk, String wrapIvB64, String dekWrappedB64) throws Exception {
        ParsedOuterHeader h = parseOuterHeader(pae3);

        byte[] wrapIv = decodeB64MaybeUrl(wrapIvB64);
        byte[] dekWrapped = decodeB64MaybeUrl(dekWrappedB64);
        if (wrapIv.length != 12 || dekWrapped.length <= 16) throw new IllegalStateException("Invalid wrap data");

        byte[] wrapKey = hkdfSha256(smk, "hkdf:wrap:v3".getBytes(StandardCharsets.UTF_8), 32);
        byte[] aadWrap = concat("wrap:v3".getBytes(StandardCharsets.UTF_8), h.assetId16);
        byte[] dek = aesGcmDecryptCombined(wrapKey, wrapIv, aadWrap, dekWrapped);

        byte[] aadHeader = concat("header:v3".getBytes(StandardCharsets.UTF_8), h.assetId16);
        // Header decrypt validates key and envelope consistency.
        aesGcmDecryptCombined(dek, h.headerIv, aadHeader, h.headerCtCombined);

        int trailerPos = pae3.length - TRAILER_SIZE;
        if (trailerPos <= h.headerEndOffset) throw new IllegalStateException("Invalid PAE3 body");

        ByteArrayOutputStream out = new ByteArrayOutputStream();
        int pos = h.headerEndOffset;
        int idx = 0;
        while (pos < trailerPos) {
            if (pos + 4 > trailerPos) throw new IllegalStateException("Invalid PAE3 chunk length");
            int clen = be32(pae3, pos);
            pos += 4;
            if (clen <= 0 || pos + clen > trailerPos) throw new IllegalStateException("Invalid PAE3 chunk");
            byte[] ct = new byte[clen];
            System.arraycopy(pae3, pos, ct, 0, clen);
            pos += clen;

            boolean last = (pos == trailerPos);
            byte[] aadChunk = aadForChunk(h.assetId16, idx, last);
            byte[] iv = addToIv(h.baseIv, idx);
            byte[] plain = aesGcmDecryptCombined(dek, iv, aadChunk, ct);
            out.write(plain);
            idx++;
        }
        return out.toByteArray();
    }

    private static byte[] aadForChunk(byte[] assetId16, int idx, boolean last) {
        ByteBuffer bb = ByteBuffer.allocate("chunk:v3".length() + assetId16.length + 4 + 1);
        bb.put("chunk:v3".getBytes(StandardCharsets.UTF_8));
        bb.put(assetId16);
        bb.putInt(idx);
        bb.put((byte) (last ? 1 : 0));
        return bb.array();
    }

    private static byte[] addToIv(byte[] iv, int counter) {
        byte[] out = iv.clone();
        int c = counter;
        for (int i = out.length - 1; i >= 0 && c > 0; i--) {
            int v = (out[i] & 0xFF) + (c & 0xFF);
            out[i] = (byte) (v & 0xFF);
            c >>>= 8;
        }
        return out;
    }

    private static int be32(byte[] bytes, int off) {
        return ((bytes[off] & 0xFF) << 24)
                | ((bytes[off + 1] & 0xFF) << 16)
                | ((bytes[off + 2] & 0xFF) << 8)
                | (bytes[off + 3] & 0xFF);
    }

    private static boolean isPae3(byte[] data) {
        return data != null && data.length >= 4
                && data[0] == MAGIC[0]
                && data[1] == MAGIC[1]
                && data[2] == MAGIC[2]
                && data[3] == MAGIC[3];
    }

    private static byte[] fetchBytes(OkHttpClient client, String absoluteUrl) throws IOException {
        Request req = new Request.Builder().url(absoluteUrl).get().build();
        try (Response r = client.newCall(req).execute()) {
            if (!r.isSuccessful()) {
                String body = r.body() != null ? r.body().string() : "";
                throw new IOException("HTTP " + r.code() + (body.isEmpty() ? "" : (" - " + body)));
            }
            return r.body() != null ? r.body().bytes() : new byte[0];
        }
    }

    private static KeyPair generateP256KeyPair() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("EC");
        kpg.initialize(new ECGenParameterSpec("secp256r1"));
        return kpg.generateKeyPair();
    }

    private static PublicKey raw65ToPublicKey(byte[] raw65) throws Exception {
        if (raw65.length != 65 || raw65[0] != 0x04) throw new IllegalArgumentException("Invalid raw P-256 key");
        byte[] xb = new byte[32];
        byte[] yb = new byte[32];
        System.arraycopy(raw65, 1, xb, 0, 32);
        System.arraycopy(raw65, 33, yb, 0, 32);

        AlgorithmParameters params = AlgorithmParameters.getInstance("EC");
        params.init(new ECGenParameterSpec("secp256r1"));
        ECParameterSpec ecSpec = params.getParameterSpec(ECParameterSpec.class);
        ECPoint point = new ECPoint(new BigInteger(1, xb), new BigInteger(1, yb));
        ECPublicKeySpec pubSpec = new ECPublicKeySpec(point, ecSpec);
        return KeyFactory.getInstance("EC").generatePublic(pubSpec);
    }

    private static byte[] publicKeyToRaw65(ECPublicKey publicKey) {
        byte[] xb = toFixed32(publicKey.getW().getAffineX().toByteArray());
        byte[] yb = toFixed32(publicKey.getW().getAffineY().toByteArray());
        byte[] raw = new byte[65];
        raw[0] = 0x04;
        System.arraycopy(xb, 0, raw, 1, 32);
        System.arraycopy(yb, 0, raw, 33, 32);
        return raw;
    }

    private static byte[] toFixed32(byte[] in) {
        if (in.length == 32) return in;
        byte[] out = new byte[32];
        if (in.length > 32) {
            System.arraycopy(in, in.length - 32, out, 0, 32);
        } else {
            System.arraycopy(in, 0, out, 32 - in.length, in.length);
        }
        return out;
    }

    private static byte[] ecdh(PrivateKey privateKey, PublicKey publicKey) throws Exception {
        KeyAgreement ka = KeyAgreement.getInstance("ECDH");
        ka.init(privateKey);
        ka.doPhase(publicKey, true);
        return ka.generateSecret();
    }

    private static byte[] hkdfSha256(byte[] ikm, byte[] info, int outLen) throws Exception {
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(new byte[32], "HmacSHA256"));
        byte[] prk = mac.doFinal(ikm);

        byte[] out = new byte[outLen];
        byte[] t = new byte[0];
        int pos = 0;
        int counter = 1;
        while (pos < outLen) {
            mac.init(new SecretKeySpec(prk, "HmacSHA256"));
            mac.update(t);
            mac.update(info);
            mac.update((byte) counter);
            t = mac.doFinal();
            int n = Math.min(t.length, outLen - pos);
            System.arraycopy(t, 0, out, pos, n);
            pos += n;
            counter++;
        }
        return out;
    }

    private static byte[] aesGcmEncryptCombined(byte[] key, byte[] iv, @Nullable byte[] aad, byte[] plain) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.ENCRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        if (aad != null && aad.length > 0) c.updateAAD(aad);
        return c.doFinal(plain);
    }

    private static byte[] aesGcmDecryptCombined(byte[] key, byte[] iv, @Nullable byte[] aad, byte[] ciphertextAndTag) throws Exception {
        Cipher c = Cipher.getInstance("AES/GCM/NoPadding");
        c.init(Cipher.DECRYPT_MODE, new SecretKeySpec(key, "AES"), new GCMParameterSpec(128, iv));
        if (aad != null && aad.length > 0) c.updateAAD(aad);
        return c.doFinal(ciphertextAndTag);
    }

    private static byte[] concat(byte[] a, byte[] b) {
        byte[] out = new byte[a.length + b.length];
        System.arraycopy(a, 0, out, 0, a.length);
        System.arraycopy(b, 0, out, a.length, b.length);
        return out;
    }

    private static byte[] decodeB64MaybeUrl(String raw) {
        if (raw == null || raw.isEmpty()) return new byte[0];
        String s = raw.trim();
        // Try regular first.
        try {
            return Base64.decode(s, Base64.DEFAULT);
        } catch (Exception ignored) {
        }
        // Try URL-safe + padding.
        String t = s.replace('-', '+').replace('_', '/');
        int pad = (4 - (t.length() % 4)) % 4;
        StringBuilder sb = new StringBuilder(t);
        for (int i = 0; i < pad; i++) sb.append('=');
        return Base64.decode(sb.toString(), Base64.DEFAULT);
    }

    private static String b64url(byte[] data) {
        return Base64.encodeToString(data, Base64.NO_WRAP)
                .replace('+', '-')
                .replace('/', '_')
                .replace("=", "");
    }

    private static String bytesToHex(byte[] data) {
        StringBuilder sb = new StringBuilder();
        for (byte b : data) sb.append(String.format("%02x", b));
        return sb.toString();
    }

    private static byte[] hexToBytes(String hex) {
        if (hex == null) return new byte[0];
        String h = hex.trim();
        if (h.length() % 2 != 0) return new byte[0];
        byte[] out = new byte[h.length() / 2];
        for (int i = 0; i < out.length; i++) {
            int hi = Character.digit(h.charAt(i * 2), 16);
            int lo = Character.digit(h.charAt(i * 2 + 1), 16);
            if (hi < 0 || lo < 0) return new byte[0];
            out[i] = (byte) ((hi << 4) + lo);
        }
        return out;
    }

    @Nullable
    public static String appendVkToUrl(@Nullable String url, @NonNull String vkB64Url) {
        if (url == null || url.isEmpty()) return url;
        if (url.contains("#vk=")) return url;
        return url + "#vk=" + vkB64Url;
    }

    public static boolean isUnauthorizedError(Throwable t) {
        if (t == null || t.getMessage() == null) return false;
        String m = t.getMessage();
        return m.contains("HTTP 401") || m.contains("HTTP 403");
    }

    public static boolean hasUmk(Context context) {
        return new E2EEManager(context.getApplicationContext()).getUmk() != null;
    }

    @Nullable
    public static byte[] currentUmk(Context context) {
        return new E2EEManager(context.getApplicationContext()).getUmk();
    }

    @Nullable
    public static String currentUserId(Context context) {
        return AuthManager.get(context.getApplicationContext()).getUserId();
    }
}
