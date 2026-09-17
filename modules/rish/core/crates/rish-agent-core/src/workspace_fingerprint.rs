//! What binds a workspace authority to a physical directory.
//!
//! Ported from `DSHWorkspaceValidateRootFingerprintInput` in
//! `DSHWorkspaceCanonical.mm` and the three input builders in
//! `LocalWorkspaceAccess.mm`. This is the first rule of the workspace
//! subsystem to move, and it moves first on purpose: the root fingerprint is
//! what an Agent root projection carries and what a lease proves, so two
//! implementations of it would mean an authority written on one platform is
//! invalid on the other. Building Android's workspace subsystem against a
//! second Kotlin copy of this would have been the exact thing this core exists
//! to prevent.
//!
//! Three origins, three shapes, one digest:
//!
//! - `rish_created` / `imported` → a directory this app owns, identified by
//!   device, inode and the digest of its name;
//! - `granted_folder` → a folder the person granted, identified by the
//!   volume and resource identifiers and the security-scoped bookmark;
//! - `legacy_app_owned` → the pre-workspace project layout, identified by
//!   three separate device/inode pairs.
//!
//! The first two also fold in `authority_sha256`, the digest of the authority
//! record *without* its own fingerprint — so the fingerprint covers everything
//! the authority says about itself, and cannot be carried to a record that
//! says something different.

use serde_json::{json, Map, Value};

use crate::canonical::{canonical_json, hash_json, sha256_hex};
use crate::schema::{canonical_sha256, canonical_uuid, exact_keys, MAX_SAFE_INTEGER};

/// `DSHWorkspaceCanonicalUnsignedIntegerString`: a device or inode number as
/// its shortest decimal spelling. They travel as strings because they outrun a
/// safe integer on some filesystems.
fn unsigned_integer_string(value: Option<&Value>) -> bool {
    let Some(Value::String(text)) = value else {
        return false;
    };
    if text.is_empty() || text.len() > 20 {
        return false;
    }
    if text != "0" && text.starts_with('0') {
        return false;
    }
    text.bytes().all(|b| b.is_ascii_digit()) && text.parse::<u64>().is_ok()
}

/// `DSHWorkspaceSafeRevision`: a binding revision starts at one.
fn safe_revision(value: Option<&Value>) -> bool {
    match value {
        Some(Value::Number(number)) => number.as_f64().is_some_and(|n| {
            n.is_finite() && n.floor() == n && (1.0..=MAX_SAFE_INTEGER as f64).contains(&n)
        }),
        _ => false,
    }
}

fn common(input: &Map<String, Value>, origin: &str, locator: &str) -> bool {
    input.get("schema_version") == Some(&json!(1))
        && input.get("origin") == Some(&json!(origin))
        && canonical_uuid(input.get("workspace_id"))
        && safe_revision(input.get("binding_revision"))
        && input.get("root_locator_kind") == Some(&json!(locator))
}

/// `DSHWorkspaceValidateRootFingerprintInput`.
pub fn input_shape(input: Option<&Value>) -> bool {
    let Some(Value::Object(map)) = input else {
        return false;
    };
    let digest = |key: &str| canonical_sha256(map.get(key));
    let number = |key: &str| unsigned_integer_string(map.get(key));
    match map.get("origin").and_then(Value::as_str) {
        Some(origin @ ("rish_created" | "imported")) => {
            exact_keys(
                input,
                &[
                    "schema_version",
                    "origin",
                    "workspace_id",
                    "binding_revision",
                    "root_locator_kind",
                    "device_id",
                    "inode_id",
                    "directory_name_sha256",
                    "authority_sha256",
                ],
            )
            .is_some()
                && common(map, origin, "documents_owned")
                && number("device_id")
                && number("inode_id")
                && digest("directory_name_sha256")
                && digest("authority_sha256")
        }
        Some("granted_folder") => {
            exact_keys(
                input,
                &[
                    "schema_version",
                    "origin",
                    "workspace_id",
                    "binding_revision",
                    "root_locator_kind",
                    "volume_identifier_sha256",
                    "resource_identifier_sha256",
                    "device_id",
                    "inode_id",
                    "bookmark_sha256",
                    "authority_sha256",
                ],
            )
            .is_some()
                && common(map, "granted_folder", "security_scoped")
                && digest("volume_identifier_sha256")
                && digest("resource_identifier_sha256")
                && number("device_id")
                && number("inode_id")
                && digest("bookmark_sha256")
                && digest("authority_sha256")
        }
        Some("legacy_app_owned") => {
            exact_keys(
                input,
                &[
                    "schema_version",
                    "origin",
                    "workspace_id",
                    "binding_revision",
                    "root_locator_kind",
                    "legacy_project_id",
                    "project_metadata_sha256",
                    "projects_root_device_id",
                    "projects_root_inode_id",
                    "repository_device_id",
                    "repository_inode_id",
                    "git_device_id",
                    "git_inode_id",
                ],
            )
            .is_some()
                && common(map, "legacy_app_owned", "legacy_app_owned")
                && canonical_uuid(map.get("legacy_project_id"))
                && digest("project_metadata_sha256")
                && number("projects_root_device_id")
                && number("projects_root_inode_id")
                && number("repository_device_id")
                && number("repository_inode_id")
                && number("git_device_id")
                && number("git_inode_id")
        }
        _ => false,
    }
}

/// `DSHWorkspaceRootFingerprintSHA256`. `None` when the input is not one of
/// the three shapes — a fingerprint is never computed over something the rule
/// does not recognise.
pub fn fingerprint(input: Option<&Value>) -> Option<String> {
    if !input_shape(input) {
        return None;
    }
    hash_json("workspace-root-fingerprint", input?)
}

/// `DSHAuthorityDigestWithoutFingerprint`: a plain SHA-256 over the authority's
/// canonical JSON with its own fingerprint removed. Plain, not
/// domain-separated, because that is what the stored records were written
/// with.
pub fn authority_digest(authority: Option<&Value>) -> Option<String> {
    let Some(Value::Object(map)) = authority else {
        return None;
    };
    let mut base = map.clone();
    base.remove("root_fingerprint_sha256");
    Some(sha256_hex(&canonical_json(&Value::Object(base)).ok()?))
}

/// Builds the fingerprint input for a record and authority, choosing the shape
/// from the record's origin. The authority digest is folded in for the two
/// origins that carry one.
pub fn fingerprint_input(record: &Value, authority: &Value) -> Option<Value> {
    let origin = record.get("origin")?.as_str()?;
    let a = |key: &str| authority.get(key).cloned().unwrap_or(Value::Null);
    let workspace_id = record.get("workspace_id").cloned().unwrap_or(Value::Null);
    let binding_revision = record
        .get("binding_revision")
        .cloned()
        .unwrap_or(Value::Null);
    let digest = || authority_digest(Some(authority)).map(Value::String);
    Some(match origin {
        "rish_created" | "imported" => json!({
            "schema_version": 1, "origin": origin,
            "workspace_id": workspace_id, "binding_revision": binding_revision,
            "root_locator_kind": "documents_owned",
            "device_id": a("device_id"), "inode_id": a("inode_id"),
            "directory_name_sha256": a("directory_name_sha256"),
            "authority_sha256": digest()?,
        }),
        "granted_folder" => json!({
            "schema_version": 1, "origin": origin,
            "workspace_id": workspace_id, "binding_revision": binding_revision,
            "root_locator_kind": "security_scoped",
            "volume_identifier_sha256": a("volume_identifier_sha256"),
            "resource_identifier_sha256": a("resource_identifier_sha256"),
            "device_id": a("device_id"), "inode_id": a("inode_id"),
            "bookmark_sha256": a("bookmark_sha256"),
            "authority_sha256": digest()?,
        }),
        // The legacy shape names three device/inode pairs and folds in no
        // authority digest: its records predate one.
        "legacy_app_owned" => json!({
            "schema_version": 1, "origin": origin,
            "workspace_id": workspace_id, "binding_revision": binding_revision,
            "root_locator_kind": "legacy_app_owned",
            "legacy_project_id": a("legacy_project_id"),
            "project_metadata_sha256": a("project_metadata_sha256"),
            "projects_root_device_id": a("projects_root_device_id"),
            "projects_root_inode_id": a("projects_root_inode_id"),
            "repository_device_id": a("repository_device_id"),
            "repository_inode_id": a("repository_inode_id"),
            "git_device_id": a("git_device_id"),
            "git_inode_id": a("git_inode_id"),
        }),
        _ => return None,
    })
}

/// The fingerprint a record and an unsealed authority imply — the writing side
/// of `fingerprint_valid`. Building the input and hashing it is one step from
/// the host's point of view, and keeping it one step here means the two sides
/// cannot drift: whatever seals an authority is exactly what will later be
/// asked to recognise it.
pub fn seal(record: &Value, authority: &Value) -> Option<String> {
    fingerprint(Some(&fingerprint_input(record, authority)?))
}

/// Whether an authority's stored fingerprint is the one its own contents imply./// Whether an authority's stored fingerprint is the one its own contents imply.
pub fn fingerprint_valid(authority: &Value, record: &Value) -> bool {
    let Some(stored) = authority.get("root_fingerprint_sha256") else {
        return false;
    };
    if !canonical_sha256(Some(stored)) {
        return false;
    }
    fingerprint_input(record, authority)
        .and_then(|input| fingerprint(Some(&input)))
        .is_some_and(|expected| stored == &json!(expected))
}

/// One envelope in, one reply out; see `rish_agent_workspace_fingerprint_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let envelope: Value = serde_json::from_str(input).ok()?;
    match envelope.get("op")?.as_str()? {
        "fingerprint" => Some(json!({
            "ok": true, "fingerprint": fingerprint(envelope.get("input"))
        })),
        "authority_digest" => Some(json!({
            "ok": true, "digest": authority_digest(envelope.get("authority"))
        })),
        "fingerprint_input" => Some(json!({
            "ok": true,
            "input": fingerprint_input(envelope.get("record")?, envelope.get("authority")?)
        })),
        "seal" => Some(json!({
            "ok": true,
            "fingerprint": seal(envelope.get("record")?, envelope.get("authority")?),
        })),
        "fingerprint_valid" => Some(json!({
            "ok": true,
            "valid": fingerprint_valid(envelope.get("authority")?, envelope.get("record")?)
        })),
        _ => None,
    }
}

#[cfg(test)]
#[path = "workspace_fingerprint_tests.rs"]
mod tests;
