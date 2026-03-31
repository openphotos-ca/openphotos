package ca.openphotos.android.upload;

import org.junit.Test;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class TusAdaptiveChunkControllerTest {
    @Test
    public void largeWifiUploadStartsAtOneMiBAndGrowsToTwoMiB() {
        TusAdaptiveChunkController controller =
                TusAdaptiveChunkController.forUpload(95L * TusAdaptiveChunkController.MIB, 1 * TusAdaptiveChunkController.MIB);

        assertEquals(1 * TusAdaptiveChunkController.MIB, controller.currentChunkBytes());
        assertEquals(2 * TusAdaptiveChunkController.MIB, controller.maxChunkBytes());

        for (int i = 0; i < 4; i++) {
            controller.recordSuccess();
        }

        assertEquals(2 * TusAdaptiveChunkController.MIB, controller.currentChunkBytes());
    }

    @Test
    public void mediumWifiUploadStartsAtHalfMiB() {
        TusAdaptiveChunkController controller =
                TusAdaptiveChunkController.forUpload(24L * TusAdaptiveChunkController.MIB, 1 * TusAdaptiveChunkController.MIB);

        assertEquals(512 * TusAdaptiveChunkController.KIB, controller.currentChunkBytes());
        assertEquals(1 * TusAdaptiveChunkController.MIB, controller.maxChunkBytes());
    }

    @Test
    public void cellularCapKeepsLargeUploadSmall() {
        TusAdaptiveChunkController controller =
                TusAdaptiveChunkController.forUpload(95L * TusAdaptiveChunkController.MIB, 256 * TusAdaptiveChunkController.KIB);

        assertEquals(256 * TusAdaptiveChunkController.KIB, controller.currentChunkBytes());
        assertEquals(512 * TusAdaptiveChunkController.KIB, controller.maxChunkBytes());
    }

    @Test
    public void recoveryMissHalvesChunkUntilFloor() {
        TusAdaptiveChunkController controller =
                TusAdaptiveChunkController.forUpload(95L * TusAdaptiveChunkController.MIB, 1 * TusAdaptiveChunkController.MIB);

        assertEquals(512 * TusAdaptiveChunkController.KIB, controller.recordRecoveryMiss());
        assertEquals(256 * TusAdaptiveChunkController.KIB, controller.recordRecoveryMiss());
        assertEquals(256 * TusAdaptiveChunkController.KIB, controller.recordRecoveryMiss());
        assertTrue(controller.canAttemptRecovery());
    }
}
