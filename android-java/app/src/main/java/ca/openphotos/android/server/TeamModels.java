package ca.openphotos.android.server;

import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/** Request/response models for enterprise Users & Groups flows. */
public final class TeamModels {
    private TeamModels() {}

    @Nullable
    private static String optStringOrNull(@Nullable JSONObject j, @Nullable String key) {
        if (j == null || key == null || !j.has(key) || j.isNull(key)) return null;
        String s = j.optString(key, null);
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    @Nullable
    public static String firstNonEmpty(@Nullable String... values) {
        if (values == null) return null;
        for (String value : values) {
            if (value == null) continue;
            String t = value.trim();
            if (!t.isEmpty()) return t;
        }
        return null;
    }

    public static final class TeamUser {
        public final int id;
        public final String userId;
        public final String name;
        @Nullable public final String email;
        public final String role;
        public final String status;
        public final long mediaCount;
        public final long storageBytes;
        public final boolean isCreator;

        public TeamUser(
                int id,
                String userId,
                String name,
                @Nullable String email,
                String role,
                String status,
                long mediaCount,
                long storageBytes,
                boolean isCreator
        ) {
            this.id = id;
            this.userId = userId;
            this.name = name;
            this.email = email;
            this.role = role;
            this.status = status;
            this.mediaCount = mediaCount;
            this.storageBytes = storageBytes;
            this.isCreator = isCreator;
        }

        @Nullable
        public String friendlyLabel() {
            return firstNonEmpty(name, email, userId);
        }

        public static TeamUser fromJson(JSONObject j) {
            return new TeamUser(
                    j.optInt("id", 0),
                    j.optString("user_id", ""),
                    j.optString("name", ""),
                    optStringOrNull(j, "email"),
                    j.optString("role", "regular"),
                    j.optString("status", "active"),
                    j.optLong("media_count", 0L),
                    j.optLong("storage_bytes", 0L),
                    j.optBoolean("is_creator", false)
            );
        }
    }

    public static final class TeamGroup {
        public final int id;
        public final String name;
        @Nullable public final String description;

        public TeamGroup(int id, String name, @Nullable String description) {
            this.id = id;
            this.name = name;
            this.description = description;
        }

        public static TeamGroup fromJson(JSONObject j) {
            return new TeamGroup(
                    j.optInt("id", 0),
                    j.optString("name", ""),
                    optStringOrNull(j, "description")
            );
        }
    }

    public static final class GroupMember {
        public final String userId;
        public final String name;
        @Nullable public final String email;
        public final String role;

        public GroupMember(String userId, String name, @Nullable String email, String role) {
            this.userId = userId;
            this.name = name;
            this.email = email;
            this.role = role;
        }

        @Nullable
        public String friendlyLabel() {
            return firstNonEmpty(name, email, userId);
        }

        public static GroupMember fromJson(JSONObject j) {
            return new GroupMember(
                    j.optString("user_id", ""),
                    j.optString("name", ""),
                    optStringOrNull(j, "email"),
                    j.optString("role", "regular")
            );
        }
    }

    public static final class OrgInfo {
        public final int id;
        public final String name;
        public final String creatorUserId;

        public OrgInfo(int id, String name, String creatorUserId) {
            this.id = id;
            this.name = name;
            this.creatorUserId = creatorUserId;
        }

        public static OrgInfo fromJson(JSONObject j) {
            return new OrgInfo(
                    j.optInt("id", 0),
                    j.optString("name", ""),
                    j.optString("creator_user_id", "")
            );
        }
    }

    public static final class CreateTeamUserRequest {
        public String email;
        public String name;
        @Nullable public String role;
        public String initialPassword;
        @Nullable public Boolean mustChangePassword;
        @Nullable public List<Integer> groups;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("email", email);
                j.put("name", name);
                if (role != null) j.put("role", role);
                j.put("initial_password", initialPassword);
                if (mustChangePassword != null) j.put("must_change_password", mustChangePassword);
                if (groups != null && !groups.isEmpty()) {
                    JSONArray arr = new JSONArray();
                    for (Integer id : groups) {
                        if (id != null) arr.put(id);
                    }
                    j.put("groups", arr);
                }
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdateTeamUserRequest {
        @Nullable public String name;
        @Nullable public String role;
        @Nullable public String status;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (name != null) j.put("name", name);
                if (role != null) j.put("role", role);
                if (status != null) j.put("status", status);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class ResetPasswordRequest {
        public String newPassword;
        @Nullable public String currentPassword;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("new_password", newPassword);
                if (currentPassword != null) j.put("current_password", currentPassword);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class CreateGroupRequest {
        public String name;
        @Nullable public String description;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("name", name);
                if (description != null) j.put("description", description);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdateGroupRequest {
        @Nullable public String name;
        @Nullable public String description;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (name != null) j.put("name", name);
                if (description != null) j.put("description", description);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class ModifyGroupUsersRequest {
        @Nullable public List<String> add;
        @Nullable public List<String> remove;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (add != null && !add.isEmpty()) {
                    JSONArray arr = new JSONArray();
                    for (String id : add) {
                        if (id != null && !id.trim().isEmpty()) arr.put(id.trim());
                    }
                    j.put("add", arr);
                }
                if (remove != null && !remove.isEmpty()) {
                    JSONArray arr = new JSONArray();
                    for (String id : remove) {
                        if (id != null && !id.trim().isEmpty()) arr.put(id.trim());
                    }
                    j.put("remove", arr);
                }
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdateOrgRequest {
        public String name;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try { j.put("name", name); } catch (Exception ignored) {}
            return j;
        }
    }

    public static List<TeamUser> parseUsers(@Nullable JSONArray arr) {
        if (arr == null || arr.length() == 0) return new ArrayList<>();
        ArrayList<TeamUser> out = new ArrayList<>(arr.length());
        for (int i = 0; i < arr.length(); i++) {
            JSONObject item = arr.optJSONObject(i);
            if (item != null) out.add(TeamUser.fromJson(item));
        }
        return out;
    }

    public static List<TeamGroup> parseGroups(@Nullable JSONArray arr) {
        if (arr == null || arr.length() == 0) return new ArrayList<>();
        ArrayList<TeamGroup> out = new ArrayList<>(arr.length());
        for (int i = 0; i < arr.length(); i++) {
            JSONObject item = arr.optJSONObject(i);
            if (item != null) out.add(TeamGroup.fromJson(item));
        }
        return out;
    }

    public static List<GroupMember> parseGroupMembers(@Nullable JSONArray arr) {
        if (arr == null || arr.length() == 0) return new ArrayList<>();
        ArrayList<GroupMember> out = new ArrayList<>(arr.length());
        for (int i = 0; i < arr.length(); i++) {
            JSONObject item = arr.optJSONObject(i);
            if (item != null) out.add(GroupMember.fromJson(item));
        }
        return out;
    }
}
