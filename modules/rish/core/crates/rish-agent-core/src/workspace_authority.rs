//! What a stored workspace authority looks like, how it is tied to its record,
//! and how one written before fingerprints existed is upgraded.
//!
//! Ported from `DSHValidOwnedAuthority`, `DSHValidBookmarkAuthority`,
//! `DSHValidGrantedAuthority` and `DSHValidLegacyAuthority` in
//! `LocalWorkspaceAccess.mm`. The fourth workspace rule, and the one that ties
//! the other three together: every shape here re-states the record's identity
//! and ends in the fingerprint from `workspace_fingerprint`.
//!
//! The cross-checks are the point. An authority that merely *looks* well
//! formed but names a different workspace, a different binding revision or a
//! different display name than the record it was loaded for is not an
//! authority for that record — it is someone else's, and the whole reason the
//! fingerprint folds in the authority digest is so the two cannot be mixed.
//!
//! **Base64 stays with the host.** The core has no base64, and decoding a
//! bookmark is mechanical; the host decodes and passes the length and the
//! digest of the decoded bytes. The rule — that the claimed digest must be the
//! bytes' digest and the bytes must fit the cap — stays here.

use serde_json::{json, Map, Value};

use crate::canonical::sha256_hex;
use crate::schema::{canonical_sha256, canonical_timestamp, exact_keys};
use crate::workspace_fingerprint::{fingerprint_valid, seal};
use crate::workspace_record::{capabilities_array, display_name, CAPABILITY_ORDER};

/// A security-scoped bookmark is at most this many bytes.
pub const MAX_BOOKMARK_BYTES: u64 = 256 * 1024;

/// `DSHCanonicalUnsignedIntegerString`.
fn unsigned_string(value: Option<&Value>) -> bool {
    let Some(Value::String(text)) = value else {
        return false;
    };
    !text.is_empty()
        && text.len() <= 20
        && (text == "0" || !text.starts_with('0'))
        && text.bytes().all(|b| b.is_ascii_digit())
        && text.parse::<u64>().is_ok()
}

/// `DSHCanonicalPositiveIntegerString`: the same, but a device or inode of
/// zero names nothing.
fn positive_string(value: Option<&Value>) -> bool {
    unsigned_string(value) && value != Some(&json!("0"))
}

/// Foundation compares these with `isEqual:`, and two `NSNumber`s are equal
/// when their values are, so a binding revision written `3.0` reads as equal
/// to `3`. That is reproduced. The other `NSNumber` coincidence — `true`
/// equalling `1` — is not: nothing writes a boolean revision, and treating one
/// as a number here would be carrying a Foundation accident into the rule.
fn same_value(left: Option<&Value>, right: Option<&Value>) -> bool {
    match (left, right) {
        (Some(Value::Number(a)), Some(Value::Number(b))) => match (a.as_f64(), b.as_f64()) {
            (Some(a), Some(b)) => a == b,
            _ => a == b,
        },
        (Some(a), Some(b)) => a == b,
        _ => false,
    }
}

/// Every authority restates the record's own identity, so a well-formed
/// authority for one workspace cannot be read as an authority for another.
fn matches_record(authority: &Map<String, Value>, record: &Value, keys: &[&str]) -> bool {
    keys.iter()
        .all(|key| same_value(authority.get(*key), record.get(*key)))
}

/// `DSHValidOwnedAuthority`. The directory-name digest is checked against the
/// record's own directory name: an authority cannot claim a folder the record
/// does not name.
pub fn owned_authority(authority: Option<&Value>, record: &Value) -> bool {
    let Some(map) = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "device_id",
            "inode_id",
            "directory_name_sha256",
            "recorded_at",
            "root_fingerprint_sha256",
        ],
    ) else {
        return false;
    };
    let Some(Value::String(directory)) = record.get("owned_directory_name") else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && matches_record(map, record, &["workspace_id", "binding_revision"])
        && unsigned_string(map.get("device_id"))
        && unsigned_string(map.get("inode_id"))
        && map.get("directory_name_sha256") == Some(&json!(sha256_hex(directory.as_bytes())))
        && canonical_timestamp(map.get("recorded_at"))
        && fingerprint_valid(authority.expect("checked"), record)
}

/// What the host observed about a bookmark's bytes. It decodes; the rule about
/// what the bytes must satisfy is here.
pub struct BookmarkBytes<'a> {
    /// `None` when the base64 could not be decoded at all.
    pub sha256: Option<&'a str>,
    pub length: u64,
}

/// `DSHValidBookmarkAuthority`.
pub fn bookmark_authority(
    authority: Option<&Value>,
    record: &Value,
    bytes: &BookmarkBytes,
) -> bool {
    let Some(map) = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "bookmark_sha256",
            "bookmark_bytes_base64",
            "recorded_at",
        ],
    ) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !matches_record(map, record, &["workspace_id", "binding_revision"])
        || !canonical_sha256(map.get("bookmark_sha256"))
        || !matches!(map.get("bookmark_bytes_base64"), Some(Value::String(_)))
        || !canonical_timestamp(map.get("recorded_at"))
    {
        return false;
    }
    // Bytes that do not decode, or that outrun the cap, are not a bookmark;
    // and the claimed digest has to be the digest of what decoded.
    let Some(digest) = bytes.sha256 else {
        return false;
    };
    bytes.length <= MAX_BOOKMARK_BYTES && map.get("bookmark_sha256") == Some(&json!(digest))
}

/// `DSHValidGrantedAuthority`. It carries the bookmark's digest rather than
/// the bookmark, and that digest must be the one the bookmark authority
/// recorded — the two are halves of one grant.
pub fn granted_authority(
    authority: Option<&Value>,
    record: &Value,
    bookmark_authority_value: &Value,
) -> bool {
    let Some(map) = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "volume_identifier_sha256",
            "resource_identifier_sha256",
            "device_id",
            "inode_id",
            "bookmark_sha256",
            "classified_at",
            "root_fingerprint_sha256",
        ],
    ) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && matches_record(map, record, &["workspace_id", "binding_revision"])
        && canonical_sha256(map.get("volume_identifier_sha256"))
        && canonical_sha256(map.get("resource_identifier_sha256"))
        && unsigned_string(map.get("device_id"))
        && unsigned_string(map.get("inode_id"))
        && same_value(
            map.get("bookmark_sha256"),
            bookmark_authority_value.get("bookmark_sha256"),
        )
        && canonical_timestamp(map.get("classified_at"))
        && fingerprint_valid(authority.expect("checked"), record)
}

/// `DSHValidLegacyAuthority`. The widest shape: it restates the record's
/// display name and both timestamps as well as its identity, because a legacy
/// root is verified by comparing all of them against the project on disk.
pub fn legacy_authority(authority: Option<&Value>, record: &Value) -> bool {
    let Some(map) = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "legacy_project_id",
            "root_identity_sha256",
            "display_name",
            "capabilities",
            "created_at",
            "last_opened_at",
            "recorded_at",
            "project_metadata_sha256",
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
            "root_fingerprint_sha256",
        ],
    ) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && matches_record(
            map,
            record,
            &[
                "workspace_id",
                "binding_revision",
                "legacy_project_id",
                "display_name",
                "created_at",
                "last_opened_at",
            ],
        )
        && canonical_sha256(map.get("root_identity_sha256"))
        && capabilities_array(map.get("capabilities"))
        && canonical_timestamp(map.get("recorded_at"))
        && canonical_sha256(map.get("project_metadata_sha256"))
        && [
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
        ]
        .iter()
        .all(|key| positive_string(map.get(*key)))
        && fingerprint_valid(authority.expect("checked"), record)
}

// MARK: - migration
//
// An authority written before root fingerprints existed carries every field
// its shape names except that one. Upgrading it is sealing it: the same
// contents, with the fingerprint they imply. Nothing else is rewritten, so an
// upgrade can never turn an authority into a claim over something its own
// bytes did not already say.
//
// The pre-fingerprint shapes are checked with the same rules as the sealed
// ones, less that key. What they are *not* checked against is the record's own
// `created_at` and `last_opened_at` in the legacy case — the validator demands
// those match and the migration does not, which means an old legacy authority
// whose timestamps have drifted can be upgraded into one that still fails to
// validate. That is the original's behaviour and it is left alone; see
// `a_migrated_legacy_authority_can_still_fail_to_validate`.

/// Seals an authority with the fingerprint its own contents imply. One copy of
/// that step, shared with the creation path, so an upgrade and a fresh write
/// cannot seal differently.
fn sealed(authority: Map<String, Value>, record: &Value) -> Option<Value> {
    let mut map = authority;
    let sha = seal(record, &Value::Object(map.clone()))?;
    map.insert("root_fingerprint_sha256".to_string(), json!(sha));
    Some(Value::Object(map))
}

/// `DSHMigrateOwnedAuthority`.
pub fn owned_migration(authority: Option<&Value>, record: &Value) -> Option<Value> {
    let map = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "device_id",
            "inode_id",
            "directory_name_sha256",
            "recorded_at",
        ],
    )?;
    let Some(Value::String(directory)) = record.get("owned_directory_name") else {
        return None;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !matches_record(map, record, &["workspace_id", "binding_revision"])
        || !unsigned_string(map.get("device_id"))
        || !unsigned_string(map.get("inode_id"))
        || map.get("directory_name_sha256") != Some(&json!(sha256_hex(directory.as_bytes())))
        || !canonical_timestamp(map.get("recorded_at"))
    {
        return None;
    }
    sealed(map.clone(), record)
}

/// `DSHMigrateGrantedAuthority`.
pub fn granted_migration(
    authority: Option<&Value>,
    record: &Value,
    bookmark_authority_value: &Value,
) -> Option<Value> {
    let map = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "volume_identifier_sha256",
            "resource_identifier_sha256",
            "device_id",
            "inode_id",
            "bookmark_sha256",
            "classified_at",
        ],
    )?;
    if map.get("schema_version") != Some(&json!(1))
        || !matches_record(map, record, &["workspace_id", "binding_revision"])
        || !canonical_sha256(map.get("volume_identifier_sha256"))
        || !canonical_sha256(map.get("resource_identifier_sha256"))
        || !unsigned_string(map.get("device_id"))
        || !unsigned_string(map.get("inode_id"))
        || !same_value(
            map.get("bookmark_sha256"),
            bookmark_authority_value.get("bookmark_sha256"),
        )
        || !canonical_timestamp(map.get("classified_at"))
    {
        return None;
    }
    sealed(map.clone(), record)
}

/// `DSHValidLegacyPhysicalIdentity`: what the host re-read from the project on
/// disk. Every identifier is positive — a legacy root that reports device or
/// inode zero names nothing and cannot be verified.
pub fn legacy_physical_identity(
    identity: Option<&Value>,
    expected_metadata: Option<&Value>,
) -> bool {
    let Some(map) = exact_keys(
        identity,
        &[
            "project_metadata_sha256",
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
        ],
    ) else {
        return false;
    };
    map.get("project_metadata_sha256").is_some()
        && map.get("project_metadata_sha256") == expected_metadata
        && canonical_sha256(map.get("project_metadata_sha256"))
        && [
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
        ]
        .iter()
        .all(|key| positive_string(map.get(*key)))
}

/// `DSHValidLegacyEvidence`: what the host found when it re-read a legacy
/// project on disk, before any of it is written down. The display name is a
/// display name, so the host's folding comes in the same way `record_shape`
/// takes it.
///
/// This is the widest legacy shape: it carries the project's own identity and
/// the capabilities the host could verify, and the migration narrows it to the
/// physical identity that gets sealed.
pub fn legacy_evidence(
    identity: Option<&Value>,
    expected_project_id: Option<&Value>,
    folded_display_name: Option<&str>,
) -> bool {
    let Some(map) = exact_keys(
        identity,
        &[
            "project_id",
            "display_name",
            "metadata_sha256",
            "capabilities",
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
        ],
    ) else {
        return false;
    };
    map.get("project_id").is_some()
        && map.get("project_id") == expected_project_id
        && display_name(map.get("display_name"), folded_display_name)
        && canonical_sha256(map.get("metadata_sha256"))
        && capabilities_set(map.get("capabilities"))
        && [
            "projects_root_device_id",
            "projects_root_inode_id",
            "repository_device_id",
            "repository_inode_id",
            "git_device_id",
            "git_inode_id",
        ]
        .iter()
        .all(|key| positive_string(map.get(*key)))
}

/// `DSHCanonicalCapabilitiesSet`. Evidence carries a *set*, so order does not
/// matter here — only that every member is a capability and none repeats.
pub fn capabilities_set(value: Option<&Value>) -> bool {
    let Some(Value::Array(items)) = value else {
        return false;
    };
    let mut seen: Vec<&str> = Vec::with_capacity(items.len());
    for item in items {
        let Some(name) = item.as_str() else {
            return false;
        };
        if !CAPABILITY_ORDER.contains(&name) || seen.contains(&name) {
            return false;
        }
        seen.push(name);
    }
    true
}

/// `DSHWorkspaceDescriptorMatchesAuthority`: whether an open directory is the
/// one an authority was sealed over.
///
/// **Only the inode is compared**, for the same reason the legacy matcher
/// below gives: iOS renumbers the data volume across reboots, so a persisted
/// `st_dev` would fail a perfectly good root after a restart. What a matching
/// device id used to stand for — "this is inside our own container" — is
/// carried instead by *how* the caller got here: it walked down from the app
/// container to open the descriptor. Stating that in one place rather than two
/// is why this lives here.
///
/// Whether the descriptor is a directory and not a symlink is the host's to
/// determine; it passes `is_directory` along with the inode it read.
pub fn descriptor_matches_authority(
    authority: Option<&Value>,
    inode: Option<&Value>,
    is_directory: bool,
) -> bool {
    if !is_directory {
        return false;
    }
    let Some(authority) = authority else {
        return false;
    };
    unsigned_string(inode) && authority.get("inode_id") == inode
}

/// `DSHLegacyPhysicalIdentityMatchesAuthority`./// `DSHLegacyPhysicalIdentityMatchesAuthority`.
///
/// **Device ids are deliberately absent.** iOS renumbers the data volume
/// across reboots, so a persisted `st_dev` is not evidence about a directory —
/// comparing it would fail a perfectly good root after a restart. The three
/// inodes, all reached from this app's own container, carry the identity.
pub fn legacy_identity_matches_authority(
    identity: Option<&Value>,
    authority: Option<&Value>,
) -> bool {
    let (Some(identity), Some(authority)) = (identity, authority) else {
        return false;
    };
    [
        "projects_root_inode_id",
        "repository_inode_id",
        "git_inode_id",
    ]
    .iter()
    .all(|key| {
        let recorded = identity.get(*key);
        recorded.is_some() && recorded == authority.get(*key)
    })
}

/// `DSHMigrateLegacyAuthority`. The physical identity is folded in before the/// `DSHMigrateLegacyAuthority`. The physical identity is folded in before the
/// seal, because the fingerprint is taken over all three device/inode pairs.
pub fn legacy_migration(
    authority: Option<&Value>,
    record: &Value,
    physical: Option<&Value>,
) -> Option<Value> {
    let map = exact_keys(
        authority,
        &[
            "schema_version",
            "workspace_id",
            "binding_revision",
            "legacy_project_id",
            "root_identity_sha256",
            "display_name",
            "created_at",
            "last_opened_at",
            "recorded_at",
        ],
    )?;
    if map.get("schema_version") != Some(&json!(1))
        || !matches_record(
            map,
            record,
            &[
                "workspace_id",
                "binding_revision",
                "legacy_project_id",
                "display_name",
            ],
        )
        || !canonical_sha256(map.get("root_identity_sha256"))
        || !canonical_timestamp(map.get("created_at"))
        || !canonical_timestamp(map.get("last_opened_at"))
        || !canonical_timestamp(map.get("recorded_at"))
    {
        return None;
    }
    if !legacy_physical_identity(physical, map.get("root_identity_sha256")) {
        return None;
    }
    let mut merged = map.clone();
    for (key, value) in physical?.as_object()? {
        merged.insert(key.clone(), value.clone());
    }
    sealed(merged, record)
}

/// The capabilities the host verified, in the one order a stored authority may
/// spell them. The legacy fingerprint folds in no authority digest, so these
/// are added *after* the seal and the seal still holds — which is also why the
/// capability list is not what makes a legacy root trustworthy.
pub fn ordered_capabilities(available: &[String]) -> Vec<String> {
    CAPABILITY_ORDER
        .iter()
        .filter(|name| available.iter().any(|have| have == *name))
        .map(|name| (*name).to_string())
        .collect()
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_authority_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    let authority = envelope.get("authority");
    let op = text(envelope, "op")?;
    // Two ops are about neither an authority nor a record, so they are
    // answered before one is demanded: asking the host to hand over a record
    // it has no use for would be an invitation to invent one.
    match op {
        "legacy_physical_identity" => {
            return Some(json!({
                "ok": true,
                "valid": legacy_physical_identity(
                    envelope.get("identity"),
                    envelope.get("expected_metadata_sha256"),
                ),
            }))
        }
        "legacy_evidence" => {
            return Some(json!({
                "ok": true,
                "valid": legacy_evidence(
                    envelope.get("identity"),
                    envelope.get("expected_project_id"),
                    text(envelope, "folded_display_name"),
                ),
            }))
        }
        "capabilities_set" => {
            return Some(json!({
                "ok": true, "valid": capabilities_set(envelope.get("value"))
            }))
        }
        "descriptor_matches_authority" => {
            return Some(json!({
                "ok": true,
                "matches": descriptor_matches_authority(
                    envelope.get("authority"),
                    envelope.get("inode_id"),
                    envelope.get("is_directory") == Some(&json!(true)),
                ),
            }))
        }
        "legacy_identity_matches_authority" => {
            return Some(json!({
                "ok": true,
                "matches": legacy_identity_matches_authority(
                    envelope.get("identity"),
                    envelope.get("authority"),
                ),
            }))
        }
        "ordered_capabilities" => {
            let available: Vec<String> = envelope
                .get("available")?
                .as_array()?
                .iter()
                .map(|item| item.as_str().map(str::to_owned))
                .collect::<Option<Vec<String>>>()?;
            return Some(json!({
                "ok": true, "capabilities": ordered_capabilities(&available)
            }));
        }
        _ => {}
    }
    let record = envelope.get("record")?;
    let valid = match op {
        "owned" => owned_authority(authority, record),
        "bookmark" => bookmark_authority(
            authority,
            record,
            &BookmarkBytes {
                sha256: text(envelope, "bookmark_bytes_sha256"),
                length: envelope
                    .get("bookmark_bytes_length")
                    .and_then(Value::as_u64)
                    .unwrap_or(u64::MAX),
            },
        ),
        "granted" => granted_authority(
            authority,
            record,
            envelope.get("bookmark_authority").unwrap_or(&Value::Null),
        ),
        "legacy" => legacy_authority(authority, record),
        // The migrations answer with an authority rather than a verdict, so
        // they return early: `valid` would say nothing about them.
        "owned_migration" => {
            return Some(json!({
                "ok": true, "authority": owned_migration(authority, record)
            }))
        }
        "granted_migration" => {
            return Some(json!({
                "ok": true,
                "authority": granted_migration(
                    authority,
                    record,
                    envelope.get("bookmark_authority").unwrap_or(&Value::Null),
                ),
            }))
        }
        "legacy_migration" => {
            return Some(json!({
                "ok": true,
                "authority": legacy_migration(authority, record, envelope.get("physical_identity")),
            }))
        }
        _ => return None,
    };
    Some(json!({ "ok": true, "valid": valid }))
}

#[cfg(test)]
#[path = "workspace_authority_tests.rs"]
mod tests;
