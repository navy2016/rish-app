//! The read-only tools a workspace exposes to JavaScript, and what their
//! options may be.
//!
//! Ported from `LWToolNameValid`, `LWToolOptionsValid` and the byte bound in
//! `LocalWorkspaceModule.mm`.
//!
//! **The tool list is closed, and that is the point.** These run against a
//! folder a person granted, so the surface is six named readers and nothing
//! else — not "any command", not a pattern that happens to start with one of
//! them. An option key the host does not recognise is refused rather than
//! ignored, because ignoring it would run a different command than the caller
//! asked for and report success.

use serde_json::{json, Map, Value};

use crate::schema::{safe_integer, MAX_SAFE_INTEGER};

/// Every tool a workspace will run. Closed.
pub const TOOLS: &[&str] = &["cat", "grep", "head", "tail", "wc", "sha256sum"];

/// Every option any of them takes. Also closed.
pub const OPTION_KEYS: &[&str] = &["lines", "metric", "pattern", "case_insensitive"];

/// What `wc` can count.
pub const METRICS: &[&str] = &["lines", "words", "bytes"];

/// `head`/`tail` will not return more lines than this.
pub const MAX_LINES: u64 = 1000;

/// A `grep` pattern is at most this many bytes.
pub const MAX_PATTERN_BYTES: usize = 1024;

/// A tool will not return more output than this.
pub const MAX_OUTPUT_BYTES: usize = 256 * 1024;

/// `LWToolNameValid`.
pub fn tool_name_valid(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|name| TOOLS.contains(&name))
}

/// `LWToolOptionsValid`.
///
/// Each option is optional; what is *not* optional is that every key present
/// is one of the four and every value is the shape that key takes.
pub fn tool_options_valid(options: Option<&Value>) -> bool {
    let Some(Value::Object(map)) = options else {
        return false;
    };
    if !map.keys().all(|key| OPTION_KEYS.contains(&key.as_str())) {
        return false;
    }
    if let Some(lines) = map.get("lines") {
        match safe_integer(Some(lines), MAX_SAFE_INTEGER, false) {
            Some(count) if count <= MAX_LINES => {}
            _ => return false,
        }
    }
    if let Some(metric) = map.get("metric") {
        if !metric.as_str().is_some_and(|name| METRICS.contains(&name)) {
            return false;
        }
    }
    if let Some(pattern) = map.get("pattern") {
        match pattern.as_str() {
            Some(text) if !text.is_empty() && text.len() <= MAX_PATTERN_BYTES => {}
            _ => return false,
        }
    }
    if let Some(insensitive) = map.get("case_insensitive") {
        if !insensitive.is_boolean() {
            return false;
        }
    }
    true
}

/// `LWBytesFromArray`'s bound: output crosses the bridge as an array of byte
/// values, and one longer than this is not output this engine produced.
pub fn output_length_valid(length: Option<u64>) -> bool {
    length.is_some_and(|value| value <= MAX_OUTPUT_BYTES as u64)
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see
/// `rish_agent_workspace_read_tools_reduce`.
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
        "tool_name_valid" => json!({
            "ok": true, "valid": tool_name_valid(envelope.get("value"))
        }),
        "tool_options_valid" => json!({
            "ok": true, "valid": tool_options_valid(envelope.get("options"))
        }),
        "output_length_valid" => json!({
            "ok": true,
            "valid": output_length_valid(envelope.get("length").and_then(Value::as_u64)),
        }),
        "tools" => json!({ "ok": true, "tools": TOOLS }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_read_tools_tests.rs"]
mod tests;
