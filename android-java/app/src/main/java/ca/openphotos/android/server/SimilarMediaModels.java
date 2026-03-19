package ca.openphotos.android.server;

import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** Models for /api/similar/groups and /api/video/similar/groups. */
public final class SimilarMediaModels {
    private SimilarMediaModels() {}

    public static final class SimilarGroup {
        public final String representative;
        public final int count;
        public final List<String> members;

        public SimilarGroup(String representative, int count, List<String> members) {
            this.representative = representative;
            this.count = count;
            this.members = members;
        }
    }

    public static final class AssetMeta {
        @Nullable public final String mimeType;
        public final long size;
        public final long createdAt;

        public AssetMeta(@Nullable String mimeType, long size, long createdAt) {
            this.mimeType = mimeType;
            this.size = size;
            this.createdAt = createdAt;
        }
    }

    public static final class GroupsResponse {
        public final int totalGroups;
        public final List<SimilarGroup> groups;
        @Nullable public final Integer nextCursor;
        public final Map<String, AssetMeta> metadata;

        public GroupsResponse(
                int totalGroups,
                List<SimilarGroup> groups,
                @Nullable Integer nextCursor,
                Map<String, AssetMeta> metadata
        ) {
            this.totalGroups = totalGroups;
            this.groups = groups;
            this.nextCursor = nextCursor;
            this.metadata = metadata;
        }
    }

    public static GroupsResponse parseGroupsResponse(@Nullable JSONObject j) {
        if (j == null) {
            return new GroupsResponse(0, new ArrayList<>(), null, new HashMap<>());
        }

        List<SimilarGroup> groups = new ArrayList<>();
        JSONArray ga = j.optJSONArray("groups");
        if (ga != null) {
            for (int i = 0; i < ga.length(); i++) {
                JSONObject g = ga.optJSONObject(i);
                if (g == null) continue;
                String representative = g.optString("representative", "");
                int count = g.optInt("count", 0);
                List<String> members = new ArrayList<>();
                JSONArray ma = g.optJSONArray("members");
                if (ma != null) {
                    for (int k = 0; k < ma.length(); k++) {
                        String id = ma.optString(k, "");
                        if (id != null && !id.trim().isEmpty()) members.add(id);
                    }
                }
                groups.add(new SimilarGroup(representative, count, members));
            }
        }

        Map<String, AssetMeta> metadata = new HashMap<>();
        JSONObject mo = j.optJSONObject("metadata");
        if (mo != null) {
            JSONArray names = mo.names();
            if (names != null) {
                for (int i = 0; i < names.length(); i++) {
                    String key = names.optString(i, "");
                    if (key == null || key.isEmpty()) continue;
                    JSONObject m = mo.optJSONObject(key);
                    if (m == null) continue;
                    String mime = m.has("mime_type") && !m.isNull("mime_type") ? m.optString("mime_type", null) : null;
                    long size = m.optLong("size", 0L);
                    long created = m.optLong("created_at", 0L);
                    metadata.put(key, new AssetMeta(mime, size, created));
                }
            }
        }

        Integer next = null;
        if (j.has("next_cursor") && !j.isNull("next_cursor")) {
            next = j.optInt("next_cursor");
        }

        return new GroupsResponse(
                j.optInt("total_groups", groups.size()),
                groups,
                next,
                metadata
        );
    }
}
