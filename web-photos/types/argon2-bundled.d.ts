declare module 'argon2-browser/dist/argon2-bundled.min.js' {
  const argon2: {
    ArgonType: { Argon2d: number; Argon2i: number; Argon2id: number };
    hash: (params: any) => Promise<{ hash: Uint8Array; hashHex: string; encoded: string }>;
    verify: (params: any) => Promise<{ hash: Uint8Array; hashHex: string; encoded: string }>;
  };
  export default argon2;
}

