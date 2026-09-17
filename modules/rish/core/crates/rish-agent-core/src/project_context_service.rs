//! How a project-context snapshot is named, and what a caller's v2 arguments
//! have to be.
//!
//! Ported from `DSHServiceV2RootRef`, `DSHServiceV2RootsEqual`,
//! `DSHServiceV2BoundedString`, `DSHServiceCanonicalDigest` and
//! `DSHServiceV2ReferenceId` in `ProjectContextService.mm`.
//!
//! **The reference id is derived, not chosen.** `ProjectContextStore` names a
//! prepare transaction by the suffix of an `active:<uuid>` key, so if that
//! uuid were simply the conversation's, two workspaces using the same
//! conversation id could evict or authorise one another's snapshot. It is
//! instead a digest over the whole authority tuple — root, root fingerprint,
//! conversation — shaped into a UUID. It is private and never returned to
//! JavaScript.
//!
//! The root reference rule is **not** re-stated here: it is the same rule
//! `project_access` owns, and this file used to carry a second copy of it.

use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};

use crate::canonical::canonical_json;
use crate::project_access::canonical_root_ref;
use crate::workspace_tool::path_control_or_format;

/// The domain this id is derived under. Changing it renames every snapshot.
pub const REFERENCE_DOMAIN: &str = "rish.project-context-reference.v2";

/// `DSHServiceCanonicalDigest`.
pub fn canonical_digest(value: Option<&Value>) -> bool {
    value.and_then(Value::as_str).is_some_and(|text| {
        text.len() == 64
            && text
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

/// `DSHServiceV2BoundedString`: a string within a byte bound and free of
/// control or format characters.
pub fn bounded_string(value: Option<&Value>, max_bytes: usize, allow_empty: bool) -> bool {
    let Some(text) = value.and_then(Value::as_str) else {
        return false;
    };
    text.len() <= max_bytes
        && (allow_empty || !text.is_empty())
        && !text.chars().any(path_control_or_format)
}

/// `DSHServiceV2RootsEqual`: two roots are the same root when their canonical
/// forms are equal. Comparing the given dictionaries would let key order or a
/// differently spelled revision make one root look like two.
pub fn roots_equal(left: Option<&Value>, right: Option<&Value>) -> bool {
    match (canonical_root_ref(left), canonical_root_ref(right)) {
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// `DSHServiceV2ReferenceId`.
///
/// The digest's first sixteen bytes become the id, with the version and
/// variant bits set so it is a well-formed UUID rather than sixteen bytes that
/// merely look like one — `ProjectContextStore` checks that it is.
pub fn reference_id(
    root: Option<&Value>,
    root_fingerprint: Option<&Value>,
    conversation_id: Option<&Value>,
) -> Option<String> {
    let root = canonical_root_ref(root)?;
    if !canonical_digest(root_fingerprint) {
        return None;
    }
    let conversation = conversation_id.and_then(Value::as_str)?;
    if !crate::project_context_store::canonical_snapshot_id(conversation) {
        return None;
    }
    let body = canonical_json(&json!({
        "root": root,
        "root_fingerprint_sha256": root_fingerprint,
        "conversation_id": conversation,
    }))
    .ok()?;
    let mut hasher = Sha256::new();
    hasher.update(REFERENCE_DOMAIN.as_bytes());
    hasher.update([0u8]);
    hasher.update(&body);
    let mut digest: [u8; 32] = hasher.finalize().into();
    digest[6] = (digest[6] & 0x0f) | 0x40;
    digest[8] = (digest[8] & 0x3f) | 0x80;
    let hex = |range: std::ops::Range<usize>| {
        digest[range]
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>()
    };
    Some(format!(
        "{}-{}-{}-{}-{}",
        hex(0..4),
        hex(4..6),
        hex(6..8),
        hex(8..10),
        hex(10..16)
    ))
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see
/// `rish_agent_project_context_service_reduce`.
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
        "reference_id" => json!({
            "ok": true,
            "reference_id": reference_id(
                envelope.get("root"),
                envelope.get("root_fingerprint_sha256"),
                envelope.get("conversation_id"),
            ),
        }),
        "roots_equal" => json!({
            "ok": true,
            "equal": roots_equal(envelope.get("left"), envelope.get("right")),
        }),
        "canonical_digest" => json!({
            "ok": true, "valid": canonical_digest(envelope.get("value"))
        }),
        "bounded_string" => json!({
            "ok": true,
            "valid": bounded_string(
                envelope.get("value"),
                envelope.get("max_bytes").and_then(Value::as_u64)? as usize,
                envelope.get("allow_empty") == Some(&json!(true)),
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "project_context_service_tests.rs"]
mod tests;
