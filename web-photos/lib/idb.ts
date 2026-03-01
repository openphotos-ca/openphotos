// Minimal IndexedDB helpers for storing E2EE envelope ciphertext locally

const DB_NAME = 'albumbud_e2ee';
const DB_VERSION = 1;
const STORE = 'kvs';

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, DB_VERSION);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) {
        db.createObjectStore(STORE);
      }
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error || new Error('indexedDB open failed'));
  });
}

export async function idbGet<T = any>(key: string): Promise<T | null> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readonly');
    const st = tx.objectStore(STORE);
    const rq = st.get(key);
    rq.onsuccess = () => resolve((rq.result as T) ?? null);
    rq.onerror = () => reject(rq.error || new Error('idb get failed'));
  });
}

export async function idbSet<T = any>(key: string, value: T): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    const st = tx.objectStore(STORE);
    const rq = st.put(value as any, key);
    rq.onsuccess = () => resolve();
    rq.onerror = () => reject(rq.error || new Error('idb put failed'));
  });
}

export async function idbDel(key: string): Promise<void> {
  const db = await openDb();
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE, 'readwrite');
    const st = tx.objectStore(STORE);
    const rq = st.delete(key);
    rq.onsuccess = () => resolve();
    rq.onerror = () => reject(rq.error || new Error('idb delete failed'));
  });
}

