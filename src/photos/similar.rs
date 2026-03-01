use std::collections::{HashMap, HashSet, VecDeque};

use crate::photos::phash::hamming_distance;

/// Banding-based index for 64-bit pHash using t_max+1 bands.
pub struct BandingIndex {
    pub t_max: u8,
    band_widths: Vec<u8>,
    /// Map of (band_idx, band_val) -> asset_ids
    buckets: HashMap<(u8, u32), Vec<String>>,
    /// asset_id -> phash
    hashes: HashMap<String, u64>,
}

impl BandingIndex {
    pub fn new(t_max: u8) -> Self {
        let band_count = (t_max as usize) + 1;
        let mut band_widths = Vec::with_capacity(band_count);
        let base = 64 / band_count;
        let rem = 64 % band_count;
        for i in 0..band_count {
            let w = base + if i < rem { 1 } else { 0 };
            band_widths.push(w as u8);
        }
        Self {
            t_max,
            band_widths,
            buckets: HashMap::new(),
            hashes: HashMap::new(),
        }
    }

    pub fn len(&self) -> usize {
        self.hashes.len()
    }
    pub fn is_empty(&self) -> bool {
        self.hashes.is_empty()
    }

    /// Add/update an asset's hash
    pub fn upsert(&mut self, asset_id: String, phash: u64) {
        // If present with a different hash, remove old bucket entries
        if let Some(old) = self.hashes.get(&asset_id).copied() {
            if old != phash {
                self.remove_from_buckets(&asset_id, old);
            }
        }
        self.hashes.insert(asset_id.clone(), phash);
        for (i, val) in self.bands(phash).into_iter().enumerate() {
            self.buckets
                .entry((i as u8, val))
                .or_default()
                .push(asset_id.clone());
        }
    }

    /// Remove an asset from buckets (used when hash changed)
    fn remove_from_buckets(&mut self, asset_id: &str, phash: u64) {
        for (i, val) in self.bands(phash).into_iter().enumerate() {
            if let Some(v) = self.buckets.get_mut(&(i as u8, val)) {
                v.retain(|a| a != asset_id);
            }
        }
    }

    fn bands(&self, phash: u64) -> Vec<u32> {
        // Partition 64 bits most-significant-first with band_widths
        let mut vals = Vec::with_capacity(self.band_widths.len());
        let mut shift = 64u8;
        for &w in &self.band_widths {
            shift -= w;
            let mask = if w == 32 { u64::MAX } else { (1u64 << w) - 1 } as u64;
            let v = ((phash >> shift) & mask) as u32;
            vals.push(v);
        }
        vals
    }

    /// Find neighbor asset IDs within distance t of the given phash
    pub fn neighbors(&self, phash: u64, t: u8, exclude: Option<&str>) -> Vec<(String, u32)> {
        let t = t.min(self.t_max);
        let mut cand: HashSet<String> = HashSet::new();
        for (i, val) in self.bands(phash).into_iter().enumerate() {
            if let Some(v) = self.buckets.get(&(i as u8, val)) {
                for a in v {
                    cand.insert(a.clone());
                }
            }
        }
        if let Some(ex) = exclude {
            cand.remove(ex);
        }
        let mut out: Vec<(String, u32)> = Vec::new();
        for a in cand.into_iter() {
            if let Some(&h) = self.hashes.get(&a) {
                let d = hamming_distance(h, phash);
                if d as u8 <= t {
                    out.push((a, d));
                }
            }
        }
        out.sort_by_key(|(_, d)| *d);
        out
    }

    /// Form connected components via union-by-search using threshold t
    pub fn groups(&self, t: u8, min_group_size: usize) -> Vec<Vec<String>> {
        let t = t.min(self.t_max);
        let mut visited: HashSet<String> = HashSet::new();
        let mut groups: Vec<Vec<String>> = Vec::new();
        for a in self.hashes.keys() {
            if visited.contains(a) {
                continue;
            }
            // BFS/DFS
            let mut group: Vec<String> = Vec::new();
            let mut q: VecDeque<String> = VecDeque::new();
            visited.insert(a.clone());
            q.push_back(a.clone());
            while let Some(cur) = q.pop_front() {
                group.push(cur.clone());
                let ph = self.hashes.get(&cur).copied().unwrap_or(0);
                for (nb, _d) in self.neighbors(ph, t, Some(&cur)) {
                    if visited.insert(nb.clone()) {
                        q.push_back(nb);
                    }
                }
            }
            if group.len() >= min_group_size {
                groups.push(group);
            }
        }
        // Sort groups by size desc, then by representative asset_id
        groups.sort_by(|a, b| b.len().cmp(&a.len()).then(a[0].cmp(&b[0])));
        groups
    }
}
