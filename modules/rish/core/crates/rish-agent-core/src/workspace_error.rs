//! Which workspace failure a caller is told about, and in what words.
//!
//! Ported from `DSHWorkspacePublicCode` and `DSHWorkspacePublicMessage` in
//! `LocalWorkspaceAccess.mm`.
//!
//! This is a rule and not a lookup table by accident. The public code is what
//! the JS layer branches on and what a person's retry depends on, so the
//! mapping from an internal failure to a public one is part of the contract:
//! `E_WORKSPACE_CONFLICT` says "try again", `E_WORKSPACE_PERSISTENCE` says
//! "this store cannot be read", and a caller that cannot tell them apart
//! cannot behave correctly. Both platforms have to answer alike, so the table
//! lives here.
//!
//! **The messages are not localisation.** They are the fixed English fallback
//! the native layer attaches; the product's own translated strings are chosen
//! in the UI from the code, never from this text.

use serde_json::{json, Map, Value};

/// Every workspace failure, in the numeric order the stored enum fixes. The
/// numbers are on the wire between the host and its callers, so the order is
/// not free — a code inserted in the middle would renumber everything after it.
pub const FAILURES: &[(u64, &str, &str)] = &[
    (1, "E_WORKSPACE_INVALID", "Workspace request is invalid."),
    (2, "E_WORKSPACE_NOT_FOUND", "Workspace is not available."),
    (3, "E_WORKSPACE_BUSY", "Workspace storage is busy."),
    (
        4,
        "E_WORKSPACE_PICKER_BUSY",
        "Another workspace picker operation is active.",
    ),
    (
        5,
        "E_WORKSPACE_SELECTION_EXPIRED",
        "Workspace picker selection has expired.",
    ),
    (
        6,
        "E_WORKSPACE_REVISION_STALE",
        "Workspace binding is stale.",
    ),
    (
        7,
        "E_WORKSPACE_REVISION_OVERFLOW",
        "Workspace binding cannot be advanced.",
    ),
    (
        8,
        "E_WORKSPACE_STATUS_STALE",
        "Workspace authority is stale.",
    ),
    (9, "E_WORKSPACE_REVOKED", "Workspace authority was revoked."),
    (10, "E_WORKSPACE_UNAVAILABLE", "Workspace is unavailable."),
    (
        11,
        "E_WORKSPACE_NOT_DOWNLOADED",
        "Workspace content is not downloaded.",
    ),
    (
        12,
        "E_WORKSPACE_IMPORT_REQUIRED",
        "Workspace import is required.",
    ),
    (
        13,
        "E_WORKSPACE_CAPABILITY",
        "Workspace capability is unavailable.",
    ),
    (14, "E_WORKSPACE_ROOT_CHANGED", "Workspace root changed."),
    (
        15,
        "E_WORKSPACE_REFERENCED",
        "Workspace is still referenced.",
    ),
    (
        16,
        "E_WORKSPACE_CONFIRMATION",
        "Workspace confirmation is invalid.",
    ),
    (
        17,
        "E_WORKSPACE_CONFLICT",
        "Workspace storage changed concurrently.",
    ),
    (
        18,
        "E_WORKSPACE_PERSISTENCE",
        "Workspace storage is invalid.",
    ),
    (19, "E_WORKSPACE_IO", "Workspace operation failed."),
];

fn entry(code: u64) -> Option<&'static (u64, &'static str, &'static str)> {
    FAILURES.iter().find(|(number, _, _)| *number == code)
}

/// `DSHWorkspacePublicCode`. `None` for a number that is not a failure this
/// engine defines — the host has no code to report, and inventing one would
/// let a caller branch on a failure that does not exist.
pub fn public_code(code: Option<u64>) -> Option<&'static str> {
    entry(code?).map(|(_, name, _)| *name)
}

/// `DSHWorkspacePublicMessage`.
pub fn public_message(code: Option<u64>) -> Option<&'static str> {
    entry(code?).map(|(_, _, message)| *message)
}

/// Both at once, which is how the host builds an `NSError`'s user info.
pub fn projection(code: Option<u64>) -> Option<Value> {
    let (_, name, message) = entry(code?)?;
    Some(json!({ "code": name, "message": message }))
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_error_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    let code = envelope.get("code").and_then(Value::as_u64);
    Some(match text(envelope, "op")? {
        "projection" => json!({ "ok": true, "projection": projection(code) }),
        "codes" => json!({
            "ok": true,
            "codes": FAILURES
                .iter()
                .map(|(number, name, message)| json!({
                    "code": number, "name": name, "message": message
                }))
                .collect::<Vec<Value>>(),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_error_tests.rs"]
mod tests;
