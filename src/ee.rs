// Bridge module to include enterprise (EE) code that lives outside `src/`
// All EE modules are compiled only when the `ee` feature is enabled.

#![cfg(feature = "ee")]

// Pull in server handlers directly from the ee/ tree
#[path = "../ee/server/team_handlers.rs"]
pub mod team_handlers;

#[path = "../ee/server/auth_ee.rs"]
pub mod auth_ee;

#[path = "../ee/server/capabilities.rs"]
pub mod capabilities;

#[path = "../ee/server/shares.rs"]
pub mod shares;

#[path = "../ee/server/public_links.rs"]
pub mod public_links;

#[path = "../ee/server/settings.rs"]
pub mod settings;
