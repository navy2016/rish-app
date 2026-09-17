//! Runtime-environment identity and manifest rules.
//!
//! Mirrors the free functions in
//! `modules/rish/ios/Sources/RuntimeEnvironmentPackage.mm`. The host still
//! owns every mechanism those functions sit beside -- creating directories,
//! measuring capacity, protecting files, hashing, streaming a package -- and
//! this module owns only what makes an identity or a manifest acceptable.
//!
//! Two Foundation behaviours are reproduced here rather than corrected,
//! because correcting them would change what the shipping app accepts:
//!
//! * `Integer()` reads `doubleValue` and asks `floor(n) == n`, so a manifest
//!   writing `1048576.0` is accepted. `schema::safe_integer` rejects that --
//!   it asks serde for a `u64` -- so these bounds are checked here instead.
//! * `Text()` bounds `NSString.length`, which counts **UTF-16 code units**,
//!   not characters and not bytes. An 80-character CJK name is 80 units and
//!   240 UTF-8 bytes; bounding bytes would refuse a name the app accepts.

use crate::schema::{canonical_sha256, canonical_uuid, exact_keys};
use crate::workspace_tool::path_control_or_format;
use serde_json::{json, Map, Value};

/// The families a manifest may name, in the order the ObjC literal lists them.
pub const FAMILIES: [&str; 6] = ["python", "java", "go", "rust", "bun", "node"];

/// `architecture` is not a choice: the guest is an interpreted x86_64 machine.
pub const ARCHITECTURE: &str = "x86_64";

const MAX_ID_UNITS: usize = 96;
const MAX_DISPLAY_NAME_UNITS: usize = 80;
const MAX_VERSION_UNITS: usize = 64;
const MAX_URL_UNITS: usize = 4096;
const MIN_DISK_BYTES: u64 = 1024 * 1024;
const MAX_DISK_BYTES: u64 = 4 * 1024 * 1024 * 1024;
const DISK_BYTES_ALIGNMENT: u64 = 512;
const MIN_MEMORY_MIB: u64 = 256;
const MAX_MEMORY_MIB: u64 = 1024;

/// Whether any UTF-16 code unit is a member of `controlCharacterSet`.
///
/// Foundation's `rangeOfCharacterFromSet:` tests one `unichar` at a time, so a
/// format character outside the BMP arrives as two surrogates and neither is a
/// member: such a string passes. Scanning scalars instead would refuse it.
/// Reproducing the loophole is the point; see `content_decision`, which walks
/// units for the same reason.
fn has_control_unit(text: &str) -> bool {
    text.encode_utf16().any(|unit| {
        // Surrogates are category Cs, which controlCharacterSet does not hold.
        if (0xd800..=0xdfff).contains(&unit) {
            return false;
        }
        char::from_u32(u32::from(unit)).is_some_and(path_control_or_format)
    })
}

/// `Text(value, max)`: a non-empty string of at most `maximum_units` UTF-16
/// code units carrying no control or format character.
fn display_text(value: Option<&Value>, maximum_units: usize) -> bool {
    let Some(Value::String(text)) = value else {
        return false;
    };
    let units = text.encode_utf16().count();
    units > 0 && units <= maximum_units && !has_control_unit(text)
}

/// `Integer(value, min, max)`: a non-boolean number that is finite, integral,
/// and inside the closed range. **Integral floats count**, which is where this
/// parts company with `schema::safe_integer`.
fn integral_in_range(value: Option<&Value>, minimum: u64, maximum: u64) -> Option<u64> {
    let Some(Value::Number(number)) = value else {
        return None;
    };
    // serde keeps `true` as Value::Bool, so the CFBoolean guard the ObjC needs
    // has no counterpart here; a JSON boolean never reaches this arm.
    let candidate = if let Some(integer) = number.as_u64() {
        integer
    } else {
        let double = number.as_f64()?;
        if !double.is_finite() || double.floor() != double || double < 0.0 {
            return None;
        }
        // Above 2^64 a float cannot name an integer the bounds could accept.
        if double > u64::MAX as f64 {
            return None;
        }
        double as u64
    };
    (candidate >= minimum && candidate <= maximum).then_some(candidate)
}

/// `DSHEnvironmentValidId`: `^[a-z0-9][a-z0-9-]*$`, at most 96 units.
///
/// The bound is checked before the pattern in the ObjC, but both refuse the
/// same strings: every character the pattern allows is one UTF-16 unit, so the
/// count cannot disagree with the length for anything that reaches it.
pub fn valid_environment_id(value: Option<&Value>) -> bool {
    let Some(Value::String(text)) = value else {
        return false;
    };
    let mut characters = text.chars();
    let Some(first) = characters.next() else {
        return false;
    };
    text.encode_utf16().count() <= MAX_ID_UNITS
        && first.is_ascii_lowercase() | first.is_ascii_digit()
        && characters.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// The **program** side's spelling of the same idea, and it is not the same
/// rule: `ValidStart` in `RuntimeProgramService.mm` tests membership of
/// `[a-z0-9-]` over the whole string, so it accepts a leading `-` and accepts
/// `---`, both of which `valid_environment_id` refuses.
///
/// No catalogued environment can carry such an id -- every manifest is checked
/// with the anchored rule -- so a start naming one fails later as a missing
/// environment rather than an invalid request. The two spellings are kept
/// apart here so that unifying them is a decision someone makes on purpose,
/// with this test going red, rather than a silent consequence of the move.
pub fn valid_program_environment_id(value: Option<&Value>) -> bool {
    let Some(Value::String(text)) = value else {
        return false;
    };
    let units = text.encode_utf16().count();
    units > 0
        && units <= MAX_ID_UNITS
        && text
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

/// `DSHEnvironmentValidWorkspaceId`. The ObjC runs the 8-4-4-4-12 lowercase-hex
/// pattern **and** then parses with `NSUUID`; the parse cannot refuse anything
/// the pattern accepted, so it is redundant by construction and only the
/// pattern is reproduced. Said out loud so the missing parse reads as
/// deliberate rather than dropped.
pub fn valid_workspace_id(value: Option<&Value>) -> bool {
    canonical_uuid(value)
}

/// `DSHEnvironmentValidHTTPSURL`, over components the host has already parsed.
///
/// The parse stays on the host on purpose. `NSURLComponents` is what decides
/// today what counts as a host or a fragment, and a Rust URL parser does not
/// answer those questions identically; swapping it in would change which
/// downloads are accepted without anything saying so. The host sends what it
/// parsed, and the rule about those parts lives here.
///
/// Expected shape:
/// `{"text": "https://...", "parsed": true, "scheme": "https",
///   "host": "example.com", "has_user": false, "has_password": false,
///   "has_fragment": false}`
/// A component Foundation reported as absent is `null`, never `""`: the ObjC
/// asks `parts.user == nil`, and an empty user is not an absent one.
pub fn valid_https_url(projection: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        projection,
        &[
            "text",
            "parsed",
            "scheme",
            "host",
            "has_user",
            "has_password",
            "has_fragment",
        ],
    ) else {
        return false;
    };
    let Some(Value::String(text)) = map.get("text") else {
        return false;
    };
    // The ObjC bounds the string and scans it for control characters before it
    // parses anything, so a refusal here never depended on the parse.
    if text.encode_utf16().count() > MAX_URL_UNITS || has_control_unit(text) {
        return false;
    }
    if map.get("parsed") != Some(&json!(true)) {
        return false;
    }
    if map.get("scheme") != Some(&json!("https")) {
        return false;
    }
    let host_present = matches!(map.get("host"), Some(Value::String(host)) if !host.is_empty());
    host_present
        && map.get("has_user") == Some(&json!(false))
        && map.get("has_password") == Some(&json!(false))
        && map.get("has_fragment") == Some(&json!(false))
}

/// `DSHEnvironmentValidateManifest`. Exactly ten keys, and every one of them
/// checked; `kernel_sha256` must equal the kernel this build actually carries,
/// which is why the digest is an argument rather than a constant.
pub fn validate_manifest(value: Option<&Value>, kernel_sha256: &str) -> bool {
    let Some(map) = exact_keys(
        value,
        &[
            "schema_version",
            "environment_id",
            "family",
            "display_name",
            "version",
            "architecture",
            "kernel_sha256",
            "disk_sha256",
            "disk_bytes",
            "minimum_memory_mib",
        ],
    ) else {
        return false;
    };
    let Some(disk_bytes) = integral_in_range(map.get("disk_bytes"), MIN_DISK_BYTES, MAX_DISK_BYTES)
    else {
        return false;
    };
    integral_in_range(map.get("schema_version"), 1, 1).is_some()
        && valid_environment_id(map.get("environment_id"))
        && matches!(map.get("family"), Some(Value::String(family)) if FAMILIES.contains(&family.as_str()))
        && display_text(map.get("display_name"), MAX_DISPLAY_NAME_UNITS)
        && display_text(map.get("version"), MAX_VERSION_UNITS)
        && map.get("architecture") == Some(&json!(ARCHITECTURE))
        && matches!(map.get("kernel_sha256"), Some(Value::String(digest)) if digest == kernel_sha256)
        && canonical_sha256(map.get("disk_sha256"))
        // A disk is addressed in sectors; a length that is not a whole number
        // of them describes no disk the guest could mount.
        && disk_bytes % DISK_BYTES_ALIGNMENT == 0
        && integral_in_range(
            map.get("minimum_memory_mib"),
            MIN_MEMORY_MIB,
            MAX_MEMORY_MIB,
        )
        .is_some()
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_runtime_environment_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    Some(match text(envelope, "op")? {
        "valid_environment_id" => json!({
            "ok": true, "valid": valid_environment_id(envelope.get("value"))
        }),
        "valid_program_environment_id" => json!({
            "ok": true, "valid": valid_program_environment_id(envelope.get("value"))
        }),
        "valid_workspace_id" => json!({
            "ok": true, "valid": valid_workspace_id(envelope.get("value"))
        }),
        "valid_https_url" => json!({
            "ok": true, "valid": valid_https_url(envelope.get("value"))
        }),
        "validate_manifest" => json!({
            "ok": true,
            "valid": validate_manifest(
                envelope.get("value"),
                text(envelope, "kernel_sha256")?,
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "runtime_environment_tests.rs"]
mod tests;
