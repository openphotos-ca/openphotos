package ca.openphotos.android.server;

import android.content.Context;
import androidx.annotation.Nullable;

import ca.openphotos.android.core.AuthorizedHttpClient;
import ca.openphotos.android.core.AuthManager;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

import okhttp3.MediaType;
import okhttp3.Request;
import okhttp3.RequestBody;
import okhttp3.Response;

/** Minimal server API wrappers for albums/faces/search/media. */
public final class ServerPhotosService {
    private final Context app;
    public ServerPhotosService(Context app) { this.app = app.getApplicationContext(); }

    private String url(String path) { return AuthManager.get(app).getServerUrl() + path; }
    private String encPath(String value) {
        try { return java.net.URLEncoder.encode(value, java.nio.charset.StandardCharsets.UTF_8.name()); }
        catch (Exception ignored) { return value; }
    }

    public JSONArray listAlbums() throws IOException { return getJsonArray("/api/albums"); }
    public JSONArray listMedia() throws IOException { return getJsonArray("/api/media"); }

    /** Filters metadata (faces, countries, cities, cameras) */
    public JSONObject getFilterMetadata() throws IOException { return getJsonObject("/api/filters/metadata"); }

    public JSONObject createAlbum(String name, String description, Long parentId) throws IOException {
        JSONObject body = new JSONObject(); try { body.put("name", name); if (description != null) body.put("description", description); if (parentId != null) body.put("parent_id", parentId); } catch (Exception ignored) {}
        return postJson("/api/albums", body);
    }

    public JSONObject updateAlbum(long id, String name, String description, Long parentId, Integer position) throws IOException {
        JSONObject body = new JSONObject(); try { body.put("id", id); if (name != null) body.put("name", name); if (description != null) body.put("description", description); if (parentId != null) body.put("parent_id", parentId); if (position != null) body.put("position", position); } catch (Exception ignored) {}
        return postJson("/api/albums/update", body);
    }

    public JSONObject createLiveAlbum(String name, String description, Long parentId, JSONObject criteria) throws IOException {
        JSONObject body = new JSONObject(); try { body.put("name", name); if (description != null) body.put("description", description); if (parentId != null) body.put("parent_id", parentId); body.put("criteria", criteria); } catch (Exception ignored) {}
        return postJson("/api/albums/live", body);
    }

    public JSONObject freezeAlbum(long id, String nameOrNull) throws IOException {
        JSONObject body = new JSONObject(); try { if (nameOrNull != null && !nameOrNull.isEmpty()) body.put("name", nameOrNull); } catch (Exception ignored) {}
        return postJson("/api/albums/" + id + "/freeze", body);
    }

    public void deleteAlbum(long id) throws IOException {
        Request req = new Request.Builder().url(url("/api/albums/" + id)).delete().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) { if (!r.isSuccessful()) throw new IOException("HTTP " + r.code()); }
    }

    public JSONArray getFaces() throws IOException { return getJsonArray("/api/faces"); }

    /** Typed persons list from /api/faces for Manage Faces UI. */
    public List<FaceModels.Person> listPersons() throws IOException {
        return FaceModels.parsePersons(getJsonArray("/api/faces"));
    }

    public JSONObject updateMetadata(String assetId, String caption, String description) throws IOException {
        String path = "/api/photos/" + assetId + "/metadata";
        JSONObject body = new JSONObject(); try { body.put("caption", caption); body.put("description", description); } catch (Exception ignored) {}
        return putJson(path, body);
    }

    public JSONObject search(String q, String media, Boolean locked, String dateFrom, String dateTo, int page, int limit) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("q", q); if (media != null) body.put("media", media); if (locked != null) body.put("locked", locked); if (dateFrom != null) body.put("date_from", dateFrom); if (dateTo != null) body.put("date_to", dateTo); body.put("page", page); body.put("limit", limit); } catch (Exception ignored) {}
        return postJson("/api/search", body);
    }

    /** Fetch paged similar photo groups. */
    public SimilarMediaModels.GroupsResponse getSimilarPhotoGroups(int threshold, int minGroupSize, int limit, int cursor) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/similar/groups")).newBuilder();
        hb.addQueryParameter("threshold", String.valueOf(threshold));
        hb.addQueryParameter("min_group_size", String.valueOf(minGroupSize));
        hb.addQueryParameter("limit", String.valueOf(limit));
        hb.addQueryParameter("cursor", String.valueOf(cursor));
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "{}";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONObject j;
            try { j = new JSONObject(s.isEmpty() ? "{}" : s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return SimilarMediaModels.parseGroupsResponse(j);
        }
    }

    /** Fetch paged similar video groups. */
    public SimilarMediaModels.GroupsResponse getSimilarVideoGroups(int minGroupSize, int limit, int cursor) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/video/similar/groups")).newBuilder();
        hb.addQueryParameter("min_group_size", String.valueOf(minGroupSize));
        hb.addQueryParameter("limit", String.valueOf(limit));
        hb.addQueryParameter("cursor", String.valueOf(cursor));
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "{}";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONObject j;
            try { j = new JSONObject(s.isEmpty() ? "{}" : s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return SimilarMediaModels.parseGroupsResponse(j);
        }
    }

    /** True when asset is already fully backed up for this user/org and can be skipped pre-upload. */
    public boolean isAssetFullyBackedUp(String assetId) throws IOException {
        if (assetId == null || assetId.isEmpty()) return false;
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            arr.put(assetId);
            body.put("asset_ids", arr);
        } catch (Exception ignored) {}
        JSONObject resp = postJson("/api/photos/exists", body);
        JSONArray present = resp.optJSONArray("present_asset_ids");
        if (present == null) return false;
        for (int i = 0; i < present.length(); i++) {
            if (assetId.equals(present.optString(i, ""))) return true;
        }
        return false;
    }

    /** Returns subset of backup IDs that are fully backed up server-side. */
    public java.util.Set<String> existsFullyBackedUpByBackupIds(@Nullable java.util.List<String> backupIds) throws IOException {
        java.util.HashSet<String> out = new java.util.HashSet<>();
        if (backupIds == null || backupIds.isEmpty()) return out;
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (String id : backupIds) {
                if (id != null && !id.isEmpty()) arr.put(id);
            }
            body.put("backup_ids", arr);
        } catch (Exception ignored) {}
        JSONObject resp = postJson("/api/photos/exists", body);
        JSONArray present = resp.optJSONArray("present_backup_ids");
        if (present == null) return out;
        for (int i = 0; i < present.length(); i++) {
            String id = present.optString(i, "");
            if (!id.isEmpty()) out.add(id);
        }
        return out;
    }

    /** Hydrate photos by asset IDs. Returns JSON array of photo objects. */
    public JSONArray getPhotosByAssetIds(java.util.List<String> assetIds, boolean includeLocked) throws IOException {
        JSONObject body = new JSONObject();
        try {
            org.json.JSONArray arr = new org.json.JSONArray();
            for (String id : assetIds) arr.put(id);
            body.put("asset_ids", arr);
            body.put("include_locked", includeLocked);
        } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/photos/by-ids")).post(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "[]";
            try { return new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Toggle favorite for a photo by asset id. */
    public JSONObject setFavorite(String assetId, boolean favorite) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        JSONObject body = new JSONObject();
        try { body.put("favorite", favorite); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/photos/" + enc + "/favorite")).put(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Update rating (0..5, 0 or null clears to NULL) for a photo by asset id. */
    public JSONObject updateRating(String assetId, @Nullable Integer rating) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        JSONObject body = new JSONObject();
        try { if (rating != null) body.put("rating", rating); else body.put("rating", JSONObject.NULL); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/photos/" + enc + "/rating")).put(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body()!=null? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Soft delete photos by asset ids (moves to trash). */
    public JSONObject deletePhotos(java.util.List<String> assetIds) throws IOException {
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (String id : assetIds) arr.put(id);
            body.put("asset_ids", arr);
        } catch (Exception ignored) {}
        return postJson("/api/photos/delete", body);
    }

    /** Permanently purge all items currently in trash for the authenticated user. */
    public JSONObject purgeAllTrash() throws IOException {
        return postJson("/api/photos/purge-all", new JSONObject());
    }

    /** Fetch albums for a numeric photo id. */
    public JSONArray getAlbumsForPhoto(int photoId) throws IOException {
        Request req = new Request.Builder().url(url("/api/photos/" + photoId + "/albums")).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body()!=null? r.body().string():"[]";
            try { return new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Add photos by numeric ids to an album. */
    public JSONObject addPhotosToAlbum(int albumId, java.util.List<Integer> photoIds) throws IOException {
        JSONObject body = new JSONObject();
        try { org.json.JSONArray arr = new org.json.JSONArray(); for (int id: photoIds) arr.put(id); body.put("photo_ids", arr); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/albums/" + albumId + "/photos")).post(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body()!=null? r.body().string():"{}"; try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Remove photos by numeric ids from an album. */
    public JSONObject removePhotosFromAlbum(int albumId, java.util.List<Integer> photoIds) throws IOException {
        JSONObject body = new JSONObject();
        try { org.json.JSONArray arr = new org.json.JSONArray(); for (int id: photoIds) arr.put(id); body.put("photo_ids", arr); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/albums/" + albumId + "/photos")).delete(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body()!=null? r.body().string():"{}"; try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Lock a photo (one-way). */
    public void lockPhoto(String assetId) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        Request req = new Request.Builder().url(url("/api/photos/" + enc + "/lock")).post(RequestBody.create(new byte[0], MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) { if (!r.isSuccessful()) throw new IOException("HTTP " + r.code()); }
    }

    // ---- EE Team / Users & Groups ----
    public TeamModels.OrgInfo getTeamOrgInfo() throws IOException {
        return TeamModels.OrgInfo.fromJson(getJsonObject("/api/team/org"));
    }

    public TeamModels.OrgInfo updateTeamOrg(TeamModels.UpdateOrgRequest reqModel) throws IOException {
        JSONObject j = patchJson("/api/team/org", reqModel.toJson());
        return TeamModels.OrgInfo.fromJson(j);
    }

    public List<TeamModels.TeamUser> listTeamUsers() throws IOException {
        return TeamModels.parseUsers(getJsonArray("/api/team/users"));
    }

    public TeamModels.TeamUser createTeamUser(TeamModels.CreateTeamUserRequest reqModel) throws IOException {
        JSONObject j = postJson("/api/team/users", reqModel.toJson());
        return TeamModels.TeamUser.fromJson(j);
    }

    public TeamModels.TeamUser updateTeamUser(String userId, TeamModels.UpdateTeamUserRequest reqModel) throws IOException {
        JSONObject j = patchJson("/api/team/users/" + encPath(userId), reqModel.toJson());
        return TeamModels.TeamUser.fromJson(j);
    }

    public void deleteTeamUser(String userId, boolean hardDelete) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/team/users/" + encPath(userId))).newBuilder();
        if (hardDelete) hb.addQueryParameter("hard", "true");
        Request req = new Request.Builder().url(hb.build()).delete().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
        }
    }

    public void resetTeamUserPassword(String userId, TeamModels.ResetPasswordRequest reqModel) throws IOException {
        postJson("/api/team/users/" + encPath(userId) + "/reset-password", reqModel.toJson());
    }

    public List<TeamModels.TeamGroup> listTeamGroups() throws IOException {
        return TeamModels.parseGroups(getJsonArray("/api/team/groups"));
    }

    public TeamModels.TeamGroup createTeamGroup(TeamModels.CreateGroupRequest reqModel) throws IOException {
        JSONObject j = postJson("/api/team/groups", reqModel.toJson());
        return TeamModels.TeamGroup.fromJson(j);
    }

    public TeamModels.TeamGroup updateTeamGroup(int groupId, TeamModels.UpdateGroupRequest reqModel) throws IOException {
        JSONObject j = patchJson("/api/team/groups/" + groupId, reqModel.toJson());
        return TeamModels.TeamGroup.fromJson(j);
    }

    public void deleteTeamGroup(int groupId) throws IOException {
        deletePath("/api/team/groups/" + groupId);
    }

    public List<TeamModels.GroupMember> listTeamGroupUsers(int groupId) throws IOException {
        return TeamModels.parseGroupMembers(getJsonArray("/api/team/groups/" + groupId + "/users"));
    }

    public void modifyTeamGroupUsers(int groupId, TeamModels.ModifyGroupUsersRequest reqModel) throws IOException {
        postJson("/api/team/groups/" + groupId + "/users", reqModel.toJson());
    }

    // ---- EE Shares ----
    public java.util.List<ShareModels.ShareTarget> listShareTargets(@Nullable String query) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/ee/share-targets")).newBuilder();
        if (query != null && !query.trim().isEmpty()) hb.addQueryParameter("q", query.trim());
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "[]";
            JSONArray arr;
            try { arr = new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            java.util.ArrayList<ShareModels.ShareTarget> out = new java.util.ArrayList<>();
            for (int i = 0; i < arr.length(); i++) {
                JSONObject j = arr.optJSONObject(i);
                if (j != null) out.add(ShareModels.ShareTarget.fromJson(j));
            }
            return out;
        }
    }

    public JSONObject createShare(ShareModels.CreateShareRequest reqModel) throws IOException {
        return postJson("/api/ee/shares", reqModel.toJson());
    }

    public List<ShareModels.ShareItem> listOutgoingShares() throws IOException {
        return ShareModels.parseShareList(getJsonArray("/api/ee/shares/outgoing"));
    }

    public List<ShareModels.ShareItem> listReceivedShares() throws IOException {
        return ShareModels.parseShareList(getJsonArray("/api/ee/shares/received"));
    }

    public List<ShareModels.ShareItem> listShares() throws IOException {
        return ShareModels.parseShareList(getJsonArray("/api/ee/shares"));
    }

    public ShareModels.ShareItem getShare(String shareId) throws IOException {
        JSONObject j = getJsonObject("/api/ee/shares/" + encPath(shareId));
        return ShareModels.ShareItem.fromJson(j);
    }

    public ShareModels.ShareItem updateShare(String shareId, ShareModels.UpdateShareRequest reqModel) throws IOException {
        JSONObject j = patchJson("/api/ee/shares/" + encPath(shareId), reqModel.toJson());
        return ShareModels.ShareItem.fromJson(j);
    }

    public void deleteShare(String shareId) throws IOException {
        deletePath("/api/ee/shares/" + encPath(shareId));
    }

    public ShareModels.ShareItem addRecipients(String shareId, List<ShareModels.RecipientInput> recipients) throws IOException {
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (ShareModels.RecipientInput r : recipients) arr.put(r.toJson());
            body.put("recipients", arr);
        } catch (Exception ignored) {}
        JSONObject j = postJson("/api/ee/shares/" + encPath(shareId) + "/recipients", body);
        return ShareModels.ShareItem.fromJson(j);
    }

    public void removeRecipient(String shareId, String recipientId) throws IOException {
        deletePath("/api/ee/shares/" + encPath(shareId) + "/recipients/" + encPath(recipientId));
    }

    public ShareModels.ShareAssetsPage listShareAssets(String shareId, int page, int limit, @Nullable String sort) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/ee/shares/" + encPath(shareId) + "/assets")).newBuilder();
        hb.addQueryParameter("page", String.valueOf(Math.max(1, page)));
        hb.addQueryParameter("limit", String.valueOf(Math.max(1, Math.min(200, limit))));
        if (sort != null && !sort.isEmpty()) hb.addQueryParameter("sort", sort);
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "{}";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONObject j;
            try { j = new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return ShareModels.ShareAssetsPage.fromJson(j);
        }
    }

    public ShareModels.ShareAssetMetadata getShareAssetMetadata(String shareId, String assetId) throws IOException {
        JSONObject j = getJsonObject("/api/ee/shares/" + encPath(shareId) + "/assets/" + encPath(assetId));
        return ShareModels.ShareAssetMetadata.fromJson(j);
    }

    public byte[] getShareAssetThumbnailData(String shareId, String assetId) throws IOException {
        return getBytes("/api/ee/shares/" + encPath(shareId) + "/assets/" + encPath(assetId) + "/thumbnail");
    }

    public byte[] getShareAssetImageData(String shareId, String assetId) throws IOException {
        return getBytes("/api/ee/shares/" + encPath(shareId) + "/assets/" + encPath(assetId) + "/image");
    }

    public List<ShareModels.ShareFace> listShareFaces(String shareId, int top) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/ee/shares/" + encPath(shareId) + "/faces")).newBuilder();
        hb.addQueryParameter("top", String.valueOf(Math.max(1, Math.min(100, top))));
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "[]";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONArray arr;
            try { arr = new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return ShareModels.parseFaces(arr);
        }
    }

    public List<String> listShareFaceAssets(String shareId, String personId) throws IOException {
        JSONObject j = getJsonObject("/api/ee/shares/" + encPath(shareId) + "/faces/" + encPath(personId) + "/assets");
        JSONArray arr = j.optJSONArray("asset_ids");
        List<String> out = new ArrayList<>();
        if (arr != null) {
            for (int i = 0; i < arr.length(); i++) {
                String id = arr.optString(i, "");
                if (!id.isEmpty()) out.add(id);
            }
        }
        return out;
    }

    public byte[] getShareFaceThumbnailData(String shareId, String personId) throws IOException {
        return getBytes("/api/ee/shares/" + encPath(shareId) + "/faces/" + encPath(personId) + "/thumbnail");
    }

    public List<ShareModels.ShareComment> listShareComments(String shareId, String assetId, int limit, @Nullable Long before) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/ee/shares/" + encPath(shareId) + "/comments")).newBuilder();
        hb.addQueryParameter("asset_id", assetId);
        hb.addQueryParameter("limit", String.valueOf(Math.max(1, Math.min(200, limit))));
        if (before != null) hb.addQueryParameter("before", String.valueOf(before));
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "[]";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONArray arr;
            try { arr = new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return ShareModels.parseComments(arr);
        }
    }

    public ShareModels.ShareComment createShareComment(String shareId, String assetId, String bodyText) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("asset_id", assetId);
            body.put("body", bodyText);
        } catch (Exception ignored) {}
        JSONObject j = postJson("/api/ee/shares/" + encPath(shareId) + "/comments", body);
        return ShareModels.ShareComment.fromJson(j);
    }

    public void deleteShareComment(String shareId, String commentId) throws IOException {
        deletePath("/api/ee/shares/" + encPath(shareId) + "/comments/" + encPath(commentId));
    }

    public Map<String, ShareModels.ShareComment> latestShareCommentsByAssets(String shareId, List<String> assetIds) throws IOException {
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (String aid : assetIds) arr.put(aid);
            body.put("asset_ids", arr);
        } catch (Exception ignored) {}
        Request req = new Request.Builder()
                .url(url("/api/ee/shares/" + encPath(shareId) + "/comments/latest-by-assets"))
                .post(RequestBody.create(body.toString(), MediaType.parse("application/json")))
                .build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "[]";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONArray rows;
            try { rows = new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            Map<String, ShareModels.ShareComment> out = new HashMap<>();
            for (int i = 0; i < rows.length(); i++) {
                JSONObject row = rows.optJSONObject(i);
                if (row == null) continue;
                String aid = row.optString("asset_id", "");
                if (aid.isEmpty()) continue;
                JSONObject latest = row.optJSONObject("latest");
                out.put(aid, latest != null ? ShareModels.ShareComment.fromJson(latest) : null);
            }
            return out;
        }
    }

    public ShareModels.ShareLikeCount toggleShareLike(String shareId, String assetId, boolean like) throws IOException {
        JSONObject body = new JSONObject();
        try {
            body.put("asset_id", assetId);
            body.put("like", like);
        } catch (Exception ignored) {}
        JSONObject j = postJson("/api/ee/shares/" + encPath(shareId) + "/likes/toggle", body);
        return ShareModels.ShareLikeCount.fromJson(j);
    }

    public List<ShareModels.ShareLikeCount> shareLikeCountsByAssets(String shareId, List<String> assetIds) throws IOException {
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (String aid : assetIds) arr.put(aid);
            body.put("asset_ids", arr);
        } catch (Exception ignored) {}
        Request req = new Request.Builder()
                .url(url("/api/ee/shares/" + encPath(shareId) + "/likes/counts-by-assets"))
                .post(RequestBody.create(body.toString(), MediaType.parse("application/json")))
                .build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "[]";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONArray rows;
            try { rows = new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return ShareModels.parseLikeCounts(rows);
        }
    }

    public ShareModels.ImportResult importShareAssets(String shareId, List<String> assetIds) throws IOException {
        JSONObject body = new JSONObject();
        try {
            JSONArray arr = new JSONArray();
            for (String aid : assetIds) arr.put(aid);
            body.put("asset_ids", arr);
        } catch (Exception ignored) {}
        JSONObject j = postJson("/api/ee/shares/" + encPath(shareId) + "/import", body);
        return ShareModels.ImportResult.fromJson(j);
    }

    public JSONObject createPublicLink(ShareModels.CreatePublicLinkRequest reqModel) throws IOException {
        return postJson("/api/ee/public-links", reqModel.toJson());
    }

    public List<ShareModels.PublicLinkItem> listPublicLinks() throws IOException {
        return ShareModels.parsePublicLinks(getJsonArray("/api/ee/public-links"));
    }

    public ShareModels.PublicLinkItem updatePublicLink(String linkId, ShareModels.UpdatePublicLinkRequest reqModel) throws IOException {
        JSONObject j = patchJson("/api/ee/public-links/" + encPath(linkId), reqModel.toJson());
        return ShareModels.PublicLinkItem.fromJson(j);
    }

    public ShareModels.PublicLinkItem rotatePublicLinkKey(String linkId) throws IOException {
        JSONObject j = postJson("/api/ee/public-links/" + encPath(linkId) + "/rotate-key", new JSONObject());
        return ShareModels.PublicLinkItem.fromJson(j);
    }

    public void deletePublicLink(String linkId) throws IOException {
        deletePath("/api/ee/public-links/" + encPath(linkId));
    }

    // ---- EE share/public-link E2EE helpers ----
    public JSONObject setEeIdentityPubkey(String pubkeyB64) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("pubkey_b64", pubkeyB64); } catch (Exception ignored) {}
        return postJson("/api/ee/e2ee/identity/pubkey", body);
    }

    public JSONObject getEeIdentityPubkey(String userId) throws IOException {
        return getJsonObject("/api/ee/e2ee/identity/pubkey/" + encPath(userId));
    }

    public JSONObject uploadShareRecipientEnvelopes(String shareId, JSONArray items) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("items", items); } catch (Exception ignored) {}
        return postJson("/api/ee/shares/" + encPath(shareId) + "/e2ee/recipient-envelopes", body);
    }

    public JSONObject getMyShareSmkEnvelope(String shareId) throws IOException {
        return getJsonObject("/api/ee/shares/" + encPath(shareId) + "/e2ee/my-smk-envelope");
    }

    public JSONObject uploadShareWrapsBatch(String shareId, JSONArray items) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("items", items); } catch (Exception ignored) {}
        return postJson("/api/ee/shares/" + encPath(shareId) + "/e2ee/dek-wraps/batch", body);
    }

    public List<ShareModels.DekWrap> getShareWraps(String shareId, List<String> assetIds, @Nullable String variant) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/ee/shares/" + encPath(shareId) + "/e2ee/wraps")).newBuilder();
        hb.addQueryParameter("asset_ids", String.join(",", assetIds));
        if (variant != null && !variant.isEmpty()) hb.addQueryParameter("variant", variant);
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "{}";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            JSONObject j;
            try { j = new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
            return ShareModels.parseWraps(j.optJSONArray("items"));
        }
    }

    public JSONObject uploadPublicLinkSmkEnvelope(String linkId, JSONObject env) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("env", env); } catch (Exception ignored) {}
        return postJson("/api/ee/public-links/" + encPath(linkId) + "/e2ee/smk-envelope", body);
    }

    public JSONObject uploadPublicLinkWrapsBatch(String linkId, JSONArray items) throws IOException {
        JSONObject body = new JSONObject();
        try { body.put("items", items); } catch (Exception ignored) {}
        return postJson("/api/ee/public-links/" + encPath(linkId) + "/e2ee/dek-wraps/batch", body);
    }

    // ---- Faces/Persons ----
    public JSONArray getFacesForAsset(String assetId) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        return getJsonArray("/api/photos/" + enc + "/faces");
    }
    public JSONArray getPersons() throws IOException { return getJsonArray("/api/faces"); }

    /** Update person display name and/or birth date using PUT /api/faces/{personId}. */
    public void updatePerson(String personId, @Nullable String displayName, @Nullable String birthDate) throws IOException {
        FaceModels.UpdatePersonRequest reqModel = new FaceModels.UpdatePersonRequest();
        reqModel.displayName = displayName;
        reqModel.birthDate = birthDate;
        String enc = java.net.URLEncoder.encode(personId, java.nio.charset.StandardCharsets.UTF_8);
        putJson("/api/faces/" + enc, reqModel.toJson());
    }

    /** Merge source persons into target person using POST /api/faces/merge. */
    public void mergeFaces(String targetPersonId, List<String> sourcePersonIds) throws IOException {
        FaceModels.MergeFacesRequest reqModel = new FaceModels.MergeFacesRequest();
        reqModel.targetPersonId = targetPersonId;
        if (sourcePersonIds != null) reqModel.sourcePersonIds.addAll(sourcePersonIds);
        postJson("/api/faces/merge", reqModel.toJson());
    }

    /** Delete persons by person IDs using POST /api/faces/delete. Returns deleted count if present. */
    public int deletePersons(List<String> personIds) throws IOException {
        FaceModels.DeletePersonsRequest reqModel = new FaceModels.DeletePersonsRequest();
        if (personIds != null) reqModel.personIds.addAll(personIds);
        JSONObject out = postJson("/api/faces/delete", reqModel.toJson());
        return out.optInt("deleted", 0);
    }
    public JSONArray getPersonsForAsset(String assetId) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        return getJsonArray("/api/photos/" + enc + "/persons");
    }
    public void assignFace(String faceId, @Nullable String personId) throws IOException {
        String enc = java.net.URLEncoder.encode(faceId, java.nio.charset.StandardCharsets.UTF_8);
        JSONObject body = new JSONObject(); try { if (personId != null) body.put("person_id", personId); else body.put("person_id", JSONObject.NULL); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/faces/" + enc + "/assign")).put(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) { if (!r.isSuccessful()) throw new IOException("HTTP " + r.code()); }
    }
    public void addPersonToPhoto(String assetId, String personId) throws IOException {
        String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8);
        JSONObject body = new JSONObject(); try { body.put("person_id", personId); } catch (Exception ignored) {}
        Request req = new Request.Builder().url(url("/api/photos/" + enc + "/assign-person")).post(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) { if (!r.isSuccessful()) throw new IOException("HTTP " + r.code()); }
    }

    /** Build absolute image URL for a given asset ID. */
    public String imageUrl(String assetId) {
        try {
            String base = AuthManager.get(app).getServerUrl();
            String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8.name());
            return base + "/api/images/" + enc;
        } catch (Exception e) { return AuthManager.get(app).getServerUrl() + "/api/images/" + assetId; }
    }

    /** Build absolute thumbnail URL for a given asset ID. */
    public String thumbnailUrl(String assetId) {
        try {
            String base = AuthManager.get(app).getServerUrl();
            String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8.name());
            return base + "/api/thumbnails/" + enc;
        } catch (Exception e) { return AuthManager.get(app).getServerUrl() + "/api/thumbnails/" + assetId; }
    }

    /** Build absolute URL for Live photo motion video (unlocked). */
    public String liveUrl(String assetId) {
        try { String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8.name()); return AuthManager.get(app).getServerUrl() + "/api/live/" + enc; } catch (Exception e) { return AuthManager.get(app).getServerUrl() + "/api/live/" + assetId; }
    }
    /** Build absolute URL for Live photo motion video (locked PAE3). */
    public String liveLockedUrl(String assetId) {
        try { String enc = java.net.URLEncoder.encode(assetId, java.nio.charset.StandardCharsets.UTF_8.name()); return AuthManager.get(app).getServerUrl() + "/api/live-locked/" + enc; } catch (Exception e) { return AuthManager.get(app).getServerUrl() + "/api/live-locked/" + assetId; }
    }

    /** Face thumbnail URL builder (uses /api/face-thumbnail?personId=...). */
    public String faceThumbnailUrl(String personId) {
        try {
            String base = AuthManager.get(app).getServerUrl();
            String enc = java.net.URLEncoder.encode(personId, java.nio.charset.StandardCharsets.UTF_8.name());
            return base + "/api/face-thumbnail?personId=" + enc;
        } catch (Exception e) { return AuthManager.get(app).getServerUrl() + "/api/face-thumbnail?personId=" + personId; }
    }

    /** Buckets: list of years with counts and first_ts. */
    public JSONArray getYearBuckets() throws IOException { return getJsonArray("/api/buckets/years"); }

    /** Buckets: list of quarters (+first_ts) for a given year. */
    public JSONArray getQuarterBuckets(int year) throws IOException { return getJsonArray("/api/buckets/quarters?year=" + year); }

    

    private JSONArray getJsonArray(String path) throws IOException {
        Request req = new Request.Builder().url(url(path)).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String body = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) {
                try { android.util.Log.w("OpenPhotos", "[HTTP] getJsonArray fail " + r.code() + " url=" + path + " body=" + body); } catch (Exception ignored) {}
                throw new IOException("HTTP " + r.code() + (body.isEmpty()?"":" - "+body));
            }
            String s = body.isEmpty()?"[]":body;
            try { return new JSONArray(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    private JSONObject getJsonObject(String path) throws IOException {
        Request req = new Request.Builder().url(url(path)).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String body = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) {
                try { android.util.Log.w("OpenPhotos", "[HTTP] getJsonObject fail " + r.code() + " url=" + path + " body=" + body); } catch (Exception ignored) {}
                throw new IOException("HTTP " + r.code() + (body.isEmpty()?"":" - "+body));
            }
            String s = body.isEmpty()?"{}":body;
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    private JSONObject postJson(String path, JSONObject body) throws IOException {
        Request req = new Request.Builder().url(url(path)).post(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    private JSONObject putJson(String path, JSONObject body) throws IOException {
        Request req = new Request.Builder().url(url(path)).put(RequestBody.create(body.toString(), MediaType.parse("application/json"))).build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    private JSONObject patchJson(String path, JSONObject body) throws IOException {
        Request req = new Request.Builder()
                .url(url(path))
                .patch(RequestBody.create(body.toString(), MediaType.parse("application/json")))
                .build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "{}";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    private void deletePath(String path) throws IOException {
        Request req = new Request.Builder().url(url(path)).delete().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code() + (s.isEmpty() ? "" : (" - " + s)));
        }
    }

    private byte[] getBytes(String path) throws IOException {
        Request req = new Request.Builder().url(url(path)).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) {
                String body = r.body() != null ? r.body().string() : "";
                throw new IOException("HTTP " + r.code() + (body.isEmpty() ? "" : (" - " + body)));
            }
            return r.body() != null ? r.body().bytes() : new byte[0];
        }
    }

    /** List photos with filters using GET /api/photos. Returns full response object. */
    public JSONObject listPhotos(Integer albumId, String media, Boolean locked, int page, int limit) throws IOException {
        return listPhotos(albumId, null, media, locked, false, page, limit, null);
    }

    /** List photos with filters using GET /api/photos. Supports favorite-only flag + advanced filters. */
    public JSONObject listPhotos(Integer albumId, java.util.List<Integer> albumIds, String media, Boolean locked, boolean favoriteOnly, int page, int limit, FilterParams filters) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/photos")).newBuilder();
        if (albumIds != null && !albumIds.isEmpty()) {
            if (albumIds.size() == 1) hb.addQueryParameter("album_id", String.valueOf(albumIds.get(0)));
            else {
                String csv = albumIds.stream().map(String::valueOf).collect(java.util.stream.Collectors.joining(","));
                hb.addQueryParameter("album_ids", csv);
                hb.addQueryParameter("album_subtree", "true"); // legacy default for multi-select callers
            }
        } else if (albumId != null && albumId > 0) {
            hb.addQueryParameter("album_id", String.valueOf(albumId));
        }
        if (media != null) {
            if ("photos".equals(media)) hb.addQueryParameter("filter_is_video", "false");
            if ("videos".equals(media)) hb.addQueryParameter("filter_is_video", "true");
            if ("trash".equals(media)) hb.addQueryParameter("filter_trashed_only", "true");
        }
        if (locked != null) {
            hb.addQueryParameter("filter_locked_only", String.valueOf(locked));
            if (Boolean.TRUE.equals(locked)) hb.addQueryParameter("include_locked", "true");
        }
        if (favoriteOnly) hb.addQueryParameter("filter_favorite", "true");
        if (filters != null) filters.applyTo(hb);
        hb.addQueryParameter("page", String.valueOf(page));
        hb.addQueryParameter("limit", String.valueOf(limit));
        // Be explicit about sort to avoid backend defaults causing surprises
        hb.addQueryParameter("sort_by", "created_at");
        hb.addQueryParameter("sort_order", "DESC");
        okhttp3.HttpUrl urlBuilt = hb.build();
        Request req = new Request.Builder().url(urlBuilt).get().build();
        try { android.util.Log.i("OpenPhotos", "[PHOTOS] GET " + urlBuilt); } catch (Exception ignored) {}
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            String s = r.body() != null ? r.body().string() : "";
            if (!r.isSuccessful()) {
                try { android.util.Log.w("OpenPhotos", "[PHOTOS] list fail code="+r.code()+" body="+s); } catch (Exception ignored) {}
                throw new IOException("HTTP " + r.code() + (s.isEmpty()?"":" - "+s));
            }
            if (s.isEmpty()) s = "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /**
     * List photos with an explicit albumSubtree flag. When {@code albumSubtree==true},
     * adds {@code album_subtree=true} regardless of whether a single or multiple album
     * filter is used. When false or null, omits the flag entirely.
     */
    public JSONObject listPhotos(Integer albumId, java.util.List<Integer> albumIds, String media, Boolean locked, boolean favoriteOnly, int page, int limit, FilterParams filters, @Nullable Boolean albumSubtree) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/photos")).newBuilder();
        if (albumIds != null && !albumIds.isEmpty()) {
            if (albumIds.size() == 1) hb.addQueryParameter("album_id", String.valueOf(albumIds.get(0)));
            else {
                String csv = albumIds.stream().map(String::valueOf).collect(java.util.stream.Collectors.joining(","));
                hb.addQueryParameter("album_ids", csv);
            }
        } else if (albumId != null && albumId > 0) {
            hb.addQueryParameter("album_id", String.valueOf(albumId));
        }
        if (albumSubtree != null && albumSubtree) hb.addQueryParameter("album_subtree", "true");
        if (media != null) {
            if ("photos".equals(media)) hb.addQueryParameter("filter_is_video", "false");
            if ("videos".equals(media)) hb.addQueryParameter("filter_is_video", "true");
            if ("trash".equals(media)) hb.addQueryParameter("filter_trashed_only", "true");
        }
        if (locked != null) {
            hb.addQueryParameter("filter_locked_only", String.valueOf(locked));
            if (Boolean.TRUE.equals(locked)) hb.addQueryParameter("include_locked", "true");
        }
        if (favoriteOnly) hb.addQueryParameter("filter_favorite", "true");
        if (filters != null) filters.applyTo(hb);
        hb.addQueryParameter("page", String.valueOf(page));
        hb.addQueryParameter("limit", String.valueOf(limit));
        hb.addQueryParameter("sort_by", "created_at");
        hb.addQueryParameter("sort_order", "DESC");
        okhttp3.HttpUrl urlBuilt = hb.build();
        Request req = new Request.Builder().url(urlBuilt).get().build();
        try { android.util.Log.i("OpenPhotos", "[PHOTOS] GET " + urlBuilt); } catch (Exception ignored) {}
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Fetch media counts for segmented control (All/Photos/Videos), honoring filters like iOS/Web. */
    public JSONObject mediaCounts(boolean favoriteOnly) throws IOException {
        return mediaCounts(favoriteOnly, null, null, null, null);
    }

    public JSONObject mediaCounts(boolean favoriteOnly, String media, Boolean locked, java.util.List<Integer> albumIds, FilterParams filters) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/media/counts")).newBuilder();
        if (favoriteOnly) hb.addQueryParameter("filter_favorite", "true");
        if (media != null) {
            if ("photos".equals(media)) hb.addQueryParameter("filter_is_video", "false");
            if ("videos".equals(media)) hb.addQueryParameter("filter_is_video", "true");
            if ("trash".equals(media)) hb.addQueryParameter("filter_trashed_only", "true");
        }
        if (locked != null) {
            hb.addQueryParameter("filter_locked_only", String.valueOf(locked));
            if (Boolean.TRUE.equals(locked)) hb.addQueryParameter("include_locked", "true");
        }
        if (albumIds != null && !albumIds.isEmpty()) {
            if (albumIds.size() == 1) hb.addQueryParameter("album_id", String.valueOf(albumIds.get(0)));
            else {
                String csv = albumIds.stream().map(String::valueOf).collect(java.util.stream.Collectors.joining(","));
                hb.addQueryParameter("album_ids", csv);
                hb.addQueryParameter("album_subtree", "true"); // legacy default for multi-select callers
            }
        }
        if (filters != null) filters.applyTo(hb);
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }

    /** Counts with an explicit albumSubtree flag. */
    public JSONObject mediaCounts(boolean favoriteOnly, String media, Boolean locked, java.util.List<Integer> albumIds, FilterParams filters, @Nullable Boolean albumSubtree) throws IOException {
        okhttp3.HttpUrl.Builder hb = okhttp3.HttpUrl.parse(url("/api/media/counts")).newBuilder();
        if (favoriteOnly) hb.addQueryParameter("filter_favorite", "true");
        if (media != null) {
            if ("photos".equals(media)) hb.addQueryParameter("filter_is_video", "false");
            if ("videos".equals(media)) hb.addQueryParameter("filter_is_video", "true");
            if ("trash".equals(media)) hb.addQueryParameter("filter_trashed_only", "true");
        }
        if (locked != null) {
            hb.addQueryParameter("filter_locked_only", String.valueOf(locked));
            if (Boolean.TRUE.equals(locked)) hb.addQueryParameter("include_locked", "true");
        }
        if (albumIds != null && !albumIds.isEmpty()) {
            if (albumIds.size() == 1) hb.addQueryParameter("album_id", String.valueOf(albumIds.get(0)));
            else {
                String csv = albumIds.stream().map(String::valueOf).collect(java.util.stream.Collectors.joining(","));
                hb.addQueryParameter("album_ids", csv);
            }
        }
        if (albumSubtree != null && albumSubtree) hb.addQueryParameter("album_subtree", "true");
        if (filters != null) filters.applyTo(hb);
        Request req = new Request.Builder().url(hb.build()).get().build();
        try (Response r = AuthorizedHttpClient.get(app).raw().newCall(req).execute()) {
            if (!r.isSuccessful()) throw new IOException("HTTP " + r.code());
            String s = r.body() != null ? r.body().string() : "{}";
            try { return new JSONObject(s); } catch (Exception e) { throw new IOException("Bad JSON", e); }
        }
    }
}
