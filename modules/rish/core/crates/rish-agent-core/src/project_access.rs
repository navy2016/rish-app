//! What a project binding, its root reference and its stored metadata look
//! like.
//!
//! Ported from `DSHLocalProjectRootRefIsValid`,
//! `DSHLocalProjectCanonicalRootRef`, `DSHLocalProjectBindingIsValid`,
//! `DSHLocalProjectBindingDigest`, `DSHValidStoredMetadataRecord` and
//! `DSHLocalProjectCanonicalLegacyDisplayName` in `LocalProjectAccess.mm`.
//!
//! The project subsystem is the peer of the workspace subsystem: a workspace
//! is a folder someone granted, a project is a Git working tree inside one.
//! The binding is what ties the two together, and its job is to make that tie
//! checkable — it restates the root reference's identity and the root
//! fingerprint, so a binding cannot be read as belonging to a root it was not
//! written for.
//!
//! **The git directory is private and is not in the digest.** A binding's
//! digest is taken over everything *except* `git_directory_url`: the path is a
//! local fact that differs between installs of the same project, and folding
//! it in would make two devices' bindings disagree about a project they agree
//! about.

use serde_json::{json, Map, Value};
use unicode_normalization::UnicodeNormalization;

use crate::canonical::{canonical_json, sha256_hex};
use crate::schema::{canonical_sha256, canonical_uuid, exact_keys, safe_integer, MAX_SAFE_INTEGER};
use crate::workspace_tool::path_control_or_format;

/// A display name is at most this many UTF-8 bytes, as everywhere else in the
/// two subsystems.
pub const MAX_DISPLAY_NAME_BYTES: usize = 120;

/// `PATH_MAX`. A git directory path longer than this cannot be opened, so a
/// binding naming one is not a binding.
pub const MAX_PATH_BYTES: usize = 1024;

/// An origin URL is remembered but never resolved here, so it is only bounded.
pub const MAX_ORIGIN_BYTES: usize = 4096;

/// The one topology this engine produces: the work tree in the project folder,
/// the git directory held privately beside it.
pub const GIT_TOPOLOGY: &str = "private_split_gitdir";

fn is_string(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::String(_)))
}

fn text(value: Option<&Value>) -> Option<&str> {
    value?.as_str()
}

fn has_control(value: &str) -> bool {
    value.chars().any(path_control_or_format)
}

/// `DSHLocalProjectRootRefIsValid`. `project_required` is the caller's
/// question, not the shape's: some operations address a workspace root and
/// some address a project inside it, and the same reference answers both.
pub fn root_ref_valid(root_ref: Option<&Value>, project_required: bool) -> bool {
    let Some(map) = exact_keys(
        root_ref,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "project_id",
        ],
    ) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !canonical_uuid(map.get("workspace_id"))
        || safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
    {
        return false;
    }
    match map.get("project_id") {
        Some(Value::Null) | None => !project_required,
        project => canonical_uuid(project),
    }
}

/// `DSHLocalProjectCanonicalRootRef`: the reference with its keys enumerated
/// and its revision re-rendered as a number, so two references naming the same
/// root have the same bytes.
pub fn canonical_root_ref(root_ref: Option<&Value>) -> Option<Value> {
    if !root_ref_valid(root_ref, false) {
        return None;
    }
    let map = root_ref?.as_object()?;
    let revision = safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false)?;
    Some(json!({
        "schema_version": 1,
        "workspace_id": map.get("workspace_id"),
        "binding_revision": revision,
        "project_id": map.get("project_id").cloned().unwrap_or(Value::Null),
    }))
}

/// What the host observed about a binding's git directory. The URL itself does
/// not cross: the core is told whether it is a file URL and what its path is.
pub struct GitDirectory<'a> {
    pub is_file_url: bool,
    pub path: Option<&'a str>,
}

/// `DSHLocalProjectBindingIsValid`.
///
/// The binding restates the root reference's identity and the root
/// fingerprint. That is the whole point: a binding found beside a project must
/// prove it was written for *this* root, at *this* revision, or it is a
/// binding for something else that happens to be in the way.
pub fn binding_valid(
    binding: Option<&Value>,
    root_ref: Option<&Value>,
    root_fingerprint: Option<&str>,
    git_directory: &GitDirectory,
) -> bool {
    let Some(map) = exact_keys(
        binding,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "project_id",
            "display_name",
            "git_topology",
            "git_directory_url",
            "root_fingerprint_sha256",
        ],
    ) else {
        return false;
    };
    let Some(root) = root_ref else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(2))
        || map.get("workspace_id") != root.get("workspace_id")
        || map.get("binding_revision") != root.get("binding_revision")
        || map.get("project_id") != root.get("project_id")
        || !canonical_sha256(map.get("root_fingerprint_sha256"))
        || map.get("root_fingerprint_sha256") != root_fingerprint.map(|sha| json!(sha)).as_ref()
        || map.get("git_topology") != Some(&json!(GIT_TOPOLOGY))
    {
        return false;
    }
    let Some(display) = text(map.get("display_name")) else {
        return false;
    };
    if display.is_empty()
        || display.len() > MAX_DISPLAY_NAME_BYTES
        || has_control(display)
        || display.contains('/')
        || display.contains('\\')
        || display == "."
        || display == ".."
    {
        return false;
    }
    // The git directory is a real absolute file path this process could open.
    let Some(path) = git_directory.path else {
        return false;
    };
    git_directory.is_file_url
        && path.starts_with('/')
        && !has_control(path)
        && path.len() <= MAX_PATH_BYTES
}

/// `DSHLocalProjectBindingDigest`: the digest over the binding **without** its
/// git directory URL. See the module note — the path is a local fact, and two
/// installs of one project must agree about the binding.
pub fn binding_digest(binding: Option<&Value>) -> Option<String> {
    let map = binding?.as_object()?;
    let mut base = map.clone();
    base.remove("git_directory_url");
    Some(sha256_hex(&canonical_json(&Value::Object(base)).ok()?))
}

/// `DSHValidStoredMetadataRecord`: the project's own metadata file.
///
/// The timestamps are only bounded here, not parsed: this record predates the
/// canonical timestamp rule and refusing an old project over its date format
/// would lose the project rather than fix the date.
pub fn stored_metadata_valid(record: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        record,
        &[
            "schema_version",
            "name",
            "created_at",
            "updated_at",
            "origin_url",
        ],
    ) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1)) {
        return false;
    }
    let (Some(name), Some(created), Some(updated)) = (
        text(map.get("name")),
        text(map.get("created_at")),
        text(map.get("updated_at")),
    ) else {
        return false;
    };
    if name.is_empty()
        || name.len() > MAX_DISPLAY_NAME_BYTES
        || has_control(name)
        || name.contains('/')
        || name.contains('\\')
    {
        return false;
    }
    let dated = |value: &str| {
        // Foundation counts UTF-16 units here; every timestamp this writes is
        // ASCII, so the two agree on everything reachable.
        let units = value.encode_utf16().count();
        (20..=64).contains(&units) && !has_control(value)
    };
    if !dated(created) || !dated(updated) {
        return false;
    }
    match map.get("origin_url") {
        Some(Value::Null) | None => map.contains_key("origin_url"),
        origin => {
            is_string(origin)
                && text(origin).is_some_and(|url| {
                    url.encode_utf16().count() <= MAX_ORIGIN_BYTES && !has_control(url)
                })
        }
    }
}

/// `DSHLocalProjectCanonicalLegacyDisplayName`.
///
/// `foundation_trimmed` is the host's trimming with
/// `whitespaceAndNewlineCharacterSet`, which includes U+200B where Rust's
/// `trim` does not. That difference is the reason it is handed across rather
/// than recomputed: a name padded with a zero-width space would otherwise be
/// accepted here and refused on the device that wrote it.
pub fn legacy_display_name(value: Option<&Value>, foundation_trimmed: Option<&str>) -> bool {
    let Some(name) = text(value) else {
        return false;
    };
    let Some(trimmed) = foundation_trimmed else {
        return false;
    };
    name.nfc().eq(name.chars())
        && !name.is_empty()
        && name.len() <= MAX_DISPLAY_NAME_BYTES
        && trimmed == name
        && !name.starts_with('.')
        && name != "."
        && name != ".."
        && !name.contains('/')
        && !name.contains('\\')
        && !name.contains(':')
        && !has_control(name)
}

fn op<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_project_access_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    Some(match op(envelope, "op")? {
        "root_ref_valid" => json!({
            "ok": true,
            "valid": root_ref_valid(
                envelope.get("root_ref"),
                envelope.get("project_required") == Some(&json!(true)),
            ),
        }),
        "canonical_root_ref" => json!({
            "ok": true, "root_ref": canonical_root_ref(envelope.get("root_ref"))
        }),
        "binding_valid" => json!({
            "ok": true,
            "valid": binding_valid(
                envelope.get("binding"),
                envelope.get("root_ref"),
                op(envelope, "root_fingerprint_sha256"),
                &GitDirectory {
                    is_file_url: envelope.get("git_is_file_url") == Some(&json!(true)),
                    path: op(envelope, "git_directory_path"),
                },
            ),
        }),
        "binding_digest" => json!({
            "ok": true, "digest": binding_digest(envelope.get("binding"))
        }),
        "stored_metadata_valid" => json!({
            "ok": true, "valid": stored_metadata_valid(envelope.get("record"))
        }),
        "legacy_display_name" => json!({
            "ok": true,
            "valid": legacy_display_name(
                envelope.get("value"),
                op(envelope, "foundation_trimmed"),
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "project_access_tests.rs"]
mod tests;
