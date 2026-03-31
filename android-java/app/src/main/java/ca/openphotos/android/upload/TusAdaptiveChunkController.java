package ca.openphotos.android.upload;

final class TusAdaptiveChunkController {
    static final int KIB = 1024;
    static final int MIB = 1024 * KIB;
    static final int MIN_CHUNK_BYTES = 256 * KIB;

    private static final long MEDIUM_FILE_THRESHOLD_BYTES = 16L * MIB;
    private static final long LARGE_FILE_THRESHOLD_BYTES = 64L * MIB;
    private static final int SMALL_INITIAL_CHUNK_BYTES = MIN_CHUNK_BYTES;
    private static final int MEDIUM_INITIAL_CHUNK_BYTES = 512 * KIB;
    private static final int LARGE_INITIAL_CHUNK_BYTES = 1 * MIB;
    private static final int SMALL_MAX_CHUNK_BYTES = 512 * KIB;
    private static final int MEDIUM_MAX_CHUNK_BYTES = 1 * MIB;
    private static final int LARGE_MAX_CHUNK_BYTES = 2 * MIB;
    private static final int GROWTH_STREAK_THRESHOLD = 4;

    private final int minChunkBytes;
    private final int maxChunkBytes;
    private final int maxRecoveryAttempts;
    private int currentChunkBytes;
    private int stableSuccessStreak;
    private int recoveryMisses;

    private TusAdaptiveChunkController(int currentChunkBytes, int minChunkBytes, int maxChunkBytes, int maxRecoveryAttempts) {
        this.currentChunkBytes = currentChunkBytes;
        this.minChunkBytes = minChunkBytes;
        this.maxChunkBytes = maxChunkBytes;
        this.maxRecoveryAttempts = maxRecoveryAttempts;
    }

    static TusAdaptiveChunkController forUpload(long fileSizeBytes, int requestedInitialChunkBytes) {
        int requested = Math.max(MIN_CHUNK_BYTES, requestedInitialChunkBytes);
        int profileInitial;
        int profileMax;
        int recoveryBudget;

        if (fileSizeBytes >= LARGE_FILE_THRESHOLD_BYTES) {
            profileInitial = LARGE_INITIAL_CHUNK_BYTES;
            profileMax = LARGE_MAX_CHUNK_BYTES;
            recoveryBudget = 6;
        } else if (fileSizeBytes >= MEDIUM_FILE_THRESHOLD_BYTES) {
            profileInitial = MEDIUM_INITIAL_CHUNK_BYTES;
            profileMax = MEDIUM_MAX_CHUNK_BYTES;
            recoveryBudget = 5;
        } else {
            profileInitial = SMALL_INITIAL_CHUNK_BYTES;
            profileMax = SMALL_MAX_CHUNK_BYTES;
            recoveryBudget = 4;
        }

        int start = Math.min(profileInitial, requested);
        int max = Math.max(start, Math.min(profileMax, Math.max(requested, MIN_CHUNK_BYTES) * 2));
        return new TusAdaptiveChunkController(start, MIN_CHUNK_BYTES, max, recoveryBudget);
    }

    int currentChunkBytes() {
        return currentChunkBytes;
    }

    int maxChunkBytes() {
        return maxChunkBytes;
    }

    int recoveryMisses() {
        return recoveryMisses;
    }

    int maxRecoveryAttempts() {
        return maxRecoveryAttempts;
    }

    boolean canAttemptRecovery() {
        return recoveryMisses < maxRecoveryAttempts;
    }

    int recordSuccess() {
        stableSuccessStreak++;
        if (stableSuccessStreak >= GROWTH_STREAK_THRESHOLD && currentChunkBytes < maxChunkBytes) {
            currentChunkBytes = Math.min(maxChunkBytes, currentChunkBytes * 2);
            stableSuccessStreak = 0;
        }
        return currentChunkBytes;
    }

    void recordRecoveredProgress() {
        stableSuccessStreak = 0;
    }

    int recordRecoveryMiss() {
        recoveryMisses++;
        stableSuccessStreak = 0;
        currentChunkBytes = Math.max(minChunkBytes, currentChunkBytes / 2);
        return currentChunkBytes;
    }
}
