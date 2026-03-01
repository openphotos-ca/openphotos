pub mod embeddings;
// pub mod faces; // Temporarily disabled due to rusqlite dependency issues
pub mod meta_store;
pub mod multi_tenant;
pub mod pg_meta_store;
pub mod postgres;

use anyhow::Result;
use duckdb::Connection;
use parking_lot::Mutex;
use std::sync::Arc;
use tracing::info;

pub type DbPool = Arc<Mutex<Connection>>;

pub struct Database {
    conn: DbPool,
}

impl Database {
    pub fn new(path: &str) -> Result<Self> {
        let conn = if path == ":memory:" {
            Connection::open_in_memory()?
        } else {
            Connection::open(path)?
        };

        // Install and load VSS extension for vector operations
        conn.execute_batch(
            "INSTALL vss;
             LOAD vss;
             SET hnsw_enable_experimental_persistence = true;",
        )?;

        info!("Database initialized at: {}", path);

        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
        })
    }

    pub fn create_tables(&self, embedding_dim: usize) -> Result<()> {
        let conn = self.conn.lock();

        // Create tables with configurable embedding dimensions
        let schema = format!(
            "CREATE TABLE IF NOT EXISTS smart_search (
                asset_id VARCHAR PRIMARY KEY,
                embedding FLOAT[{}],
                image_data BLOB,
                image_width INTEGER,
                image_height INTEGER,
                content_type VARCHAR DEFAULT 'image/jpeg',
                detected_objects TEXT[],
                scene_tags TEXT[],
                search_tags TEXT[],
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            
            CREATE TABLE IF NOT EXISTS text_cache (
                query_text VARCHAR,
                model_name VARCHAR,
                language VARCHAR,
                embedding FLOAT[{}],
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (query_text, model_name, language)
            );
            
            CREATE TABLE IF NOT EXISTS faces (
                face_id VARCHAR PRIMARY KEY,
                asset_id VARCHAR NOT NULL,
                person_id VARCHAR,
                bbox_x INTEGER NOT NULL,
                bbox_y INTEGER NOT NULL,
                bbox_width INTEGER NOT NULL,
                bbox_height INTEGER NOT NULL,
                confidence REAL NOT NULL,
                embedding FLOAT[512],
                face_thumbnail BLOB,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                -- FOREIGN KEY (asset_id) REFERENCES smart_search(asset_id)
            );
            
            CREATE TABLE IF NOT EXISTS persons (
                person_id VARCHAR PRIMARY KEY,
                display_name VARCHAR,
                face_count INTEGER DEFAULT 0,
                representative_face_id VARCHAR,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                -- FOREIGN KEY (representative_face_id) REFERENCES faces(face_id)
            );
            
            CREATE INDEX IF NOT EXISTS idx_faces_asset ON faces(asset_id);
            CREATE INDEX IF NOT EXISTS idx_faces_person ON faces(person_id);
            CREATE INDEX IF NOT EXISTS idx_face_embedding ON faces USING HNSW (embedding) WITH (metric = 'cosine');",
            embedding_dim, embedding_dim
        );

        conn.execute_batch(&schema)?;
        Ok(())
    }

    pub fn connection(&self) -> DbPool {
        self.conn.clone()
    }

    pub fn create_index(&self) -> Result<()> {
        let conn = self.conn.lock();

        // Create HNSW index for fast similarity search
        conn.execute(
            "CREATE INDEX IF NOT EXISTS idx_embedding 
             ON smart_search USING HNSW (embedding) 
             WITH (metric = 'cosine');",
            [],
        )?;

        // Force checkpoint to commit schema to main database file
        conn.execute("CHECKPOINT;", [])?;

        info!("Created HNSW index for vector search");
        Ok(())
    }
}
