package ca.openphotos.android.server;

import androidx.annotation.Nullable;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

/** Request/response models for face/person management APIs. */
public final class FaceModels {
    private FaceModels() {}

    @Nullable
    private static String optStringOrNull(@Nullable JSONObject j, @Nullable String key) {
        if (j == null || key == null || !j.has(key) || j.isNull(key)) return null;
        String s = j.optString(key, null);
        if (s == null) return null;
        String t = s.trim();
        return t.isEmpty() ? null : t;
    }

    public static final class Person {
        public final String personId;
        @Nullable public final String displayName;
        @Nullable public final String birthDate;
        public final int faceCount;
        public final int photoCount;

        public Person(
                String personId,
                @Nullable String displayName,
                @Nullable String birthDate,
                int faceCount,
                int photoCount
        ) {
            this.personId = personId;
            this.displayName = displayName;
            this.birthDate = birthDate;
            this.faceCount = faceCount;
            this.photoCount = photoCount;
        }

        public String label() {
            if (displayName != null && !displayName.trim().isEmpty()) return displayName.trim();
            return personId;
        }

        public static Person fromJson(@Nullable JSONObject j) {
            if (j == null) {
                return new Person("", null, null, 0, 0);
            }
            int faceCount = j.optInt("face_count", 0);
            int photoCount = j.optInt("photo_count", faceCount);
            return new Person(
                    j.optString("person_id", ""),
                    optStringOrNull(j, "display_name"),
                    optStringOrNull(j, "birth_date"),
                    faceCount,
                    photoCount
            );
        }
    }

    public static final class MergeFacesRequest {
        public String targetPersonId;
        public final List<String> sourcePersonIds = new ArrayList<>();

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                j.put("target_person_id", targetPersonId);
                JSONArray arr = new JSONArray();
                for (String id : sourcePersonIds) {
                    if (id == null || id.trim().isEmpty()) continue;
                    arr.put(id.trim());
                }
                j.put("source_person_ids", arr);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class UpdatePersonRequest {
        @Nullable public String displayName;
        @Nullable public String birthDate;

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                if (displayName != null) j.put("display_name", displayName);
                if (birthDate != null) j.put("birth_date", birthDate);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static final class DeletePersonsRequest {
        public final List<String> personIds = new ArrayList<>();

        public JSONObject toJson() {
            JSONObject j = new JSONObject();
            try {
                JSONArray arr = new JSONArray();
                for (String id : personIds) {
                    if (id == null || id.trim().isEmpty()) continue;
                    arr.put(id.trim());
                }
                j.put("person_ids", arr);
            } catch (Exception ignored) {}
            return j;
        }
    }

    public static List<Person> parsePersons(@Nullable JSONArray arr) {
        List<Person> list = new ArrayList<>();
        if (arr == null) return list;
        for (int i = 0; i < arr.length(); i++) {
            JSONObject j = arr.optJSONObject(i);
            if (j == null) continue;
            Person p = Person.fromJson(j);
            if (p.personId == null || p.personId.trim().isEmpty()) continue;
            list.add(p);
        }
        return list;
    }
}
