//! Conditional bridge to the optional `serde` dependency.
//!
//! The layout port is a zero-dependency package by default, mirroring Taffy's
//! default feature set in which `serde` is off. Build with `-Dserde=true` to
//! compile the Taffy-compatible JSON support in `serde_hooks.zig`.
//!
//! Type files reference the helpers here when declaring their `serde` options
//! and hooks. The initializers are lazily analyzed, so a default build never
//! resolves `@import("serde")` inside `serde_hooks.zig`.

// Namespaced so embedding this package as a dependency cannot collide
// with a consumer module import of the same conventional name.
const zlay_options = @import("zlay_options");

pub const enabled = zlay_options.serde;

/// Real implementations when enabled; an empty namespace when disabled.
pub const impl = if (enabled) @import("serde_hooks.zig") else struct {};

/// `rename_all = .pascal_case`, matching Rust's serde derive on Taffy enums.
pub const pascal_options = if (enabled) impl.pascal_options else {};

/// Generic hook forwarders; assigned to `zerdeSerialize` / `zerdeDeserialize`
/// declarations on the types that need a custom wire representation.
pub const serialize = if (enabled) impl.serialize else {};
pub const deserialize = if (enabled) impl.deserialize else {};

/// Named grid line payloads, which upstream models as tuple variants and
/// therefore serialize as two-element arrays rather than objects.
pub const serializeNamedLine = if (enabled) impl.serializeNamedLine else {};
pub const serializeNamedSpan = if (enabled) impl.serializeNamedSpan else {};
pub const deserializeNamedLine = if (enabled) impl.deserializeNamedLine else {};
pub const deserializeNamedSpan = if (enabled) impl.deserializeNamedSpan else {};
