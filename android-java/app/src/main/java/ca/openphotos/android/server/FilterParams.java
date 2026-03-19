package ca.openphotos.android.server;

import android.os.Parcel;
import android.os.Parcelable;

import okhttp3.HttpUrl;

import java.util.LinkedHashSet;
import java.util.Set;

/**
 * Filter parameters for /api/photos and /api/media/counts.
 * Matches server query keys and mirrors iOS/Web semantics.
 * Parcelable so it can be passed between fragments.
 */
public class FilterParams implements Parcelable {
    public final Set<String> faces = new LinkedHashSet<>(); // person_id values
    public Long dateFrom; // seconds since epoch (start-of-day)
    public Long dateTo;   // seconds since epoch (inclusive end-of-day)
    public boolean screenshots;
    public boolean livePhotos;
    public Integer ratingMin; // 1..5 or null
    @androidx.annotation.Nullable public String facesMode; // "all" (default backend) or "any"
    // Location selections (UI-only for now; not applied to query)
    public String country;
    public String region;
    public String city;

    public FilterParams() {}

    // Copy constructor
    public FilterParams(FilterParams other) {
        if (other == null) return;
        this.faces.addAll(other.faces);
        this.dateFrom = other.dateFrom;
        this.dateTo = other.dateTo;
        this.screenshots = other.screenshots;
        this.livePhotos = other.livePhotos;
        this.ratingMin = other.ratingMin;
        this.facesMode = other.facesMode;
        this.country = other.country;
        this.region = other.region;
        this.city = other.city;
    }

    /** Apply non-null filters to an HttpUrl builder as query parameters. */
    public void applyTo(HttpUrl.Builder hb) {
        if (dateFrom != null && dateFrom > 0) hb.addQueryParameter("filter_date_from", String.valueOf(dateFrom));
        if (dateTo != null && dateTo > 0) hb.addQueryParameter("filter_date_to", String.valueOf(dateTo));
        if (screenshots) hb.addQueryParameter("filter_screenshot", "true");
        if (livePhotos) hb.addQueryParameter("filter_live_photo", "true");
        if (ratingMin != null && ratingMin > 0) hb.addQueryParameter("filter_rating_min", String.valueOf(Math.min(5, Math.max(1, ratingMin))));
        if (!faces.isEmpty()) {
            hb.addQueryParameter("filter_faces", String.join(",", faces)); // AND semantics by default
            if (facesMode != null && !facesMode.trim().isEmpty()) hb.addQueryParameter("filter_faces_mode", facesMode.trim());
        }
        // Country/City/Province are UI-only in this Android pass per spec
    }

    // Parcelable
    protected FilterParams(Parcel in) {
        int n = in.readInt();
        for (int i=0;i<n;i++) faces.add(in.readString());
        if (in.readByte() == 1) dateFrom = in.readLong();
        if (in.readByte() == 1) dateTo = in.readLong();
        screenshots = in.readByte() == 1;
        livePhotos = in.readByte() == 1;
        if (in.readByte() == 1) ratingMin = in.readInt();
        facesMode = in.readString();
        country = in.readString();
        region = in.readString();
        city = in.readString();
    }

    @Override public void writeToParcel(Parcel dest, int flags) {
        dest.writeInt(faces.size());
        for (String f : faces) dest.writeString(f);
        if (dateFrom != null) { dest.writeByte((byte)1); dest.writeLong(dateFrom); } else { dest.writeByte((byte)0); }
        if (dateTo != null) { dest.writeByte((byte)1); dest.writeLong(dateTo); } else { dest.writeByte((byte)0); }
        dest.writeByte((byte)(screenshots ? 1 : 0));
        dest.writeByte((byte)(livePhotos ? 1 : 0));
        if (ratingMin != null) { dest.writeByte((byte)1); dest.writeInt(ratingMin); } else { dest.writeByte((byte)0); }
        dest.writeString(facesMode);
        dest.writeString(country);
        dest.writeString(region);
        dest.writeString(city);
    }

    @Override public int describeContents() { return 0; }
    public static final Creator<FilterParams> CREATOR = new Creator<>() {
        @Override public FilterParams createFromParcel(Parcel in) { return new FilterParams(in); }
        @Override public FilterParams[] newArray(int size) { return new FilterParams[size]; }
    };
}
