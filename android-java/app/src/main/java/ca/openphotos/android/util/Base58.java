package ca.openphotos.android.util;

/**
 * Minimal Base58 encoder (Bitcoin alphabet) used for content_id and asset_id encoding.
 */
public final class Base58 {
    private static final char[] ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz".toCharArray();

    private Base58() {}

    public static String encode(byte[] input) {
        if (input.length == 0) return "";
        // Count leading zeros.
        int zeros = 0;
        while (zeros < input.length && input[zeros] == 0) zeros++;
        // Convert base-256 digits to base-58 digits (plus conversion to ASCII characters)
        input = input.clone();
        int size = input.length * 2;
        char[] encoded = new char[size];
        int outputStart = size;
        int inputStart = zeros;
        while (inputStart < input.length) {
            int mod = divmod58(input, inputStart);
            if (input[inputStart] == 0) inputStart++;
            encoded[--outputStart] = ALPHABET[mod];
        }
        // Add as many leading '1' as there were leading zeros.
        while (outputStart < size && encoded[outputStart] == ALPHABET[0]) outputStart++;
        while (--zeros >= 0) encoded[--outputStart] = ALPHABET[0];
        return new String(encoded, outputStart, size - outputStart);
    }

    private static int divmod58(byte[] number, int startAt) {
        int remainder = 0;
        for (int i = startAt; i < number.length; i++) {
            int digit256 = number[i] & 0xFF;
            int temp = remainder * 256 + digit256;
            number[i] = (byte) (temp / 58);
            remainder = temp % 58;
        }
        return remainder;
    }
}

