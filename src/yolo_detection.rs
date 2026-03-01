use anyhow::Result;
use image::{DynamicImage, GenericImageView, RgbImage};
use ndarray::{s, Array4, ArrayView3};
use ort::{
    session::{builder::GraphOptimizationLevel, Session},
    value::Value,
};
use std::fs;
use std::path::Path;
use std::sync::{Arc, Mutex};
use tracing::{info, warn};

/// COCO dataset class names (80 classes)
pub const COCO_CLASSES: &[&str] = &[
    "person",
    "bicycle",
    "car",
    "motorcycle",
    "airplane",
    "bus",
    "train",
    "truck",
    "boat",
    "traffic light",
    "fire hydrant",
    "stop sign",
    "parking meter",
    "bench",
    "bird",
    "cat",
    "dog",
    "horse",
    "sheep",
    "cow",
    "elephant",
    "bear",
    "zebra",
    "giraffe",
    "backpack",
    "umbrella",
    "handbag",
    "tie",
    "suitcase",
    "frisbee",
    "skis",
    "snowboard",
    "sports ball",
    "kite",
    "baseball bat",
    "baseball glove",
    "skateboard",
    "surfboard",
    "tennis racket",
    "bottle",
    "wine glass",
    "cup",
    "fork",
    "knife",
    "spoon",
    "bowl",
    "banana",
    "apple",
    "sandwich",
    "orange",
    "broccoli",
    "carrot",
    "hot dog",
    "pizza",
    "donut",
    "cake",
    "chair",
    "couch",
    "potted plant",
    "bed",
    "dining table",
    "toilet",
    "tv",
    "laptop",
    "mouse",
    "remote",
    "keyboard",
    "cell phone",
    "microwave",
    "oven",
    "toaster",
    "sink",
    "refrigerator",
    "book",
    "clock",
    "vase",
    "scissors",
    "teddy bear",
    "hair drier",
    "toothbrush",
];

/// OIV7 dataset class names (601 classes) - first 100 for brevity
pub const OIV7_CLASSES: &[&str] = &[
    "Accordion",
    "Adhesive tape",
    "Aircraft",
    "Airplane",
    "Alarm clock",
    "Alpaca",
    "Ambulance",
    "Animal",
    "Ant",
    "Antelope",
    "Apple",
    "Armadillo",
    "Artichoke",
    "Auto part",
    "Axe",
    "Backpack",
    "Bagel",
    "Baked goods",
    "Balance beam",
    "Ball",
    "Balloon",
    "Banana",
    "Band-aid",
    "Banjo",
    "Barge",
    "Barrel",
    "Baseball bat",
    "Baseball glove",
    "Bat (Animal)",
    "Bathroom accessory",
    "Bathroom cabinet",
    "Bathtub",
    "Beaker",
    "Bear",
    "Bed",
    "Bee",
    "Beehive",
    "Beer",
    "Beetle",
    "Bell pepper",
    "Belt",
    "Bench",
    "Bicycle",
    "Bicycle helmet",
    "Bicycle wheel",
    "Bidet",
    "Billboard",
    "Billiard table",
    "Binoculars",
    "Bird",
    "Blackboard",
    "Blender",
    "Blue jay",
    "Boat",
    "Bobby pin",
    "Bomb",
    "Book",
    "Bookcase",
    "Boot",
    "Bottle",
    "Bottle opener",
    "Bow tie",
    "Bowl",
    "Bowling equipment",
    "Box",
    "Boy",
    "Brassiere",
    "Bread",
    "Briefcase",
    "Broccoli",
    "Bronze sculpture",
    "Brown bear",
    "Building",
    "Bull",
    "Burrito",
    "Bus",
    "Butterfly",
    "Cabinetry",
    "Cake",
    "Camel",
    "Camera",
    "Canary",
    "Candle",
    "Candy",
    "Cannon",
    "Canoe",
    "Car",
    "Carnivore",
    "Carrot",
    "Cart",
    "Cassette deck",
    "Castle",
    "Cat",
    "Caterpillar",
    "Cattle",
    "Ceiling fan",
    "Cello",
    "Centipede",
    "Chainsaw",
    "Chair",
    "Cheese",
    "Cheetah",
    "Chest of drawers",
    "Chicken",
    "Chime",
    "Chisel",
    "Chocolate",
    "Christmas tree",
    "Cigar",
    "Cigarette",
    "Clock",
    "Closet",
    "Clothing",
    "Cloud",
    "Cockroach",
    "Cocktail",
    "Coconut",
    "Coffee",
    "Coffee cup",
    "Coffee table",
    "Coin",
    "Common fig",
    "Common sunflower",
    "Computer keyboard",
    "Computer monitor",
    "Computer mouse",
    "Container",
    "Convenience store",
    "Cookie",
    "Cooking spray",
    "Corded phone",
    "Cosmetics",
    "Couch",
    "Countertop",
    "Cowboy hat",
    "Crab",
    "Cream",
    "Cricket ball",
    "Crocodile",
    "Croissant",
    "Crown",
    "Cucumber",
    "Cupboard",
    "Curtain",
    "Cutting board",
    "Dagger",
    "Dairy Product",
    "Deer",
    "Desk",
    "Dessert",
    "Diaper",
    "Dice",
    "Digital clock",
    "Dinosaur",
    "Dishwasher",
    "Dog",
    "Doll",
    "Dolphin",
    "Door",
    "Door handle",
    "Doughnut",
    "Dragonfly",
    "Drawer",
    "Dress",
    "Drill (Tool)",
    "Drink",
    "Drum",
    "Duck",
    "Dumbbell",
    "Eagle",
    "Earrings",
    "Egg (Food)",
    "Elephant",
    "Envelope",
    "Eraser",
    "Face powder",
    "Facial tissue",
    "Falcon",
    "Fashion accessory",
    "Fast food",
    "Fax",
    "Fedora",
    "Filing cabinet",
    "Fire hydrant",
    "Fireplace",
    "Fish",
    "Flag",
    "Flashlight",
    "Floppy disk",
    "Flower",
    "Flowerpot",
    "Flute",
    "Flying disc",
    "Food",
    "Food processor",
    "Football",
    "Football helmet",
    "Footwear",
    "Fork",
    "Fountain",
    "Fox",
    "French fries",
    "French horn",
    "Frog",
    "Fruit",
    "Frying pan",
    "Furniture",
    "Gas stove",
    "Giraffe",
    "Girl",
    "Glass",
    "Glasses",
    "Glove",
    "Goat",
    "Goggles",
    "Goldfish",
    "Golf ball",
    "Golf cart",
    "Gondola",
    "Goose",
    "Grape",
    "Grapefruit",
    "Grasshopper",
    "Grill",
    "Guitar",
    "Hamster",
    "Handbag",
    "Harmonica",
    "Harp",
    "Hat",
    "Headphones",
    "Hedgehog",
    "Helicopter",
    "Helmet",
    "High heels",
    "Hiking equipment",
    "Hippopotamus",
    "Home appliance",
    "Honeycomb",
    "Horizontal bar",
    "Horse",
    "House",
    "Houseplant",
    "Human arm",
    "Human beard",
    "Human body",
    "Human ear",
    "Human eye",
    "Human face",
    "Human foot",
    "Human hair",
    "Human hand",
    "Human head",
    "Human leg",
    "Human mouth",
    "Human nose",
    "Humidifier",
    "Ice cream",
    "Indoor rower",
    "Infant bed",
    "Insect",
    "Invertebrate",
    "Ipod",
    "Jacket",
    "Jaguar",
    "Jeans",
    "Jellyfish",
    "Jet ski",
    "Jug",
    "Juice",
    "Kangaroo",
    "Kettle",
    "Kitchen & dining room table",
    "Kitchen appliance",
    "Kitchen knife",
    "Kitchen utensil",
    "Kitchenware",
    "Kite",
    "Knife",
    "Koala",
    "Ladder",
    "Ladle",
    "Ladybug",
    "Lamp",
    "Land vehicle",
    "Laptop",
    "Lavender (Plant)",
    "Lemon",
    "Leopard",
    "Light bulb",
    "Light switch",
    "Lighthouse",
    "Lily",
    "Limousine",
    "Lion",
    "Lipstick",
    "Lizard",
    "Lobster",
    "Lock",
    "Loveseat",
    "Luggage and bags",
    "Lynx",
    "Magpie",
    "Mammal",
    "Man",
    "Mango",
    "Maple",
    "Maracas",
    "Marine invertebrates",
    "Marine mammal",
    "Mask",
    "Measuring cup",
    "Mechanical fan",
    "Medical equipment",
    "Microphone",
    "Microwave oven",
    "Military vehicle",
    "Milk",
    "Miniskirt",
    "Mirror",
    "Missile",
    "Mixer",
    "Mobile phone",
    "Monkey",
    "Motorcycle",
    "Mouse",
    "Muffin",
    "Mug",
    "Mule",
    "Mushroom",
    "Musical instrument",
    "Musical keyboard",
    "Nail (Construction)",
    "Necklace",
    "Nightstand",
    "Oboe",
    "Office building",
    "Office supplies",
    "Orange",
    "Organ (Musical Instrument)",
    "Ostrich",
    "Otter",
    "Oven",
    "Owl",
    "Oyster",
    "Paddle",
    "Palm tree",
    "Pancake",
    "Panda",
    "Paper towel",
    "Parachute",
    "Parrot",
    "Pasta",
    "Pastry",
    "Peach",
    "Pear",
    "Pen",
    "Penguin",
    "Person",
    "Personal care",
    "Personal flotation device",
    "Piano",
    "Picnic basket",
    "Picture frame",
    "Pig",
    "Pillow",
    "Pineapple",
    "Pizza",
    "Plant",
    "Plastic bag",
    "Plate",
    "Platter",
    "Polar bear",
    "Pomegranate",
    "Porch",
    "Porcupine",
    "Poster",
    "Potato",
    "Power plugs and sockets",
    "Printer",
    "Pumpkin",
    "Punching bag",
    "Rabbit",
    "Raccoon",
    "Radio",
    "Radish",
    "Raven",
    "Rays and skates",
    "Red panda",
    "Refrigerator",
    "Remote control",
    "Reptile",
    "Rhinoceros",
    "Rifle",
    "Ring",
    "River",
    "Rocket",
    "Roller skates",
    "Rose",
    "Rugby ball",
    "Ruler",
    "Salad",
    "Salt and pepper shakers",
    "Sandal",
    "Sandwich",
    "Saucer",
    "Saxophone",
    "Scale",
    "Scarf",
    "Scissors",
    "Scorpion",
    "Screwdriver",
    "Sculpture",
    "Sea lion",
    "Sea turtle",
    "Seafood",
    "Seal",
    "Sheep",
    "Shelf",
    "Shellfish",
    "Shield",
    "Shirt",
    "Shoe",
    "Shopping cart",
    "Shorts",
    "Shotgun",
    "Shower",
    "Shrimp",
    "Sink",
    "Skateboard",
    "Ski",
    "Skirt",
    "Skull",
    "Skunk",
    "Skyscraper",
    "Slow cooker",
    "Snack",
    "Snail",
    "Snake",
    "Snowboard",
    "Snowman",
    "Snowmobile",
    "Soap",
    "Soccer ball",
    "Sock",
    "Sofa bed",
    "Sombrero",
    "Sparrow",
    "Spatula",
    "Spice rack",
    "Spider",
    "Spoon",
    "Sports equipment",
    "Sports uniform",
    "Spotlight",
    "Squid",
    "Squirrel",
    "Stairs",
    "Stapler",
    "Starfish",
    "Stationary bicycle",
    "Stethoscope",
    "Stool",
    "Stop sign",
    "Strawberry",
    "Street light",
    "Stretcher",
    "Studio couch",
    "Submarine",
    "Suit",
    "Suitcase",
    "Sun hat",
    "Sunflower",
    "Sunglasses",
    "Surfboard",
    "Sushi",
    "Swan",
    "Sweet potato",
    "Swimming pool",
    "Swimwear",
    "Sword",
    "Syringe",
    "Table",
    "Table tennis racket",
    "Tablet computer",
    "Tableware",
    "Taco",
    "Tank",
    "Tap",
    "Taxi",
    "Tea",
    "Teapot",
    "Teddy bear",
    "Telephone",
    "Television",
    "Tennis ball",
    "Tennis racket",
    "Tent",
    "Tie",
    "Tiger",
    "Tin can",
    "Tire",
    "Toaster",
    "Toilet",
    "Toilet paper",
    "Tomato",
    "Tool",
    "Toothbrush",
    "Torch",
    "Tortoise",
    "Towel",
    "Tower",
    "Toy",
    "Traffic light",
    "Traffic sign",
    "Train",
    "Training bench",
    "Tram",
    "Tree",
    "Tripod",
    "Trombone",
    "Truck",
    "Trumpet",
    "Turkey",
    "Turtle",
    "Umbrella",
    "Unicycle",
    "Van",
    "Vase",
    "Vegetable",
    "Vehicle",
    "Vehicle registration plate",
    "Violin",
    "Volleyball (Ball)",
    "Waffle",
    "Wall clock",
    "Wardrobe",
    "Washing machine",
    "Watch",
    "Watercraft",
    "Watermelon",
    "Weapon",
    "Whale",
    "Wheel",
    "Wheelchair",
    "Whisk",
    "Whiteboard",
    "Willow",
    "Window",
    "Window blind",
    "Wine",
    "Wine glass",
    "Winter melon",
    "Wok",
    "Woman",
    "Wood-burning stove",
    "Woodpecker",
    "Wrench",
    "Zebra",
    "Zucchini",
];

#[derive(Debug, Clone)]
pub struct BoundingBox {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

#[derive(Debug, Clone)]
pub struct Detection {
    pub class: String,
    pub class_id: usize,
    pub confidence: f32,
    pub bbox: BoundingBox,
}

#[derive(Debug, Clone, Copy)]
struct LetterboxInfo {
    // Resize scale used to fit original into network input (after rounding)
    scale: f32,
    // Left/top padding applied during letterbox in network input space
    pad_x: f32,
    pad_y: f32,
}

pub struct YoloDetector {
    session: Option<Arc<Mutex<Session>>>,
    input_size: (u32, u32),
    confidence_threshold: f32,
    nms_threshold: f32,
    model_type: ModelType,
    oiv7_classes: Option<Vec<String>>,
}

#[derive(Debug, Clone)]
pub enum ModelType {
    Coco, // 80 classes
    Oiv7, // 601 classes
}

impl YoloDetector {
    /// Load OIV7 class names from file
    fn load_oiv7_classes() -> Result<Vec<String>> {
        let class_file = Path::new("models/oiv7_classes.txt");
        if class_file.exists() {
            let content = fs::read_to_string(class_file)?;
            let classes: Vec<String> = content.lines().map(|s| s.to_string()).collect();
            info!("Loaded {} OIV7 class names", classes.len());
            Ok(classes)
        } else {
            warn!("OIV7 class file not found at models/oiv7_classes.txt");
            Err(anyhow::anyhow!("OIV7 class file not found"))
        }
    }

    /// Create a new YOLO detector
    pub fn new(model_path: Option<&Path>) -> Result<Self> {
        let (session, model_type) = if let Some(path) = model_path {
            if path.exists() && path.metadata()?.len() > 1000 {
                // Only load if file is valid (> 1KB)
                let session = Session::builder()
                    .unwrap()
                    .with_optimization_level(GraphOptimizationLevel::Level3)
                    .unwrap()
                    .with_intra_threads(1)
                    .unwrap()
                    .commit_from_file(path)
                    .unwrap();

                // Detect model type from filename or output shape
                let model_type = if path.to_string_lossy().contains("oiv7") {
                    ModelType::Oiv7
                } else {
                    ModelType::Coco
                };

                info!("Loaded YOLO model: {:?} type", model_type);
                (Some(Arc::new(Mutex::new(session))), model_type)
            } else {
                warn!(
                    "YOLO model not found or invalid at {:?}, using mock detector",
                    path
                );
                (None, ModelType::Coco)
            }
        } else {
            (None, ModelType::Coco)
        };

        // Load OIV7 classes if needed
        let oiv7_classes = if matches!(model_type, ModelType::Oiv7) {
            Self::load_oiv7_classes().ok()
        } else {
            None
        };

        Ok(Self {
            session,
            input_size: (640, 640),
            confidence_threshold: 0.1, // Low threshold - let CLI do the filtering
            nms_threshold: 0.45,
            model_type,
            oiv7_classes,
        })
    }

    /// Detect objects in an image
    pub fn detect(&self, image: &DynamicImage) -> Result<Vec<Detection>> {
        if let Some(ref session) = self.session {
            // Real YOLO detection
            self.detect_with_yolo(session.clone(), image)
        } else {
            // Mock detection for testing
            self.mock_detect(image)
        }
    }

    /// Real YOLO detection using ONNX model
    fn detect_with_yolo(
        &self,
        session: Arc<Mutex<Session>>,
        image: &DynamicImage,
    ) -> Result<Vec<Detection>> {
        // Preprocess image with letterbox (preserve aspect ratio)
        let (input, lb_info) = self.preprocess_image(image)?;

        // Run inference
        let input_value = Value::from_array(input)?;
        let mut session_lock = session.lock().unwrap();
        let outputs = session_lock.run(ort::inputs![input_value])?;

        // Get output tensor
        let (output_shape, output_data) = outputs[0].try_extract_tensor::<f32>()?;
        let output_array = ArrayView3::from_shape(
            (
                output_shape[0] as usize,
                output_shape[1] as usize,
                output_shape[2] as usize,
            ),
            output_data,
        )?;

        // Post-process to get detections
        let detections =
            self.postprocess_output(&output_array, image.width(), image.height(), lb_info)?;

        // Apply NMS
        let final_detections = self.non_max_suppression(detections);

        Ok(final_detections)
    }

    /// Mock detection for testing without model
    fn mock_detect(&self, image: &DynamicImage) -> Result<Vec<Detection>> {
        info!(
            "Using mock detector for image {}x{}",
            image.width(),
            image.height()
        );

        // Simple heuristic-based detection for testing
        let mut detections = Vec::new();

        // Analyze image for basic patterns
        let rgb_image = image.to_rgb8();
        let (width, height) = image.dimensions();

        // Check for text-like patterns (lots of uniform colors)
        let has_text = self.detect_text_patterns(&rgb_image);
        if has_text {
            detections.push(Detection {
                class: "text".to_string(),
                class_id: 999, // Custom ID for text
                confidence: 0.45,
                bbox: BoundingBox {
                    x: width as f32 * 0.1,
                    y: height as f32 * 0.1,
                    width: width as f32 * 0.8,
                    height: height as f32 * 0.3,
                },
            });
        }

        // Check for animal-like features (browns, texture variation)
        let has_animal = self.detect_animal_patterns(&rgb_image);
        if has_animal {
            detections.push(Detection {
                class: "animal".to_string(), // Generic animal
                class_id: 16,                // Dog class ID
                confidence: 0.75,
                bbox: BoundingBox {
                    x: width as f32 * 0.2,
                    y: height as f32 * 0.2,
                    width: width as f32 * 0.6,
                    height: height as f32 * 0.6,
                },
            });
        }

        Ok(detections)
    }

    /// Preprocess image for YOLO input (letterbox to preserve aspect ratio)
    fn preprocess_image(&self, image: &DynamicImage) -> Result<(Array4<f32>, LetterboxInfo)> {
        let (in_w, in_h) = self.input_size;
        let (orig_w, orig_h) = image.dimensions();

        // Compute scale and padding (Ultralytics-style letterbox)
        let r = (in_w as f32 / orig_w as f32).min(in_h as f32 / orig_h as f32);
        let new_w = (orig_w as f32 * r).round() as u32;
        let new_h = (orig_h as f32 * r).round() as u32;
        let pad_x = ((in_w - new_w) as f32) / 2.0; // left padding
        let pad_y = ((in_h - new_h) as f32) / 2.0; // top padding

        // Resize keeping aspect ratio
        let resized = image.resize_exact(new_w, new_h, image::imageops::FilterType::Triangle);

        // Create letterboxed canvas filled with 114 gray
        let mut canvas = image::RgbImage::from_pixel(in_w, in_h, image::Rgb([114u8, 114u8, 114u8]));
        image::imageops::overlay(
            &mut canvas,
            &resized.to_rgb8(),
            pad_x.round() as i64,
            pad_y.round() as i64,
        );

        let mut input = Array4::<f32>::zeros((1, 3, in_h as usize, in_w as usize));

        // Convert to normalized float array (0-1 range)
        for y in 0..in_h {
            for x in 0..in_w {
                let pixel = canvas.get_pixel(x, y);
                input[[0, 0, y as usize, x as usize]] = pixel[0] as f32 / 255.0;
                input[[0, 1, y as usize, x as usize]] = pixel[1] as f32 / 255.0;
                input[[0, 2, y as usize, x as usize]] = pixel[2] as f32 / 255.0;
            }
        }

        let lb_info = LetterboxInfo {
            scale: new_w as f32 / orig_w as f32, // use actual resize ratio after rounding
            pad_x,
            pad_y,
        };

        Ok((input, lb_info))
    }

    /// Post-process YOLO output to get detections
    fn postprocess_output(
        &self,
        output: &ArrayView3<f32>,
        orig_width: u32,
        orig_height: u32,
        lb: LetterboxInfo,
    ) -> Result<Vec<Detection>> {
        let mut detections = Vec::new();

        // YOLOv8 output shape varies by model:
        // COCO: [1, 84, 8400] = 4 (bbox) + 80 (classes)
        // OIV7: [1, 605, 8400] = 4 (bbox) + 601 (classes)

        let num_predictions = output.shape()[2];
        let num_classes = match self.model_type {
            ModelType::Coco => 80,
            ModelType::Oiv7 => 601,
        };

        for i in 0..num_predictions {
            // Get bounding box (first 4 values)
            let cx = output[[0, 0, i]];
            let cy = output[[0, 1, i]];
            let w = output[[0, 2, i]];
            let h = output[[0, 3, i]];

            // Get confidence scores for all classes (values 4+)
            let class_scores = output.slice(s![0, 4.., i]);

            // Find best class
            let (class_id, &confidence) = class_scores
                .iter()
                .enumerate()
                .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
                .unwrap();

            if confidence < self.confidence_threshold {
                continue;
            }

            // Undo letterbox: remove padding, then scale back to original image space
            let x0 = (cx - w / 2.0) - lb.pad_x;
            let y0 = (cy - h / 2.0) - lb.pad_y;
            let bbox = BoundingBox {
                x: x0.max(0.0) / lb.scale,
                y: y0.max(0.0) / lb.scale,
                width: (w).max(0.0) / lb.scale,
                height: (h).max(0.0) / lb.scale,
            };

            let class_name = match self.model_type {
                ModelType::Coco => COCO_CLASSES.get(class_id).unwrap_or(&"unknown").to_string(),
                ModelType::Oiv7 => {
                    if let Some(ref classes) = self.oiv7_classes {
                        classes
                            .get(class_id)
                            .unwrap_or(&"unknown".to_string())
                            .clone()
                    } else {
                        format!("class_{}", class_id)
                    }
                }
            };

            detections.push(Detection {
                class: class_name,
                class_id,
                confidence,
                bbox,
            });
        }

        Ok(detections)
    }

    /// Apply Non-Maximum Suppression to remove overlapping detections
    fn non_max_suppression(&self, mut detections: Vec<Detection>) -> Vec<Detection> {
        // Sort by confidence
        detections.sort_by(|a, b| b.confidence.partial_cmp(&a.confidence).unwrap());

        let mut keep = Vec::new();
        let mut suppressed = vec![false; detections.len()];

        for i in 0..detections.len() {
            if suppressed[i] {
                continue;
            }

            keep.push(detections[i].clone());

            // Suppress overlapping detections
            for j in (i + 1)..detections.len() {
                if suppressed[j] || detections[i].class_id != detections[j].class_id {
                    continue;
                }

                let iou = self.calculate_iou(&detections[i].bbox, &detections[j].bbox);
                if iou > self.nms_threshold {
                    suppressed[j] = true;
                }
            }
        }

        keep
    }

    /// Calculate Intersection over Union for two bounding boxes
    fn calculate_iou(&self, box1: &BoundingBox, box2: &BoundingBox) -> f32 {
        let x1 = box1.x.max(box2.x);
        let y1 = box1.y.max(box2.y);
        let x2 = (box1.x + box1.width).min(box2.x + box2.width);
        let y2 = (box1.y + box1.height).min(box2.y + box2.height);

        if x2 < x1 || y2 < y1 {
            return 0.0;
        }

        let intersection = (x2 - x1) * (y2 - y1);
        let area1 = box1.width * box1.height;
        let area2 = box2.width * box2.height;
        let union = area1 + area2 - intersection;

        intersection / union
    }

    /// Simple heuristic to detect text patterns
    fn detect_text_patterns(&self, image: &RgbImage) -> bool {
        let (width, height) = image.dimensions();
        let sample_size = 100;

        // Sample some pixels
        let mut uniform_regions = 0;
        for _ in 0..sample_size {
            let x = rand::random::<u32>() % width.max(1);
            let y = rand::random::<u32>() % height.max(1);

            if x > 0 && y > 0 && x < width - 1 && y < height - 1 {
                let center = image.get_pixel(x, y);
                let neighbors = [
                    image.get_pixel(x - 1, y),
                    image.get_pixel(x + 1, y),
                    image.get_pixel(x, y - 1),
                    image.get_pixel(x, y + 1),
                ];

                let uniform = neighbors.iter().all(|n| {
                    let diff = ((center[0] as i32 - n[0] as i32).abs()
                        + (center[1] as i32 - n[1] as i32).abs()
                        + (center[2] as i32 - n[2] as i32).abs())
                        as u32;
                    diff < 30
                });

                if uniform {
                    uniform_regions += 1;
                }
            }
        }

        // If many uniform regions, likely text
        uniform_regions > sample_size / 3
    }

    /// Simple heuristic to detect animal patterns
    fn detect_animal_patterns(&self, image: &RgbImage) -> bool {
        let (width, height) = image.dimensions();
        let mut brown_pixels = 0;
        let mut texture_variation = 0;
        let sample_size = 500;

        for _ in 0..sample_size {
            let x = rand::random::<u32>() % width.max(1);
            let y = rand::random::<u32>() % height.max(1);

            let pixel = image.get_pixel(x, y);

            // Check for brown/tan colors (common in animals)
            if pixel[0] > 100
                && pixel[0] < 200
                && pixel[1] > 80
                && pixel[1] < 180
                && pixel[2] > 60
                && pixel[2] < 160
                && pixel[0] > pixel[2]
            {
                brown_pixels += 1;
            }

            // Check texture variation
            if x > 0 && y > 0 && x < width - 1 && y < height - 1 {
                let neighbors = [
                    image.get_pixel(x - 1, y),
                    image.get_pixel(x + 1, y),
                    image.get_pixel(x, y - 1),
                    image.get_pixel(x, y + 1),
                ];

                let max_diff = neighbors
                    .iter()
                    .map(|n| {
                        ((pixel[0] as i32 - n[0] as i32).abs()
                            + (pixel[1] as i32 - n[1] as i32).abs()
                            + (pixel[2] as i32 - n[2] as i32).abs()) as u32
                    })
                    .max()
                    .unwrap_or(0);

                if max_diff > 20 && max_diff < 100 {
                    texture_variation += 1;
                }
            }
        }

        // Animal detected if significant brown pixels and texture
        brown_pixels > sample_size / 10 && texture_variation > sample_size / 5
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_iou_calculation() {
        let detector = YoloDetector::new(None).unwrap();

        let box1 = BoundingBox {
            x: 0.0,
            y: 0.0,
            width: 100.0,
            height: 100.0,
        };
        let box2 = BoundingBox {
            x: 50.0,
            y: 50.0,
            width: 100.0,
            height: 100.0,
        };

        let iou = detector.calculate_iou(&box1, &box2);
        assert!((iou - 0.142857).abs() < 0.01); // 2500 / 17500
    }
}
