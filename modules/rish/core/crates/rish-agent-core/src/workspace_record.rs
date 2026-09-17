//! What a stored workspace registry record looks like.
//!
//! Ported from `DSHValidWorkspaceRecord`, `DSHCanonicalDisplayName`,
//! `DSHCanonicalCapabilitiesArray` and
//! `DSHLocalWorkspaceValidateBindingRevisionAdvance` in
//! `LocalWorkspaceAccess.mm`. The third workspace rule, after the fingerprint
//! and the grants: this is the record those two are computed over.
//!
//! The origin decides everything else. A record does not get to name a locator
//! kind, a location class, an owned directory and a legacy project
//! independently — each origin fixes all four, and a record that mixes them is
//! not a record.
//!
//! **Case-and-diacritic folding stays with the host.** The reserved-name check
//! uses `stringByFoldingWithOptions:` with `NSCaseInsensitiveSearch |
//! NSDiacriticInsensitiveSearch` under `en_US_POSIX`, which is neither
//! lowercasing nor the case folding the project-context policy uses. The host
//! folds and passes the folded spelling in, as it does there.

use serde_json::{json, Map, Value};
use unicode_normalization::UnicodeNormalization;

use crate::project_context_policy::REASON_POLICY;
use crate::schema::{
    canonical_timestamp, canonical_uuid, exact_keys, is_null, safe_integer, MAX_SAFE_INTEGER,
};
use crate::workspace_tool::path_control_or_format;

/// The four grants, in the order a stored capability array must list them.
pub const CAPABILITY_ORDER: &[&str] = &["read", "write", "git", "project_context"];

/// A display name is at most this many UTF-8 bytes.
pub const MAX_DISPLAY_NAME_BYTES: usize = 120;

/// `DSHIsSafeInteger(value, NO)`: a positive safe integer.
fn positive_safe_integer(value: Option<&Value>) -> Option<u64> {
    let Some(Value::Number(number)) = value else {
        return None;
    };
    let n = number.as_f64()?;
    if !n.is_finite() || n.floor() != n || !(1.0..=MAX_SAFE_INTEGER as f64).contains(&n) {
        return None;
    }
    Some(n as u64)
}

/// `DSHCanonicalDisplayName`, minus the fold. `folded` is the host's
/// case-and-diacritic-folded spelling of the same name; pass `None` only when
/// the host could not fold it, which is itself a refusal.
pub fn display_name(value: Option<&Value>, folded: Option<&str>) -> bool {
    let Some(Value::String(name)) = value else {
        return false;
    };
    // NFC, so one name has one spelling.
    if name.nfc().ne(name.chars()) {
        return false;
    }
    if name.is_empty() || name.len() > MAX_DISPLAY_NAME_BYTES {
        return false;
    }
    // No leading or trailing whitespace: a name that differs only by padding
    // is a second name for one folder.
    if name.trim() != name.as_str() {
        return false;
    }
    if name.starts_with('.')
        || name == "."
        || name == ".."
        || name.contains('/')
        || name.contains('\\')
        || name.contains(':')
        || name.contains('\0')
        || name.chars().any(path_control_or_format)
    {
        return false;
    }
    // The container's own directory and the private prefix are not names a
    // person's workspace may take.
    let Some(folded) = folded else {
        return false;
    };
    folded != "rish workspaces" && !folded.starts_with(".rish-")
}

/// `DSHCanonicalCapabilitiesArray`: at most four, each known, no repeats, and
/// in the fixed order — so one capability set has one spelling and a stored
/// record digests the same everywhere.
pub fn capabilities_array(value: Option<&Value>) -> bool {
    let Some(Value::Array(items)) = value else {
        return false;
    };
    if items.len() > CAPABILITY_ORDER.len() {
        return false;
    }
    let mut previous: i64 = -1;
    for item in items {
        let Value::String(name) = item else {
            return false;
        };
        let Some(index) = CAPABILITY_ORDER.iter().position(|c| c == name) else {
            return false;
        };
        if index as i64 <= previous {
            return false;
        }
        previous = index as i64;
    }
    true
}

/// `DSHValidWorkspaceRecord`. `folded_display_name` is the host's folded
/// spelling of `display_name`; `folded_directory_name` the same for
/// `owned_directory_name`, and is unused unless the origin has one.
pub fn record_shape(
    record: Option<&Value>,
    folded_display_name: Option<&str>,
    folded_directory_name: Option<&str>,
) -> bool {
    let Some(map) = exact_keys(
        record,
        &[
            "schema_version",
            "workspace_id",
            "display_name",
            "origin",
            "root_locator_kind",
            "location_class",
            "owned_directory_name",
            "legacy_project_id",
            "binding_revision",
            "created_at",
            "last_opened_at",
        ],
    ) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !canonical_uuid(map.get("workspace_id"))
        || !display_name(map.get("display_name"), folded_display_name)
        || positive_safe_integer(map.get("binding_revision")).is_none()
        || !canonical_timestamp(map.get("created_at"))
        || !canonical_timestamp(map.get("last_opened_at"))
    {
        return false;
    }
    let is = |key: &str, value: &str| map.get(key) == Some(&json!(value));
    let owned = map.get("owned_directory_name");
    let legacy = map.get("legacy_project_id");
    // The origin fixes the locator kind, the location class, and which of the
    // two optional identities is present. None of them is free.
    match map.get("origin").and_then(Value::as_str) {
        Some("rish_created" | "imported") => {
            is("root_locator_kind", "documents_owned")
                && is("location_class", "rish_owned")
                && display_name(owned, folded_directory_name)
                && is_null(legacy)
        }
        Some("granted_folder") => {
            is("root_locator_kind", "security_scoped")
                && is("location_class", "proven_local")
                && is_null(owned)
                && is_null(legacy)
        }
        Some("legacy_app_owned") => {
            is("root_locator_kind", "legacy_app_owned")
                && is("location_class", "rish_owned")
                && is_null(owned)
                && canonical_uuid(legacy)
        }
        _ => false,
    }
}

/// The registry holds at most this many records.
pub const MAX_RECORDS: usize = 1024;

/// What the host folded for one record, so the core can judge the registry as
/// a whole without doing any folding itself.
pub struct FoldedRecord<'a> {
    pub display_name: Option<&'a str>,
    pub directory_name: Option<&'a str>,
}

/// The registry file's own shape, from `loadRegistry:`.
///
/// Three invariants beyond "every record is a record":
///
/// - **Workspace ids are strictly ascending.** Not merely unique — sorted. The
///   registry's canonical JSON is what `previous_registry_sha256` is taken
///   over, so two registries holding the same records in a different order
///   would digest differently and every journal written against one would be
///   unrecoverable against the other.
/// - **No two records share a folded directory name.** Two workspaces whose
///   folders differ only by case or accent are one folder on this filesystem,
///   and the second would silently write into the first.
/// - **The count is bounded**, so a corrupted or hostile file cannot make
///   every launch walk an unbounded list.
pub fn registry_shape(registry: Option<&Value>, folded: &[FoldedRecord]) -> bool {
    let Some(map) = exact_keys(registry, &["schema_version", "generation", "records"]) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || safe_integer(map.get("generation"), MAX_SAFE_INTEGER, true).is_none()
    {
        return false;
    }
    let Some(Value::Array(records)) = map.get("records") else {
        return false;
    };
    if records.len() > MAX_RECORDS || records.len() != folded.len() {
        return false;
    }
    let mut previous: Option<&str> = None;
    let mut directories: Vec<&str> = Vec::with_capacity(records.len());
    for (record, folded) in records.iter().zip(folded) {
        if !record_shape(Some(record), folded.display_name, folded.directory_name) {
            return false;
        }
        let Some(id) = record.get("workspace_id").and_then(Value::as_str) else {
            return false;
        };
        if previous.is_some_and(|seen| seen >= id) {
            return false;
        }
        previous = Some(id);
        // A record with no owned directory occupies no name.
        if !is_null(record.get("owned_directory_name")) {
            let Some(name) = folded.directory_name else {
                return false;
            };
            if directories.contains(&name) {
                return false;
            }
            directories.push(name);
        }
    }
    true
}

/// Whether one more record fits. A full registry refuses the operation rather
/// than dropping a binding somebody still uses.
pub fn registry_has_room(count: Option<u64>) -> bool {
    match count {
        Some(count) => count < MAX_RECORDS as u64,
        None => false,
    }
}

/// The layout manifest: the one object that says this store was initialised.
pub fn layout_manifest_shape(manifest: Option<&Value>) -> bool {
    let Some(map) = exact_keys(manifest, &["schema_version", "initialized_at"]) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1)) && canonical_timestamp(map.get("initialized_at"))
}

/// What a binding revision may advance to, and why it may not./// What a binding revision may advance to, and why it may not.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Advance {
    Ok,
    /// Either revision is not a positive safe integer.
    Invalid,
    /// The current revision cannot be incremented without leaving the safe
    /// range, so this binding can never be rebound again.
    Overflow,
    /// The proposal is not exactly one past the current revision.
    Conflict,
}

/// `DSHLocalWorkspaceValidateBindingRevisionAdvance`. A revision advances by
/// exactly one: a gap would let two rebinds look like one.
pub fn binding_revision_advance(current: Option<&Value>, proposed: Option<&Value>) -> Advance {
    let (Some(current), Some(proposed)) = (
        positive_safe_integer(current),
        positive_safe_integer(proposed),
    ) else {
        return Advance::Invalid;
    };
    if current >= MAX_SAFE_INTEGER {
        return Advance::Overflow;
    }
    if proposed != current + 1 {
        return Advance::Conflict;
    }
    Advance::Ok
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_record_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    match text(envelope, "op")? {
        "record_shape" => Some(json!({
            "ok": true,
            "valid": record_shape(
                envelope.get("record"),
                text(envelope, "folded_display_name"),
                text(envelope, "folded_directory_name"),
            ),
        })),
        "display_name" => Some(json!({
            "ok": true,
            "valid": display_name(envelope.get("value"), text(envelope, "folded")),
        })),
        "capabilities_array" => Some(json!({
            "ok": true, "valid": capabilities_array(envelope.get("value"))
        })),
        "binding_revision_advance" => {
            let outcome =
                match binding_revision_advance(envelope.get("current"), envelope.get("proposed")) {
                    Advance::Ok => "ok",
                    Advance::Invalid => "invalid",
                    Advance::Overflow => "overflow",
                    Advance::Conflict => "conflict",
                };
            Some(json!({ "ok": true, "outcome": outcome }))
        }
        // The policy reason is re-exported so a caller that refuses a record
        // has one vocabulary rather than two.
        "registry_shape" => {
            let items = envelope.get("folded")?.as_array()?;
            let folded: Vec<FoldedRecord> = items
                .iter()
                .map(|item| FoldedRecord {
                    display_name: item.get("display_name").and_then(Value::as_str),
                    directory_name: item.get("directory_name").and_then(Value::as_str),
                })
                .collect();
            Some(json!({
                "ok": true,
                "valid": registry_shape(envelope.get("registry"), &folded),
            }))
        }
        "registry_has_room" => Some(json!({
            "ok": true,
            "has_room": registry_has_room(envelope.get("count").and_then(Value::as_u64)),
        })),
        "layout_manifest_shape" => Some(json!({
            "ok": true, "valid": layout_manifest_shape(envelope.get("manifest"))
        })),
        "reason" => Some(json!({ "ok": true, "reason": REASON_POLICY })),
        _ => None,
    }
}

#[cfg(test)]
#[path = "workspace_record_tests.rs"]
mod tests;
