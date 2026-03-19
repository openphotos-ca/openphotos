package ca.openphotos.android.server;

import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;

/** Request/response models for enterprise sharing flows. */
public final class ShareModels {
    private ShareModels() {}

    public static final int PERM_VIEW = 1 << 0;
    public static final int PERM_COMMENT = 1 << 1;
    public static final int PERM_LIKE = 1 << 2;
    public static final int PERM_UPLOAD = 1 << 3;

    public static int permissionForRole(String role) {
        if ("contributor".equalsIgnoreCase(role)) return PERM_VIEW | PERM_COMMENT | PERM_LIKE | PERM_UPLOAD;
        if ("commenter".equalsIgnoreCase(role)) return PERM_VIEW | PERM_COMMENT | PERM_LIKE;
        return PERM_VIEW;
    }

    public static String roleName(int permissions) {
        if (permissions == (PERM_VIEW | PERM_COMMENT | PERM_LIKE | PERM_UPLOAD)) return "Contributor";
        if (permissions == (PERM_VIEW | PERM_COMMENT | PERM_LIKE)) return "Commenter";
        if (permissions == PERM_VIEW) return "Viewer";
        return "Custom";
    }

    @Nullable
    private static String optStringOrNull(JSONObject j, String key) {
        if (j == null || !j.has(key) || j.isNull(key)) return null;
        String s = j.optString(key, null);
        return (s == null || s.isEmpty()) ? null : s;
    }

    @Nullable
    private static Integer optIntOrNull(JSONObject j, String key) {
        if (j == null || !j.has(key) || j.isNull(key)) return null;
        try {
            return j.getInt(key);
        } catch (Exception ignored) {
            return null;
        }
    }

    @Nullable
    private static String firstNonEmpty(@Nullable String... values) {
        if (values == null) return null;
        for (String value : values) {
            if (value == null) continue;
            String trimmed = value.trim();
            if (!trimmed.isEmpty()) return trimmed;
        }
        return null;
    }

    public static final class ShareTarget {
        public final String kind; // user|group
        @Nullable public final String id;
        public final String label;
        @Nullable public final String email;

        public ShareTarget(String kind, @Nullable String id, String label, @Nullable String email) {
            this.kind = kind;
            this.id = id;
            this.label = label;
            this.email = email;
        }

        public static ShareTarget fromJson(JSONObject j) {
            return new ShareTarget(
                    j.optString("kind", "user"),
                    j.isNull("id") ? null : j.optString("id", null),
                    j.optString("label", ""),
                    j.isNull("email") ? null : j.optString("email", null)
            );
        }
    }

    public static final class RecipientInput {
        public final String type; // user|group|external_email
        @Nullable public final String id;
        @Nullable public final String email;
        @Nullable public final Integer permissions;

        public RecipientInput(String type, @Nullable String id, @Nullable String email, @Nullable Integer permissions) {
            this.type = type;
            this.id = id;
            this.email = email;
            this.permissions = permissions;
        }

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("type", type);
                if (id != null) j.put("id", id);
                if (email != null) j.put("email", email);
                if (permissions != null) j.put("permissions", permissions);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class ShareRecipient {
        public final String id;
        public final String recipientType;
        @Nullable public final String recipientUserId;
        @Nullable public final Integer recipientGroupId;
        @Nullable public final String externalEmail;
        @Nullable public final Integer externalOrgId;
        @Nullable public final Integer permissions;
        public final String invitationStatus;
        @Nullable public final String createdAt;

        public ShareRecipient(
                String id,
                String recipientType,
                @Nullable String recipientUserId,
                @Nullable Integer recipientGroupId,
                @Nullable String externalEmail,
                @Nullable Integer externalOrgId,
                @Nullable Integer permissions,
                String invitationStatus,
                @Nullable String createdAt
        ) {
            this.id = id;
            this.recipientType = recipientType;
            this.recipientUserId = recipientUserId;
            this.recipientGroupId = recipientGroupId;
            this.externalEmail = externalEmail;
            this.externalOrgId = externalOrgId;
            this.permissions = permissions;
            this.invitationStatus = invitationStatus;
            this.createdAt = createdAt;
        }

        public String displayLabel() {
            if ("user".equals(recipientType)) return recipientUserId != null ? recipientUserId : "User";
            if ("group".equals(recipientType)) return recipientGroupId != null ? ("Group #" + recipientGroupId) : "Group";
            if ("external_email".equals(recipientType)) return externalEmail != null ? externalEmail : "External";
            return recipientUserId != null ? recipientUserId : "Recipient";
        }

        public static ShareRecipient fromJson(JSONObject j) {
            return new ShareRecipient(
                    j.optString("id", ""),
                    j.optString("recipient_type", "user"),
                    optStringOrNull(j, "recipient_user_id"),
                    optIntOrNull(j, "recipient_group_id"),
                    optStringOrNull(j, "external_email"),
                    optIntOrNull(j, "external_org_id"),
                    optIntOrNull(j, "permissions"),
                    j.optString("invitation_status", "active"),
                    optStringOrNull(j, "created_at")
            );
        }
    }

    public static final class ShareItem {
        public final String id;
        public final int ownerOrgId;
        public final String ownerUserId;
        @Nullable public final String ownerDisplayName;
        @Nullable public final String ownerEmail;
        public final String objectKind;
        public final String objectId;
        public final int defaultPermissions;
        @Nullable public final String expiresAt;
        public final String status;
        @Nullable public final String createdAt;
        @Nullable public final String updatedAt;
        public final String name;
        public final boolean includeFaces;
        public final boolean includeSubtree;
        public final List<ShareRecipient> recipients;

        public ShareItem(
                String id,
                int ownerOrgId,
                String ownerUserId,
                @Nullable String ownerDisplayName,
                @Nullable String ownerEmail,
                String objectKind,
                String objectId,
                int defaultPermissions,
                @Nullable String expiresAt,
                String status,
                @Nullable String createdAt,
                @Nullable String updatedAt,
                String name,
                boolean includeFaces,
                boolean includeSubtree,
                List<ShareRecipient> recipients
        ) {
            this.id = id;
            this.ownerOrgId = ownerOrgId;
            this.ownerUserId = ownerUserId;
            this.ownerDisplayName = ownerDisplayName;
            this.ownerEmail = ownerEmail;
            this.objectKind = objectKind;
            this.objectId = objectId;
            this.defaultPermissions = defaultPermissions;
            this.expiresAt = expiresAt;
            this.status = status;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
            this.name = name;
            this.includeFaces = includeFaces;
            this.includeSubtree = includeSubtree;
            this.recipients = recipients;
        }

        public static ShareItem fromJson(JSONObject j) {
            JSONArray arr = j.optJSONArray("recipients");
            List<ShareRecipient> recipients = new ArrayList<>();
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    JSONObject item = arr.optJSONObject(i);
                    if (item != null) recipients.add(ShareRecipient.fromJson(item));
                }
            }
            return new ShareItem(
                    j.optString("id", ""),
                    j.optInt("owner_org_id", 0),
                    j.optString("owner_user_id", ""),
                    firstNonEmpty(
                            optStringOrNull(j, "owner_display_name"),
                            optStringOrNull(j, "owner_name")
                    ),
                    optStringOrNull(j, "owner_email"),
                    j.optString("object_kind", "album"),
                    j.optString("object_id", ""),
                    j.optInt("default_permissions", PERM_VIEW),
                    optStringOrNull(j, "expires_at"),
                    j.optString("status", "active"),
                    optStringOrNull(j, "created_at"),
                    optStringOrNull(j, "updated_at"),
                    j.optString("name", "Shared items"),
                    j.optBoolean("include_faces", true),
                    j.optBoolean("include_subtree", false),
                    recipients
            );
        }
    }

    public static final class CreateShareRequest {
        public String objectKind; // album|asset
        public String objectId;
        public String name;
        @Nullable public Integer defaultPermissions;
        @Nullable public String expiresAt;
        @Nullable public Boolean includeFaces;
        @Nullable public Boolean includeSubtree;
        public final List<RecipientInput> recipients = new ArrayList<>();

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                JSONObject object = new JSONObject();
                object.put("kind", objectKind);
                object.put("id", objectId);
                j.put("object", object);
                j.put("name", name);
                if (defaultPermissions != null) j.put("default_permissions", defaultPermissions);
                if (expiresAt != null) j.put("expires_at", expiresAt);
                if (includeFaces != null) j.put("include_faces", includeFaces);
                if (includeSubtree != null) j.put("include_subtree", includeSubtree);
                JSONArray rec = new JSONArray();
                for (RecipientInput r : recipients) rec.put(r.toJson());
                j.put("recipients", rec);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdateShareRequest {
        @Nullable public String name;
        @Nullable public Integer defaultPermissions;
        @Nullable public String expiresAt;
        @Nullable public Boolean includeFaces;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (name != null) j.put("name", name);
                if (defaultPermissions != null) j.put("default_permissions", defaultPermissions);
                if (expiresAt != null) j.put("expires_at", expiresAt);
                if (includeFaces != null) j.put("include_faces", includeFaces);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class CreatePublicLinkRequest {
        public String name;
        public String scopeKind; // album|upload_only
        @Nullable public Integer scopeAlbumId;
        public int permissions;
        @Nullable public String expiresAt;
        @Nullable public String pin;
        public String coverAssetId;
        @Nullable public Boolean moderationEnabled;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("name", name);
                j.put("scope_kind", scopeKind);
                if (scopeAlbumId != null) j.put("scope_album_id", scopeAlbumId);
                j.put("permissions", permissions);
                if (expiresAt != null) j.put("expires_at", expiresAt);
                if (pin != null) j.put("pin", pin);
                j.put("cover_asset_id", coverAssetId);
                if (moderationEnabled != null) j.put("moderation_enabled", moderationEnabled);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdatePublicLinkRequest {
        @Nullable public String name;
        @Nullable public Integer permissions;
        @Nullable public String expiresAt;
        @Nullable public String coverAssetId;
        @Nullable public String pin;
        @Nullable public Boolean clearPin;
        @Nullable public Boolean moderationEnabled;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (name != null) j.put("name", name);
                if (permissions != null) j.put("permissions", permissions);
                if (expiresAt != null) j.put("expires_at", expiresAt);
                if (coverAssetId != null) j.put("cover_asset_id", coverAssetId);
                if (pin != null) j.put("pin", pin);
                if (clearPin != null) j.put("clear_pin", clearPin);
                if (moderationEnabled != null) j.put("moderation_enabled", moderationEnabled);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class PublicLinkItem {
        public final String id;
        @Nullable public final Integer ownerOrgId;
        @Nullable public final String ownerUserId;
        public final String name;
        public final String scopeKind;
        @Nullable public final Integer scopeAlbumId;
        @Nullable public final Integer uploadsAlbumId;
        @Nullable public final String url;
        public final int permissions;
        @Nullable public final String expiresAt;
        @Nullable public final String status;
        @Nullable public final String coverAssetId;
        public final boolean moderationEnabled;
        @Nullable public final Integer pendingCount;
        @Nullable public final Boolean hasPin;
        @Nullable public final String key;
        @Nullable public final String createdAt;
        @Nullable public final String updatedAt;

        public PublicLinkItem(
                String id,
                @Nullable Integer ownerOrgId,
                @Nullable String ownerUserId,
                String name,
                String scopeKind,
                @Nullable Integer scopeAlbumId,
                @Nullable Integer uploadsAlbumId,
                @Nullable String url,
                int permissions,
                @Nullable String expiresAt,
                @Nullable String status,
                @Nullable String coverAssetId,
                boolean moderationEnabled,
                @Nullable Integer pendingCount,
                @Nullable Boolean hasPin,
                @Nullable String key,
                @Nullable String createdAt,
                @Nullable String updatedAt
        ) {
            this.id = id;
            this.ownerOrgId = ownerOrgId;
            this.ownerUserId = ownerUserId;
            this.name = name;
            this.scopeKind = scopeKind;
            this.scopeAlbumId = scopeAlbumId;
            this.uploadsAlbumId = uploadsAlbumId;
            this.url = url;
            this.permissions = permissions;
            this.expiresAt = expiresAt;
            this.status = status;
            this.coverAssetId = coverAssetId;
            this.moderationEnabled = moderationEnabled;
            this.pendingCount = pendingCount;
            this.hasPin = hasPin;
            this.key = key;
            this.createdAt = createdAt;
            this.updatedAt = updatedAt;
        }

        public static PublicLinkItem fromJson(JSONObject j) {
            return new PublicLinkItem(
                    j.optString("id", ""),
                    optIntOrNull(j, "owner_org_id"),
                    optStringOrNull(j, "owner_user_id"),
                    j.optString("name", "Public link"),
                    j.optString("scope_kind", "album"),
                    optIntOrNull(j, "scope_album_id"),
                    optIntOrNull(j, "uploads_album_id"),
                    optStringOrNull(j, "url"),
                    j.optInt("permissions", PERM_VIEW),
                    optStringOrNull(j, "expires_at"),
                    optStringOrNull(j, "status"),
                    optStringOrNull(j, "cover_asset_id"),
                    j.optBoolean("moderation_enabled", false),
                    optIntOrNull(j, "pending_count"),
                    j.has("has_pin") && !j.isNull("has_pin") ? j.optBoolean("has_pin") : null,
                    optStringOrNull(j, "key"),
                    optStringOrNull(j, "created_at"),
                    optStringOrNull(j, "updated_at")
            );
        }
    }

    public static final class CreatePublicLinkResponse {
        public final String id;
        @Nullable public final String url;
        @Nullable public final String key;
        public final String name;

        public CreatePublicLinkResponse(String id, @Nullable String url, @Nullable String key, String name) {
            this.id = id;
            this.url = url;
            this.key = key;
            this.name = name;
        }

        public static CreatePublicLinkResponse fromJson(JSONObject j) {
            return new CreatePublicLinkResponse(
                    j.optString("id", ""),
                    j.isNull("url") ? null : j.optString("url", null),
                    j.isNull("key") ? null : j.optString("key", null),
                    j.optString("name", "")
            );
        }
    }

    public static final class ShareAssetsPage {
        public final List<String> assetIds;
        public final boolean hasMore;

        public ShareAssetsPage(List<String> assetIds, boolean hasMore) {
            this.assetIds = assetIds;
            this.hasMore = hasMore;
        }

        public static ShareAssetsPage fromJson(JSONObject j) {
            JSONArray arr = j.optJSONArray("asset_ids");
            List<String> ids = new ArrayList<>();
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    String id = arr.optString(i, "");
                    if (!id.isEmpty()) ids.add(id);
                }
            }
            return new ShareAssetsPage(ids, j.optBoolean("has_more", false));
        }
    }

    public static final class ShareAssetMetadata {
        public final String assetId;
        public final String filename;
        @Nullable public final String mimeType;
        @Nullable public final Integer width;
        @Nullable public final Integer height;
        public final long createdAt;
        public final int favorites;
        public final boolean isVideo;
        public final boolean isLivePhoto;
        public final boolean locked;

        public ShareAssetMetadata(
                String assetId,
                String filename,
                @Nullable String mimeType,
                @Nullable Integer width,
                @Nullable Integer height,
                long createdAt,
                int favorites,
                boolean isVideo,
                boolean isLivePhoto,
                boolean locked
        ) {
            this.assetId = assetId;
            this.filename = filename;
            this.mimeType = mimeType;
            this.width = width;
            this.height = height;
            this.createdAt = createdAt;
            this.favorites = favorites;
            this.isVideo = isVideo;
            this.isLivePhoto = isLivePhoto;
            this.locked = locked;
        }

        public static ShareAssetMetadata fromJson(JSONObject j) {
            return new ShareAssetMetadata(
                    j.optString("asset_id", ""),
                    j.optString("filename", ""),
                    optStringOrNull(j, "mime_type"),
                    optIntOrNull(j, "width"),
                    optIntOrNull(j, "height"),
                    j.optLong("created_at", 0L),
                    j.optInt("favorites", 0),
                    j.optBoolean("is_video", false),
                    j.optBoolean("is_live_photo", false),
                    j.optBoolean("locked", false)
            );
        }
    }

    public static final class ShareFace {
        public final String personId;
        @Nullable public final String displayName;
        public final int count;

        public ShareFace(String personId, @Nullable String displayName, int count) {
            this.personId = personId;
            this.displayName = displayName;
            this.count = count;
        }

        public String label() {
            return (displayName != null && !displayName.isEmpty()) ? displayName : ("Person " + personId);
        }

        public static ShareFace fromJson(JSONObject j) {
            return new ShareFace(
                    j.optString("person_id", ""),
                    optStringOrNull(j, "display_name"),
                    j.optInt("count", 0)
            );
        }
    }

    public static final class ShareComment {
        public final String id;
        public final String authorDisplayName;
        @Nullable public final String authorUserId;
        @Nullable public final String viewerSessionId;
        public final String body;
        public final long createdAt;

        public ShareComment(
                String id,
                String authorDisplayName,
                @Nullable String authorUserId,
                @Nullable String viewerSessionId,
                String body,
                long createdAt
        ) {
            this.id = id;
            this.authorDisplayName = authorDisplayName;
            this.authorUserId = authorUserId;
            this.viewerSessionId = viewerSessionId;
            this.body = body;
            this.createdAt = createdAt;
        }

        public static ShareComment fromJson(JSONObject j) {
            return new ShareComment(
                    j.optString("id", ""),
                    j.optString("author_display_name", "User"),
                    optStringOrNull(j, "author_user_id"),
                    optStringOrNull(j, "viewer_session_id"),
                    j.optString("body", ""),
                    j.optLong("created_at", 0L)
            );
        }
    }

    public static final class ShareLikeCount {
        public final String assetId;
        public final int count;
        public final boolean likedByMe;

        public ShareLikeCount(String assetId, int count, boolean likedByMe) {
            this.assetId = assetId;
            this.count = count;
            this.likedByMe = likedByMe;
        }

        public static ShareLikeCount fromJson(JSONObject j) {
            return new ShareLikeCount(
                    j.optString("asset_id", ""),
                    j.optInt("count", 0),
                    j.optBoolean("liked_by_me", false)
            );
        }
    }

    public static final class ImportResult {
        public final int imported;
        public final int skipped;
        public final int failed;
        public final List<String> errors;

        public ImportResult(int imported, int skipped, int failed, List<String> errors) {
            this.imported = imported;
            this.skipped = skipped;
            this.failed = failed;
            this.errors = errors;
        }

        public static ImportResult fromJson(JSONObject j) {
            JSONArray arr = j.optJSONArray("errors");
            List<String> errs = new ArrayList<>();
            if (arr != null) {
                for (int i = 0; i < arr.length(); i++) {
                    String e = arr.optString(i, "");
                    if (!e.isEmpty()) errs.add(e);
                }
            }
            return new ImportResult(
                    j.optInt("imported", 0),
                    j.optInt("skipped", 0),
                    j.optInt("failed", 0),
                    errs
            );
        }
    }

    public static final class DekWrap {
        public final String assetId;
        public final String variant;
        public final String wrapIvB64;
        public final String dekWrappedB64;
        public final String encryptedByUserId;

        public DekWrap(String assetId, String variant, String wrapIvB64, String dekWrappedB64, String encryptedByUserId) {
            this.assetId = assetId;
            this.variant = variant;
            this.wrapIvB64 = wrapIvB64;
            this.dekWrappedB64 = dekWrappedB64;
            this.encryptedByUserId = encryptedByUserId;
        }

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("asset_id", assetId);
                j.put("variant", variant);
                j.put("wrap_iv_b64", wrapIvB64);
                j.put("dek_wrapped_b64", dekWrappedB64);
                j.put("encrypted_by_user_id", encryptedByUserId);
            } catch (Exception ignored) {}
            return j;
        }

        public static DekWrap fromJson(JSONObject j) {
            return new DekWrap(
                    j.optString("asset_id", ""),
                    j.optString("variant", "orig"),
                    j.optString("wrap_iv_b64", ""),
                    j.optString("dek_wrapped_b64", ""),
                    j.optString("encrypted_by_user_id", "")
            );
        }
    }

    public static List<ShareItem> parseShareList(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<ShareItem> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(ShareItem.fromJson(j));
        }
        return out;
    }

    public static List<PublicLinkItem> parsePublicLinks(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<PublicLinkItem> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(PublicLinkItem.fromJson(j));
        }
        return out;
    }

    public static List<ShareFace> parseFaces(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<ShareFace> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(ShareFace.fromJson(j));
        }
        return out;
    }

    public static List<ShareComment> parseComments(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<ShareComment> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(ShareComment.fromJson(j));
        }
        return out;
    }

    public static List<ShareLikeCount> parseLikeCounts(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<ShareLikeCount> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(ShareLikeCount.fromJson(j));
        }
        return out;
    }

    public static List<DekWrap> parseWraps(JSONArray arr) {
        if (arr == null) return Collections.emptyList();
        List<DekWrap> out = new ArrayList<>();
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j != null) out.add(DekWrap.fromJson(j));
        }
        return out;
    }
}
