//! What a project-context result may say, at the bridge to JavaScript.
//!
//! Ported from `DSHPCSafeRelativePath` and `DSHPCBoundedString` in
//! `LocalProjectContextModule.mm`. The identifier, digest and OID rules that
//! file also carried are the ones `project_module` owns, and are re-used
//! rather than restated.
//!
//! **This path rule is not `execution_ledger::relative_path_argument`**, and
//! the two are deliberately kept apart. That one bounds an agent's tool
//! argument at 512 bytes and demands NFC; this one bounds a *reported* path at
//! 4096 and does not, because it describes a file that already exists rather
//! than naming one to act on. It also refuses a `.` component and control
//! characters, which the other does not. Same shape, different surfaces, and
//! merging them would change what one of the two accepts.

use serde_json::{json, Map, Value};

use crate::workspace_tool::path_control_or_format;

/// A reported relative path is at most this many bytes.
pub const MAX_PATH_BYTES: usize = 4096;

/// `DSHPCBoundedString`.
pub fn bounded_string(value: Option<&Value>, maximum_bytes: usize, allow_empty: bool) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|text| text.len() <= maximum_bytes && (allow_empty || !text.is_empty()))
}

/// `DSHPCSafeRelativePath`: a path *inside* the project, described rather than
/// commanded. No leading slash, no backslash, no NUL, no control or format
/// characters, and every component a real name — an empty, `.` or `..`
/// component would describe somewhere else.
pub fn safe_relative_path(value: Option<&Value>) -> bool {
    let Some(path) = value.and_then(Value::as_str) else {
        return false;
    };
    if path.is_empty()
        || path.len() > MAX_PATH_BYTES
        || path.starts_with('/')
        || path.contains('\\')
        || path.contains('\0')
        || path.chars().any(path_control_or_format)
    {
        return false;
    }
    path.split('/')
        .all(|component| !component.is_empty() && component != "." && component != "..")
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see
/// `rish_agent_project_context_bridge_reduce`.
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
        "safe_relative_path" => json!({
            "ok": true, "valid": safe_relative_path(envelope.get("value"))
        }),
        "bounded_string" => json!({
            "ok": true,
            "valid": bounded_string(
                envelope.get("value"),
                envelope.get("maximum_bytes").and_then(Value::as_u64)? as usize,
                envelope.get("allow_empty") == Some(&json!(true)),
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "project_context_bridge_tests.rs"]
mod tests;
