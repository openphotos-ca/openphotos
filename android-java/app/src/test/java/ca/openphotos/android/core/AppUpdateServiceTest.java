package ca.openphotos.android.core;

import org.junit.Test;

import java.util.Arrays;
import java.util.Collections;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class AppUpdateServiceTest {
    @Test
    public void normalizeReleaseVersionAcceptsVPrefix() {
        assertEquals("0.4.1", AppUpdateService.normalizeReleaseVersion("v0.4.1"));
        assertEquals("0.4.1", AppUpdateService.normalizeReleaseVersion("0.4.1"));
    }

    @Test(expected = IllegalArgumentException.class)
    public void normalizeReleaseVersionRejectsInvalidTag() {
        AppUpdateService.normalizeReleaseVersion("release-0.4.1");
    }

    @Test
    public void compareVersionsOrdersSemverLikeValues() {
        assertTrue(AppUpdateService.compareVersions("0.4.1", "0.4.0") > 0);
        assertEquals(0, AppUpdateService.compareVersions("0.4.0", "0.4.0"));
        assertTrue(AppUpdateService.compareVersions("0.4.0-beta.1", "0.4.0") < 0);
        assertTrue(AppUpdateService.compareVersions("0.5.0", "0.4.9") > 0);
    }

    @Test
    public void selectAndroidApkDownloadUrlMatchesOnlyCanonicalAsset() {
        Iterable<AppUpdateService.ReleaseAsset> assets = Arrays.asList(
                new AppUpdateService.ReleaseAsset(
                        "openphotos_0.4.1_amd64.deb",
                        "https://example.com/openphotos_0.4.1_amd64.deb"
                ),
                new AppUpdateService.ReleaseAsset(
                        "openphotos-android-release.apk",
                        "https://example.com/openphotos-android-release.apk"
                )
        );

        assertEquals(
                "https://example.com/openphotos-android-release.apk",
                AppUpdateService.selectAndroidApkDownloadUrlFromAssets(assets)
        );
    }

    @Test
    public void selectAndroidApkDownloadUrlReturnsNullWhenMissing() {
        assertNull(AppUpdateService.selectAndroidApkDownloadUrlFromAssets(Collections.emptyList()));
    }

    @Test
    public void cacheFreshnessHonorsTwentyFourHourTtl() {
        long now = 100L * 60L * 60L * 1000L;
        assertTrue(AppUpdateService.isCacheFresh(now - (60L * 60L * 1000L), now));
        assertFalse(AppUpdateService.isCacheFresh(now - (25L * 60L * 60L * 1000L), now));
        assertFalse(AppUpdateService.isCacheFresh(0L, now));
    }
}
