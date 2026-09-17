//! Where a path stops being the app's own container and starts being a place
//! inside it.
//!
//! Ported from `DSHIsCanonicalUUIDText`, `DSHComponentsEndWithAppContainer`,
//! `DSHLastAppContainerComponentIndex`, `DSHComponentsHavePrefix`,
//! `DSHComponentsContainTraversal` and
//! `DSHContainerAnchorSegmentCountForPaths` in `LocalProjectAccess.mm`.
//!
//! **This exists because guessing path shape got it wrong on real devices.**
//! The walker used to scan for an `Application` component followed by
//! `Application Support`, which never matches
//! `/private/var/mobile/Containers/Data/Application/<UUID>/…` — so it fell
//! back to opening `/private/var`, which the sandbox refuses. The anchor is
//! derived from the container root the host was given instead.
//!
//! The two layouts share one tail:
//!
//! - device: `/private/var/mobile/Containers/Data/Application/<UUID>/…`
//! - simulator: `…/CoreSimulator/Devices/<uuid>/data/Containers/Data/Application/<uuid>/…`
//!
//! The simulator path contains *two* UUIDs, so the **innermost** match wins:
//! the CoreSimulator device is not this app's container.
//!
//! Splitting a path into components stays with the host — `pathComponents` is
//! Foundation's, and it keeps a leading `"/"` that a naive split would not.

use serde_json::{json, Map, Value};

/// The component sequence that ends every app container path.
pub const CONTAINER_TAIL: &[&str] = &["Containers", "Data", "Application"];

/// `DSHIsCanonicalUUIDText`: 36 characters, and the canonical spelling of the
/// UUID it parses as. A container directory is named by the system, so
/// anything else in that position was not put there by the system.
pub fn canonical_uuid_text(component: &str) -> bool {
    let bytes = component.as_bytes();
    if bytes.len() != 36 {
        return false;
    }
    for (index, byte) in bytes.iter().enumerate() {
        let expected_dash = matches!(index, 8 | 13 | 18 | 23);
        if expected_dash {
            if *byte != b'-' {
                return false;
            }
        } else if !byte.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

/// `DSHComponentsEndWithAppContainer`: whether `components[index]` is the
/// container UUID of a `Containers/Data/Application/<UUID>` tail.
pub fn ends_with_app_container(components: &[String], index: usize) -> bool {
    if index < CONTAINER_TAIL.len() {
        return false;
    }
    CONTAINER_TAIL
        .iter()
        .enumerate()
        .all(|(offset, name)| components[index - CONTAINER_TAIL.len() + offset] == *name)
        && canonical_uuid_text(&components[index])
}

/// `DSHLastAppContainerComponentIndex`: the innermost such tail. The
/// simulator's path holds a CoreSimulator device UUID further up, and choosing
/// it would anchor the walk outside this app's container.
pub fn last_app_container_index(components: &[String]) -> Option<usize> {
    (0..components.len())
        .rev()
        .find(|index| ends_with_app_container(components, *index))
}

/// `DSHComponentsContainTraversal`. Refused at derivation time as well as
/// during the walk, so an anchor is never *derived* from a traversal-shaped
/// path in the first place.
pub fn contains_traversal(components: &[String]) -> bool {
    components.iter().any(|part| part == "." || part == "..")
}

fn has_prefix(components: &[String], prefix: &[String]) -> bool {
    prefix.len() <= components.len() && components[..prefix.len()] == *prefix
}

/// `DSHContainerAnchorSegmentCountForPaths`: how many components of `target`
/// are the container root, or `None` when `target` is not inside a container
/// root the host can prove.
///
/// The container root must *end* at its own app-container UUID. A root that
/// carries anything after it is not a container root, and anchoring there
/// would let the walk start somewhere the caller chose.
pub fn anchor_segment_count(target: &[String], container_root: &[String]) -> Option<usize> {
    if contains_traversal(target) || contains_traversal(container_root) {
        return None;
    }
    let index = last_app_container_index(container_root)?;
    if index + 1 != container_root.len() || !has_prefix(target, container_root) {
        return None;
    }
    Some(index)
}

/// `DSHContainerRootScanSegmentCount`: the anchor for a path with no root to
/// check it against — used where the host has only the target. It is the same
/// rule minus the containment check, so a traversal-shaped path still has no
/// anchor.
pub fn scan_segment_count(target: &[String]) -> Option<usize> {
    if contains_traversal(target) {
        return None;
    }
    last_app_container_index(target)
}

fn components(value: Option<&Value>) -> Option<Vec<String>> {
    value?
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_container_anchor_reduce`.
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
        "anchor_segment_count" => {
            let target = components(envelope.get("target"))?;
            let root = components(envelope.get("container_root"))?;
            json!({
                "ok": true,
                "segments": anchor_segment_count(&target, &root),
            })
        }
        "scan_segment_count" => {
            let target = components(envelope.get("target"))?;
            json!({ "ok": true, "segments": scan_segment_count(&target) })
        }
        "last_app_container_index" => {
            let parts = components(envelope.get("components"))?;
            json!({ "ok": true, "index": last_app_container_index(&parts) })
        }
        "canonical_uuid_text" => json!({
            "ok": true, "valid": canonical_uuid_text(text(envelope, "value")?)
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "container_anchor_tests.rs"]
mod tests;
