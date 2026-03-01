use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq)]
pub struct BoundingBox {
    pub x1: f32,
    pub y1: f32,
    pub x2: f32,
    pub y2: f32,
}

impl BoundingBox {
    pub fn new(x1: f32, y1: f32, x2: f32, y2: f32) -> Self {
        Self { x1, y1, x2, y2 }
    }
    
    pub fn width(&self) -> f32 {
        self.x2 - self.x1
    }
    
    pub fn height(&self) -> f32 {
        self.y2 - self.y1
    }
    
    pub fn center(&self) -> (f32, f32) {
        ((self.x1 + self.x2) / 2.0, (self.y1 + self.y2) / 2.0)
    }
}

#[derive(Debug, Clone)]
pub struct FacialLandmarks {
    pub points: Vec<(f32, f32)>,
}

impl FacialLandmarks {
    pub fn new(points: Vec<(f32, f32)>) -> Self {
        Self { points }
    }
    
    pub fn left_eye(&self) -> (f32, f32) {
        self.points[0]
    }
    
    pub fn right_eye(&self) -> (f32, f32) {
        self.points[1]
    }
    
    pub fn nose(&self) -> (f32, f32) {
        self.points[2]
    }
    
    pub fn left_mouth(&self) -> (f32, f32) {
        self.points[3]
    }
    
    pub fn right_mouth(&self) -> (f32, f32) {
        self.points[4]
    }
}

#[derive(Debug, Clone)]
pub struct FaceDetection {
    pub bbox: BoundingBox,
    pub landmarks: FacialLandmarks,
    pub confidence: f32,
}

impl FaceDetection {
    pub fn new(bbox: BoundingBox, landmarks: FacialLandmarks, confidence: f32) -> Self {
        Self {
            bbox,
            landmarks,
            confidence,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NormalizedFace {
    pub embedding: Vec<f32>,
    pub bbox: (f32, f32, f32, f32), // x1, y1, x2, y2
    pub confidence: f32,
}

impl NormalizedFace {
    pub fn new(embedding: Vec<f32>, bbox: &BoundingBox, confidence: f32) -> Self {
        Self {
            embedding,
            bbox: (bbox.x1, bbox.y1, bbox.x2, bbox.y2),
            confidence,
        }
    }
}