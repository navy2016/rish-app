//! The workspace executor's judgements: which paths it will touch, what a
//! revision is, what a directory listing looks like, and what a person is
//! shown before they approve a write.
//!
//! Ported from `AgentWorkspaceToolExecutor.mm`. The capability there is small
//! and entirely the host's — `openat` a directory descriptor, read and write
//! bytes, `fstatat` — and everything around it is rule. The approval diff is
//! the sharpest piece: it is what a person reads before they say yes, so two
//! copies of it would be two different things to approve.

use serde_json::{json, Map, Value};
use unicode_normalization::UnicodeNormalization;

use crate::canonical::{hash_bytes, hash_json};
use crate::schema::bounded_utf8;
use crate::store::StoreError;

/// A workspace-relative path is bounded, NFC, and names no reserved entry.
pub const MAX_PATH_BYTES: usize = 512;
/// `NAME_MAX` on Darwin and bionic alike.
const MAX_COMPONENT_BYTES: usize = 255;
/// Canonical-envelope headroom under the protected feedback cap.
pub const MAX_READ_BYTES: u64 = 60 * 1024;
const MAX_ENTRIES: usize = 1000;
/// The protected cap on anything a workspace tool reports.
const MAX_FEEDBACK_BYTES: usize = 64 * 1024;

/// How much of an existing file is read to build a preview. The host does the
/// reading, so it asks for this rather than holding its own copy.
pub const MAX_PRIOR_READ_BYTES: u64 = 64 * 1024;
const MAX_DIFF_LINES: usize = 2000;
const MAX_HUNK_LINES: usize = 24;
const MAX_CONTEXT_LINES: usize = 3;
const MAX_PREVIEW_BYTES: usize = 4096;

/// `DSHAgentWorkspacePathComponents`. The workspace root is the empty path; a
/// bare "." is accepted as the same root for a listing because models reach
/// for it first, and it never names an entry, so nothing below can be confused
/// with a "." component.
pub fn path_components(path: &str, allow_root: bool) -> Option<Vec<String>> {
    if path.len() > MAX_PATH_BYTES
        || path.nfc().ne(path.chars())
        || path.starts_with('/')
        || path.contains('\\')
        || path.contains('\0')
    {
        return None;
    }
    if path.is_empty() || (allow_root && path == ".") {
        return allow_root.then(Vec::new);
    }
    let mut components: Vec<String> = Vec::new();
    for component in path.split('/') {
        if component.is_empty()
            || component.len() > MAX_COMPONENT_BYTES
            || matches!(component, "." | ".." | ".git" | ".trash")
            || component.chars().any(path_control_or_format)
        {
            return None;
        }
        components.push(component.to_string());
    }
    Some(components)
}

// Unicode 16.0 General_Category=Cf, the format half of Foundation's
// documented control/format path constraint. Rust's is_control covers Cc only.
// https://www.unicode.org/Public/16.0.0/ucd/extracted/DerivedGeneralCategory.txt
// Do not reject adjacent marks, private-use or unassigned scalars.
pub fn path_control_or_format(c: char) -> bool {
    c.is_control()
        || matches!(c,
            '\u{00ad}' | '\u{0600}'..='\u{0605}' | '\u{061c}' | '\u{06dd}' |
            '\u{070f}' | '\u{0890}'..='\u{0891}' | '\u{08e2}' | '\u{180e}' |
            '\u{200b}'..='\u{200f}' | '\u{202a}'..='\u{202e}' |
            '\u{2060}'..='\u{2064}' | '\u{2066}'..='\u{206f}' | '\u{feff}' |
            '\u{fff9}'..='\u{fffb}' | '\u{110bd}' | '\u{110cd}' |
            '\u{13430}'..='\u{1343f}' | '\u{1bca0}'..='\u{1bca3}' |
            '\u{1d173}'..='\u{1d17a}' | '\u{e0001}' | '\u{e0020}'..='\u{e007f}')
}

/// `DSHAgentWorkspaceRevision`: opaque bounded file-state metadata, not a new
/// protocol digest. The host reads the numbers; their spelling is the rule.
pub fn revision(dev: u64, ino: u64, size: u64, mtime_sec: u64, mtime_nsec: u64) -> String {
    format!("{dev:x}:{ino:x}:{size:x}:{mtime_sec:x}:{mtime_nsec:x}")
}

/// Native metadata is never a tool result, so the same reserved names the
/// local-workspace path validator hides stay hidden here, case-folded.
/// Ordinary dotfiles such as `.gitignore` stay visible.
fn reserved(name: &str) -> bool {
    let folded = name.to_lowercase();
    folded == ".git"
        || folded == ".trash"
        || folded.starts_with(".staging-")
        || folded.starts_with(".rish-write-")
}

/// One directory entry as the host read it. `kind` is "file", "directory",
/// "invalid" for anything the host will not expose — a symlink, a device, a
/// hard-linked regular file, or an entry it could not stat — or "unnamed" for
/// a name that is not UTF-8.
struct Entry {
    name: String,
    kind: String,
    revision: String,
}

/// Decide one entry before the host reads the next one. With "uninspected"
/// metadata the result is "inspect"; this lets the host skip reserved names
/// and stop at capacity before doing any stat. The same decision is reused
/// after stat and by the final projection, so refusal priority cannot drift.
fn directory_entry_decision(
    entry: &Value,
    visible_count: usize,
) -> Result<&'static str, StoreError> {
    let kind = entry
        .get("kind")
        .and_then(Value::as_str)
        .ok_or(StoreError::InvalidArgument)?;
    if kind == "unnamed" {
        return Err(StoreError::InvalidArgument);
    }
    let name = bounded_utf8(entry.get("name"), MAX_PATH_BYTES, false)
        .ok_or(StoreError::InvalidArgument)?;
    if name == "." || name == ".." || reserved(name) {
        return Ok("skip");
    }
    if visible_count >= MAX_ENTRIES {
        return Err(StoreError::Capacity);
    }
    if kind == "uninspected" {
        return Ok("inspect");
    }
    if kind == "invalid" {
        return Err(StoreError::Conflict);
    }
    if (kind != "file" && kind != "directory") || name.nfc().ne(name.chars()) {
        return Err(StoreError::InvalidArgument);
    }
    bounded_utf8(entry.get("revision"), 256, false).ok_or(StoreError::InvalidArgument)?;
    Ok("include")
}

/// Hide reserved entries, validate the bounded observations, and construct the
/// public listing and fingerprint. The native walk uses the same incremental
/// decision to retain at most MAX_ENTRIES and stop at the first refusal.
pub fn directory_listing(entries: &[Value]) -> Result<Value, StoreError> {
    let mut visible: Vec<Entry> = Vec::new();
    for entry in entries {
        match directory_entry_decision(entry, visible.len())? {
            "skip" => continue,
            "include" => {}
            _ => return Err(StoreError::InvalidArgument),
        }
        visible.push(Entry {
            name: entry["name"]
                .as_str()
                .ok_or(StoreError::InvalidArgument)?
                .to_string(),
            kind: entry["kind"]
                .as_str()
                .ok_or(StoreError::InvalidArgument)?
                .to_string(),
            revision: entry["revision"]
                .as_str()
                .ok_or(StoreError::InvalidArgument)?
                .to_string(),
        });
    }
    // Byte order, not locale order: the fingerprint has to be the same on
    // every device that lists the same directory.
    visible.sort_by(|left, right| left.name.as_bytes().cmp(right.name.as_bytes()));
    let mut public: Vec<Value> = Vec::with_capacity(visible.len());
    let mut fingerprint: Vec<Value> = Vec::with_capacity(visible.len());
    for entry in &visible {
        let digest = hash_bytes("directory-name", entry.name.as_bytes())
            .ok_or(StoreError::InvalidArgument)?;
        public.push(json!({
            "schema_version": 1, "name": entry.name,
            "type": entry.kind, "revision": entry.revision,
        }));
        fingerprint.push(json!({
            "name_sha256": digest, "type": entry.kind, "revision": entry.revision,
        }));
    }
    let digest = hash_json("directory", &json!({ "entries": fingerprint }))
        .ok_or(StoreError::InvalidArgument)?;
    Ok(json!({ "entries": public, "directory_fingerprint_sha256": digest }))
}

/// A prior that is absent, or that the host could not decode as UTF-8, has no
/// preview: a preview of undecodable bytes would leak bytes, not text.
fn looks_binary(text: Option<&str>) -> bool {
    match text {
        None => true,
        Some(text) => text.contains('\0'),
    }
}

fn lines(text: &str) -> Vec<&str> {
    if text.is_empty() {
        Vec::new()
    } else {
        text.split('\n').collect()
    }
}

/// The result of building a preview: the text a person is shown, and whether
/// anything was left out of it.
pub struct Preview {
    pub diff: Option<String>,
    pub truncated: bool,
}

/// `DSHAgentApprovalUnifiedDiff`: an anchored prefix/suffix line diff under a
/// strict budget. `truncated` is only ever raised, never cleared, so a caller
/// whose prior read was already cut short keeps saying so.
pub fn diff_preview(prior: Option<&str>, next: &str, prior_truncated: bool) -> Preview {
    let mut truncated = prior_truncated;
    if looks_binary(prior) || looks_binary(Some(next)) {
        return Preview {
            diff: None,
            truncated,
        };
    }
    let prior = prior.unwrap_or_default();
    let mut prior_lines = lines(prior);
    let mut next_lines = lines(next);
    if prior_lines.len() > MAX_DIFF_LINES || next_lines.len() > MAX_DIFF_LINES {
        truncated = true;
        prior_lines.truncate(MAX_DIFF_LINES);
        next_lines.truncate(MAX_DIFF_LINES);
    }
    let mut prefix = 0;
    while prefix < prior_lines.len()
        && prefix < next_lines.len()
        && prior_lines[prefix] == next_lines[prefix]
    {
        prefix += 1;
    }
    let mut suffix = 0;
    while suffix < prior_lines.len() - prefix
        && suffix < next_lines.len() - prefix
        && prior_lines[prior_lines.len() - 1 - suffix] == next_lines[next_lines.len() - 1 - suffix]
    {
        suffix += 1;
    }
    let removed = prior_lines.len() - prefix - suffix;
    let added = next_lines.len() - prefix - suffix;
    if removed == 0 && added == 0 {
        return Preview {
            diff: Some(String::new()),
            truncated,
        };
    }
    let mut preview = format!("@@ -{},{removed} +{},{added} @@", prefix + 1, prefix + 1);
    let context_start = prefix.saturating_sub(MAX_CONTEXT_LINES);
    for line in &prior_lines[context_start..prefix] {
        preview.push_str(&format!("\n {line}"));
    }
    let hunk_truncated = removed > MAX_HUNK_LINES || added > MAX_HUNK_LINES;
    for line in &prior_lines[prefix..prefix + removed.min(MAX_HUNK_LINES)] {
        preview.push_str(&format!("\n-{line}"));
    }
    for line in &next_lines[prefix..prefix + added.min(MAX_HUNK_LINES)] {
        preview.push_str(&format!("\n+{line}"));
    }
    if hunk_truncated {
        preview.push_str("\n…");
    }
    let suffix_start = prefix + removed;
    let context_end = prior_lines.len().min(suffix_start + MAX_CONTEXT_LINES);
    for line in &prior_lines[suffix_start..context_end] {
        preview.push_str(&format!("\n {line}"));
    }
    if preview.len() > MAX_PREVIEW_BYTES {
        truncated = true;
        // The budget is in bytes, so the clip is too, and it stops on a
        // character boundary: a clip taken at a UTF-16 index instead used to
        // run past the end of CJK text and raise.
        let mut budget = MAX_PREVIEW_BYTES / 2;
        while budget > 0 && !preview.is_char_boundary(budget) {
            budget -= 1;
        }
        preview.truncate(budget);
        preview.push_str("\n…");
        return Preview {
            diff: Some(preview),
            truncated,
        };
    }
    Preview {
        diff: Some(preview),
        truncated: truncated || hunk_truncated,
    }
}

/// The three shapes a `write_file` call may take, and the prior each one
/// asserts. A call that names neither form asserts the file is absent.
pub fn write_expected_prior(arguments: &Map<String, Value>) -> Result<Value, StoreError> {
    let keys: Vec<&str> = arguments.keys().map(String::as_str).collect();
    let exact = |expected: &[&str]| {
        keys.len() == expected.len() && keys.iter().all(|key| expected.contains(key))
    };
    if !(exact(&["path", "content", "expected_prior"])
        || exact(&["path", "content", "expected_revision"])
        || exact(&["path", "content"]))
    {
        return Err(StoreError::InvalidArgument);
    }
    if let Some(prior) = arguments.get("expected_prior") {
        return Ok(prior.clone());
    }
    Ok(match arguments.get("expected_revision") {
        None | Some(Value::Null) => json!({ "schema_version": 1, "kind": "absent" }),
        Some(revision) => json!({
            "schema_version": 1, "kind": "known", "revision": revision,
        }),
    })
}

/// `DSHAgentWorkspaceFeedback`: canonicalise what the executor wants to report,
/// hold it to the protected feedback cap, and check it against the contract the
/// ledger will apply. The cap here is tighter than the transcript bound the
/// contract itself uses, and it applies to every workspace tool rather than
/// only the two that carry content.
pub fn feedback(value: &Value) -> Result<String, StoreError> {
    let bytes = crate::canonical::canonical_json(value).map_err(|_| StoreError::InvalidArgument)?;
    if bytes.len() > MAX_FEEDBACK_BYTES {
        return Err(StoreError::Capacity);
    }
    let text = String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?;
    crate::execution_ledger::feedback_string_valid(&text)?;
    Ok(text)
}

/// `DSHAgentWorkspaceFailure`: the result an executor reports when a tool
/// could not run. `ambiguous` says the effect may already have happened, which
/// is the one thing a retry has to know.
pub fn failure_result(name: &str, code: &str, ambiguous: bool) -> Result<Value, StoreError> {
    let outcome = if ambiguous { "ambiguous" } else { "failed" };
    let feedback = json!({
        "schema_version": 1, "name": name, "outcome": outcome,
        "payload": { "schema_version": 1, "failure_code": code },
    });
    let bytes =
        crate::canonical::canonical_json(&feedback).map_err(|_| StoreError::InvalidArgument)?;
    let text = String::from_utf8(bytes).map_err(|_| StoreError::InvalidArgument)?;
    crate::execution_ledger::feedback_string_valid(&text)?;
    Ok(json!({
        "schema_version": 1,
        "status": outcome,
        "feedback": text,
        "settled_facts": Value::Null,
        "truncated": false,
        "effect_may_have_occurred": ambiguous,
    }))
}

/// One envelope in, one reply out; see `rish_agent_workspace_tool_reduce`.
pub fn reduce_json(input: &str) -> String {
    let value = match reduce_json_inner(input) {
        Ok(output) => {
            let mut object = output.as_object().cloned().unwrap_or_default();
            object.insert("ok".to_string(), Value::Bool(true));
            Value::Object(object)
        }
        Err(error) => json!({ "ok": false, "error": error.code() }),
    };
    value.to_string()
}

fn reduce_json_inner(input: &str) -> Result<Value, StoreError> {
    let envelope: Value = serde_json::from_str(input).map_err(|_| StoreError::Corrupt)?;
    let op = envelope
        .get("op")
        .and_then(Value::as_str)
        .ok_or(StoreError::Corrupt)?;
    let number = |key: &str| {
        envelope
            .get(key)
            .and_then(Value::as_u64)
            .ok_or(StoreError::InvalidArgument)
    };
    match op {
        "path_components" => {
            let path = envelope
                .get("path")
                .and_then(Value::as_str)
                .ok_or(StoreError::InvalidArgument)?;
            let allow_root = envelope.get("allow_root") == Some(&Value::Bool(true));
            let components =
                path_components(path, allow_root).ok_or(StoreError::InvalidArgument)?;
            Ok(json!({ "components": components }))
        }
        // The caps the host enforces while reading and writing bytes. They are
        // rules, so it asks rather than keeping a second copy that could drift.
        "bounds" => Ok(json!({
            "max_path_bytes": MAX_PATH_BYTES,
            "max_read_bytes": MAX_READ_BYTES,
            "max_prior_read_bytes": MAX_PRIOR_READ_BYTES,
            "max_entries": MAX_ENTRIES,
        })),
        "revision" => Ok(json!({
            "revision": revision(
                number("dev")?, number("ino")?, number("size")?,
                number("mtime_sec")?, number("mtime_nsec")?)
        })),
        "directory_entry_decision" => {
            let count = usize::try_from(number("visible_count")?)
                .map_err(|_| StoreError::InvalidArgument)?;
            let entry = envelope.get("entry").ok_or(StoreError::InvalidArgument)?;
            Ok(json!({ "decision": directory_entry_decision(entry, count)? }))
        }
        "directory_listing" => {
            let Some(Value::Array(entries)) = envelope.get("entries") else {
                return Err(StoreError::InvalidArgument);
            };
            directory_listing(entries)
        }
        "diff_preview" => {
            let next = envelope
                .get("next")
                .and_then(Value::as_str)
                .ok_or(StoreError::InvalidArgument)?;
            // A prior the host could not decode arrives as null, and is
            // treated exactly like binary content: no preview.
            let prior = envelope.get("prior").and_then(Value::as_str);
            let preview = diff_preview(
                prior,
                next,
                envelope.get("prior_truncated") == Some(&Value::Bool(true)),
            );
            Ok(json!({
                "diff_preview": preview.diff,
                "diff_truncated": preview.truncated,
            }))
        }
        "write_expected_prior" => {
            let Some(Value::Object(arguments)) = envelope.get("arguments") else {
                return Err(StoreError::InvalidArgument);
            };
            Ok(json!({ "expected_prior": write_expected_prior(arguments)? }))
        }
        "feedback" => Ok(json!({
            "feedback": feedback(envelope.get("feedback").ok_or(StoreError::InvalidArgument)?)?
        })),
        "failure_result" => Ok(json!({
            "result": failure_result(
                envelope.get("name").and_then(Value::as_str).ok_or(StoreError::InvalidArgument)?,
                envelope.get("failure_code").and_then(Value::as_str).ok_or(StoreError::InvalidArgument)?,
                envelope.get("ambiguous") == Some(&Value::Bool(true)))?
        })),
        _ => Err(StoreError::InvalidArgument),
    }
}

#[cfg(test)]
#[path = "workspace_tool_tests.rs"]
mod tests;
