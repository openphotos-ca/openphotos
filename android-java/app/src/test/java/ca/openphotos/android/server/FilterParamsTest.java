package ca.openphotos.android.server;

import org.junit.Test;

import okhttp3.HttpUrl;

import static org.junit.Assert.assertEquals;

public class FilterParamsTest {
    @Test
    public void applyToIncludesLocationFilters() {
        FilterParams filters = new FilterParams();
        filters.country = " Canada ";
        filters.region = " Ontario ";
        filters.city = " Toronto ";

        HttpUrl.Builder builder = HttpUrl.parse("https://example.test/api/photos").newBuilder();
        filters.applyTo(builder);
        HttpUrl url = builder.build();

        assertEquals("Canada", url.queryParameter("filter_country"));
        assertEquals("Ontario", url.queryParameter("filter_province"));
        assertEquals("Toronto", url.queryParameter("filter_city"));
    }
}
