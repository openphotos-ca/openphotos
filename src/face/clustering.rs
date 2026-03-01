use anyhow::Result;
use log::info;
use std::collections::{HashMap, HashSet};

/// Face clustering implementation with multiple algorithms
pub struct FaceClusterer {
    eps: f32,           // Maximum distance between two samples for them to be in the same cluster
    min_samples: usize, // Minimum number of samples in a neighborhood to form a cluster
}

impl FaceClusterer {
    pub fn new(eps: f32, min_samples: usize) -> Self {
        Self { eps, min_samples }
    }

    /// Perform DBSCAN clustering on face embeddings
    pub fn cluster(&self, embeddings: &[Vec<f32>]) -> Vec<Option<usize>> {
        let n = embeddings.len();
        let mut labels = vec![None; n]; // None means unassigned
        let mut cluster_id = 0;
        let mut visited = vec![false; n];

        for i in 0..n {
            if visited[i] {
                continue;
            }
            visited[i] = true;

            let neighbors = self.get_neighbors(i, embeddings);
            
            // Include point i itself in the neighbor count
            if neighbors.len() + 1 < self.min_samples {
                // Mark as noise (stays None)
                continue;
            }

            // Start a new cluster
            labels[i] = Some(cluster_id);
            let mut seed_set = neighbors.into_iter().collect::<HashSet<_>>();
            
            while !seed_set.is_empty() {
                let current = *seed_set.iter().next().unwrap();
                seed_set.remove(&current);
                
                if visited[current] {
                    continue;
                }
                visited[current] = true;
                
                let current_neighbors = self.get_neighbors(current, embeddings);
                
                // Include current point itself in neighbor count
                if current_neighbors.len() + 1 >= self.min_samples {
                    for &neighbor in &current_neighbors {
                        if !visited[neighbor] {
                            seed_set.insert(neighbor);
                        }
                    }
                }
                
                if labels[current].is_none() {
                    labels[current] = Some(cluster_id);
                }
            }
            
            cluster_id += 1;
        }

        labels
    }

    /// Find all neighbors within eps distance of point i
    fn get_neighbors(&self, point_idx: usize, embeddings: &[Vec<f32>]) -> Vec<usize> {
        let mut neighbors = Vec::new();
        let point_embedding = &embeddings[point_idx];
        
        for (j, other_embedding) in embeddings.iter().enumerate() {
            if j != point_idx {
                let similarity = cosine_similarity(point_embedding, other_embedding);
                let distance = 1.0 - similarity;
                if distance <= self.eps {
                    neighbors.push(j);
                }
                // Clustering based on distance threshold
            }
        }
        
        neighbors
    }

    /// Agglomerative clustering targeting exactly k clusters
    pub fn agglomerative_cluster(&self, embeddings: &[Vec<f32>], target_clusters: usize) -> Vec<usize> {
        let n = embeddings.len();
        if n <= target_clusters {
            // If we have fewer faces than target clusters, each face gets its own cluster
            return (0..n).collect();
        }
        
        // Start with each face as its own cluster
        let mut clusters: Vec<Vec<usize>> = (0..n).map(|i| vec![i]).collect();
        
        // Merge clusters until we have target_clusters
        while clusters.len() > target_clusters {
            let mut best_merge = (0, 1);
            let mut best_similarity = -1.0f32;
            
            // Find the two clusters with highest average similarity
            for i in 0..clusters.len() {
                for j in (i+1)..clusters.len() {
                    let avg_similarity = self.cluster_similarity(&clusters[i], &clusters[j], embeddings);
                    if avg_similarity > best_similarity {
                        best_similarity = avg_similarity;
                        best_merge = (i, j);
                    }
                }
            }
            
            // Merge the two most similar clusters
            let (i, j) = best_merge;
            let cluster_j = clusters.remove(j); // Remove j first (higher index)
            clusters[i].extend(cluster_j);
        }
        
        // Convert cluster assignments to labels
        let mut labels = vec![0; n];
        for (cluster_id, cluster) in clusters.iter().enumerate() {
            for &face_id in cluster {
                labels[face_id] = cluster_id;
            }
        }
        
        info!("Agglomerative clustering created {} clusters", clusters.len());
        labels
    }
    
    /// Calculate average similarity between two clusters
    fn cluster_similarity(&self, cluster_a: &[usize], cluster_b: &[usize], embeddings: &[Vec<f32>]) -> f32 {
        let mut total_similarity = 0.0;
        let mut count = 0;
        
        for &i in cluster_a {
            for &j in cluster_b {
                total_similarity += cosine_similarity(&embeddings[i], &embeddings[j]);
                count += 1;
            }
        }
        
        if count > 0 {
            total_similarity / count as f32
        } else {
            0.0
        }
    }

    /// Consolidate clusters and assign person IDs
    pub fn assign_person_ids(&self, labels: &[Option<usize>]) -> HashMap<usize, String> {
        let mut cluster_to_person = HashMap::new();
        let mut person_counter = 1;
        
        for label in labels.iter().flatten() {
            if !cluster_to_person.contains_key(label) {
                cluster_to_person.insert(*label, format!("p{}", person_counter));
                person_counter += 1;
            }
        }
        
        info!("Created {} person clusters", cluster_to_person.len());
        cluster_to_person
    }
    
    /// Assign person IDs for agglomerative clustering results (no Option types)
    pub fn assign_person_ids_direct(&self, labels: &[usize]) -> HashMap<usize, String> {
        let mut cluster_to_person = HashMap::new();
        let mut person_counter = 1;
        
        let unique_labels: HashSet<usize> = labels.iter().cloned().collect();
        for label in unique_labels {
            cluster_to_person.insert(label, format!("p{}", person_counter));
            person_counter += 1;
        }
        
        info!("Created {} person clusters", cluster_to_person.len());
        cluster_to_person
    }
}

/// Calculate cosine similarity between two embeddings
fn cosine_similarity(emb1: &[f32], emb2: &[f32]) -> f32 {
    let mut dot_product = 0.0;
    let mut norm1 = 0.0;
    let mut norm2 = 0.0;
    
    for i in 0..emb1.len() {
        dot_product += emb1[i] * emb2[i];
        norm1 += emb1[i] * emb1[i];
        norm2 += emb2[i] * emb2[i];
    }
    
    norm1 = norm1.sqrt();
    norm2 = norm2.sqrt();
    
    if norm1 == 0.0 || norm2 == 0.0 {
        return 0.0;
    }
    
    dot_product / (norm1 * norm2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_cosine_similarity() {
        let emb1 = vec![1.0, 0.0, 0.0];
        let emb2 = vec![1.0, 0.0, 0.0];
        assert!((cosine_similarity(&emb1, &emb2) - 1.0).abs() < 1e-6);
        
        let emb3 = vec![1.0, 0.0, 0.0];
        let emb4 = vec![0.0, 1.0, 0.0];
        assert!((cosine_similarity(&emb3, &emb4) - 0.0).abs() < 1e-6);
    }
}