package ca.openphotos.android.core;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class AuthManagerNetworkRoutingTest {
    @Test
    public void initialResolvedBaseUrlPrefersPublicWhenAutoSwitchEnabled() {
        String resolved = AuthManager.initialResolvedBaseUrl(
                "https://example.openphotos.ca",
                "http://192.168.2.249:3003",
                true,
                AuthManager.ManualPreferredEndpoint.LOCAL
        );

        assertEquals("https://example.openphotos.ca", resolved);
    }

    @Test
    public void initialResolvedBaseUrlFallsBackToLocalWhenPublicMissing() {
        String resolved = AuthManager.initialResolvedBaseUrl(
                "",
                "http://192.168.2.249:3003",
                true,
                AuthManager.ManualPreferredEndpoint.PUBLIC
        );

        assertEquals("http://192.168.2.249:3003", resolved);
    }

    @Test
    public void manualResolvedBaseUrlUsesManualPreference() {
        String resolved = AuthManager.manualResolvedBaseUrl(
                "https://example.openphotos.ca",
                "http://192.168.2.249:3003",
                AuthManager.ManualPreferredEndpoint.LOCAL
        );

        assertEquals("http://192.168.2.249:3003", resolved);
    }

    @Test
    public void endpointTypeMatchesConfiguredEndpoints() {
        assertEquals(
                AuthManager.ActiveEndpoint.LOCAL,
                AuthManager.endpointType(
                        "http://192.168.2.249:3003",
                        "https://example.openphotos.ca",
                        "http://192.168.2.249:3003"
                )
        );
        assertEquals(
                AuthManager.ActiveEndpoint.PUBLIC,
                AuthManager.endpointType(
                        "https://example.openphotos.ca",
                        "https://example.openphotos.ca",
                        "http://192.168.2.249:3003"
                )
        );
    }

    @Test
    public void buildBaseUrlDoesNotForceDefaultPort() {
        AuthManager.ParsedBaseUrl parsed = AuthManager.parseBaseUrl("https://example.openphotos.ca");

        assertEquals("https", parsed.scheme);
        assertEquals("example.openphotos.ca", parsed.host);
        assertEquals(null, parsed.port);
        assertEquals(
                "https://example.openphotos.ca",
                AuthManager.buildBaseUrl(parsed.scheme, parsed.host, parsed.port)
        );
    }

    @Test
    public void repartitionConfiguredBaseUrlsMovesLocalHostsIntoLocalBucket() {
        AuthManager.ConfiguredBaseUrls configured = AuthManager.repartitionConfiguredBaseUrls(
                "http://localhost:3003",
                "http://192.168.2.249:3003"
        );

        assertEquals("", configured.publicBaseUrl);
        assertEquals("http://192.168.2.249:3003", configured.localBaseUrl);
    }

    @Test
    public void repartitionConfiguredBaseUrlsSwapsMisfiledUrls() {
        AuthManager.ConfiguredBaseUrls configured = AuthManager.repartitionConfiguredBaseUrls(
                "http://192.168.2.249:3003",
                "https://example.openphotos.ca"
        );

        assertEquals("https://example.openphotos.ca", configured.publicBaseUrl);
        assertEquals("http://192.168.2.249:3003", configured.localBaseUrl);
    }

    @Test
    public void shouldRejectLoopbackServerAlways() {
        assertTrue(AuthManager.shouldRejectLoopbackServer("http://localhost:3003"));
    }

    @Test
    public void parseBaseUrlRejectsPartialNumericIpv4Host() {
        assertNull(AuthManager.parseBaseUrl("http://192.:443"));
        assertNull(AuthManager.parseBaseUrl("http://192:443"));
    }

    @Test
    public void buildBaseUrlRejectsPartialNumericIpv4Host() {
        assertNull(AuthManager.buildBaseUrl("http", "192.", 443));
        assertNull(AuthManager.buildBaseUrl("http", "192", 443));
    }

    @Test
    public void parseBaseUrlRejectsInvalidHostnameCharacters() {
        assertNull(AuthManager.parseBaseUrl("http://192.168':3003"));
        assertNull(AuthManager.parseBaseUrl("http://exa_mple.openphotos.ca"));
    }

    @Test
    public void buildBaseUrlRejectsInvalidHostnameCharacters() {
        assertNull(AuthManager.buildBaseUrl("http", "192.168'", 3003));
        assertNull(AuthManager.buildBaseUrl("https", "exa_mple.openphotos.ca", 443));
    }

    @Test
    public void repartitionConfiguredBaseUrlsDropsMalformedPublicUrl() {
        AuthManager.ConfiguredBaseUrls configured = AuthManager.repartitionConfiguredBaseUrls(
                "http://192.:443",
                "http://192.168.2.254:3003"
        );

        assertEquals("", configured.publicBaseUrl);
        assertEquals("http://192.168.2.254:3003", configured.localBaseUrl);
    }

    @Test
    public void repartitionConfiguredBaseUrlsDropsInvalidCharacterPublicUrl() {
        AuthManager.ConfiguredBaseUrls configured = AuthManager.repartitionConfiguredBaseUrls(
                "http://192.168':3003",
                "http://192.168.2.254:3003"
        );

        assertEquals("", configured.publicBaseUrl);
        assertEquals("http://192.168.2.254:3003", configured.localBaseUrl);
    }
}
