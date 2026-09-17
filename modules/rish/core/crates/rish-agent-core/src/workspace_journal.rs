//! What a workspace operation journal looks like mid-flight, and how its
//! recorded identity relates to what is actually on disk.
//!
//! Ported from `validJournal:`, `validLegacyJournal:`,
//! `DSHCreateRequestSHA256`, `DSHBootstrapRequestSHA256`,
//! `DSHJournalIdentityPresent`, `DSHJournalIdentityMatchesState` and
//! `DSHOwnedAuthorityMatchesJournal` in `LocalWorkspaceAccess.mm`.
//!
//! A journal is what makes a workspace operation recoverable: it is written
//! before the directory moves, updated as each phase lands, and read on the
//! next launch to decide whether an interrupted operation should be finished
//! or undone. That gives the shape three jobs, and each is a rule.
//!
//! **The journal binds itself to its own request.** `request_sha256` must be
//! the digest of the request the journal claims to be carrying out, so a
//! journal cannot be replayed as a different operation than the one that was
//! asked for.
//!
//! **A phase says which digests exist yet.** `prepared` has neither an
//! authority nor a record digest, because neither has been written; any later
//! phase has both. A journal claiming a record digest at `prepared` is
//! describing a state that cannot have occurred.
//!
//! **Physical identity is recorded in fours.** Device, inode, uid and gid are
//! present together or not at all — three of four is not partial evidence, it
//! is a journal that cannot be checked against a directory, and the recovery
//! engine would have to guess.

use serde_json::{json, Map, Value};

use crate::canonical::{canonical_json, sha256_hex};
use crate::schema::{
    canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys, safe_integer,
    MAX_SAFE_INTEGER,
};
use crate::workspace_directory_name::internal_component;
use crate::workspace_record::display_name;

/// The operations with a recovery engine. Import, regrant and the destructive
/// operations fail closed until theirs ship — an unrecognised operation in a
/// journal is not one this engine knows how to finish or undo.
pub const OPERATIONS: &[&str] = &["bootstrap_legacy", "create"];

/// The phases of the three-phase commit, in order.
pub const PHASES: &[&str] = &["prepared", "authority_ready", "registry_committed"];

/// The four facts that identify a directory on disk.
const IDENTITY_FIELDS: &[&str] = &["device_id", "inode_id", "uid", "gid"];

const KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "workspace_id",
    "operation",
    "phase",
    "binding_revision",
    "previous_registry_generation",
    "previous_registry_sha256",
    "authority_sha256",
    "record_sha256",
    "staging_name",
    "destination_name",
    "display_name",
    "request_sha256",
    "staging_device_id",
    "staging_inode_id",
    "staging_uid",
    "staging_gid",
    "destination_device_id",
    "destination_inode_id",
    "destination_uid",
    "destination_gid",
    "legacy_project_id",
    "clearance_receipt_id",
    "confirmation_id",
    "created_at",
    "last_opened_at",
    "updated_at",
];

const LEGACY_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "workspace_id",
    "operation",
    "phase",
    "binding_revision",
    "previous_registry_generation",
    "previous_registry_sha256",
    "authority_sha256",
    "record_sha256",
    "staging_name",
    "destination_name",
    "legacy_project_id",
    "clearance_receipt_id",
    "confirmation_id",
    "created_at",
    "updated_at",
];

/// `DSHCanonicalUnsignedIntegerString`, as the journal spells an identifier.
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

fn is_null(value: Option<&Value>) -> bool {
    matches!(value, Some(Value::Null))
}

fn is(map: &Map<String, Value>, key: &str, value: &str) -> bool {
    map.get(key) == Some(&json!(value))
}

fn identity_key(prefix: &str, field: &str) -> String {
    format!("{prefix}{field}")
}

/// `DSHCreateRequestSHA256`: the digest a create journal must carry.
pub fn create_request_sha256(display_name: &str) -> Option<String> {
    let request = json!({ "operation": "create", "display_name": display_name });
    Some(sha256_hex(&canonical_json(&request).ok()?))
}

/// `DSHBootstrapRequestSHA256`: the digest a bootstrap journal must carry.
pub fn bootstrap_request_sha256(project_id: &str) -> Option<String> {
    let request = json!({
        "schema_version": 1, "operation": "bootstrap_legacy", "project_id": project_id
    });
    Some(sha256_hex(&canonical_json(&request).ok()?))
}

/// `DSHJournalIdentityPresent`: all four identifiers, each canonical.
pub fn identity_present(journal: Option<&Value>, prefix: &str) -> bool {
    let Some(journal) = journal else {
        return false;
    };
    IDENTITY_FIELDS
        .iter()
        .all(|field| unsigned_string(journal.get(identity_key(prefix, field))))
}

/// `DSHJournalIdentityMatchesState`: whether the recorded identity is the one
/// the host just stat'd.
///
/// The host renders `st_dev`, `st_ino`, `st_uid` and `st_gid` as the same
/// canonical decimal strings the journal holds, so this compares spellings
/// rather than re-parsing. That is exact, not a shortcut: a canonical unsigned
/// string and the number it denotes are in bijection, which is what makes the
/// canonical spelling worth insisting on in the first place.
pub fn identity_matches(journal: Option<&Value>, prefix: &str, observed: Option<&Value>) -> bool {
    if !identity_present(journal, prefix) {
        return false;
    }
    let (Some(journal), Some(observed)) = (journal, observed) else {
        return false;
    };
    IDENTITY_FIELDS.iter().all(|field| {
        let recorded = journal.get(identity_key(prefix, field));
        let seen = observed.get(*field);
        unsigned_string(seen) && recorded == seen
    })
}

/// `DSHOwnedAuthorityMatchesJournal`. The destination is preferred when it is
/// recorded: once the directory has moved, that is where the workspace lives,
/// and the staging identity describes a name that no longer exists.
pub fn owned_authority_matches_journal(authority: Option<&Value>, journal: Option<&Value>) -> bool {
    let prefix = if identity_present(journal, "destination_") {
        "destination_"
    } else {
        "staging_"
    };
    let (Some(authority), Some(journal)) = (authority, journal) else {
        return false;
    };
    ["device_id", "inode_id"].iter().all(|field| {
        let recorded = journal.get(identity_key(prefix, field));
        recorded.is_some() && authority.get(*field) == recorded
    })
}

/// The part every journal shape shares: identity, phase, and which digests a
/// phase implies.
fn common(map: &Map<String, Value>) -> bool {
    if map.get("schema_version") != Some(&json!(1))
        || !canonical_uuid(map.get("operation_id"))
        || !canonical_uuid(map.get("workspace_id"))
        || !map
            .get("phase")
            .and_then(Value::as_str)
            .is_some_and(|phase| PHASES.contains(&phase))
        || safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || safe_integer(
            map.get("previous_registry_generation"),
            MAX_SAFE_INTEGER,
            true,
        )
        .is_none()
        || !canonical_sha256(map.get("previous_registry_sha256"))
        || !canonical_timestamp(map.get("created_at"))
        || !canonical_timestamp(map.get("updated_at"))
    {
        return false;
    }
    // A phase says which digests exist yet. Nothing has been written at
    // `prepared`, so claiming a digest there describes a state that cannot
    // have occurred; every later phase has both.
    if is(map, "phase", "prepared") {
        is_null(map.get("authority_sha256")) && is_null(map.get("record_sha256"))
    } else {
        canonical_sha256(map.get("authority_sha256")) && canonical_sha256(map.get("record_sha256"))
    }
}

/// `validJournal:`. `folded_display_name` is the host's folding of
/// `display_name`, needed for the same reason `record_shape` needs it.
pub fn journal_shape(journal: Option<&Value>, folded_display_name: Option<&str>) -> bool {
    let Some(map) = exact_keys(journal, KEYS) else {
        return false;
    };
    if !map
        .get("operation")
        .and_then(Value::as_str)
        .is_some_and(|op| OPERATIONS.contains(&op))
        || !common(map)
        || !display_name(map.get("display_name"), folded_display_name)
        || !canonical_sha256(map.get("request_sha256"))
        || !canonical_timestamp(map.get("last_opened_at"))
    {
        return false;
    }
    // Every optional string is a string or absent, never a number.
    let nullable = [
        "staging_name",
        "destination_name",
        "clearance_receipt_id",
        "confirmation_id",
        "staging_device_id",
        "staging_inode_id",
        "staging_uid",
        "staging_gid",
        "destination_device_id",
        "destination_inode_id",
        "destination_uid",
        "destination_gid",
    ];
    if !nullable
        .iter()
        .all(|key| is_null(map.get(*key)) || matches!(map.get(*key), Some(Value::String(_))))
    {
        return false;
    }
    // Physical identity is recorded in fours: three of four is not partial
    // evidence, it is a journal no recovery engine can check against a
    // directory.
    for prefix in ["staging_", "destination_"] {
        let any = IDENTITY_FIELDS
            .iter()
            .any(|field| !is_null(map.get(&identity_key(prefix, field))));
        if any != identity_present(journal, prefix) {
            return false;
        }
    }
    match map.get("operation").and_then(Value::as_str) {
        // Bootstrapping adopts a project that already exists on disk. There is
        // no directory to stage or move, so every name and identity is absent,
        // and it is always the first binding.
        Some("bootstrap_legacy") => {
            map.get("binding_revision") == Some(&json!(1))
                && canonical_uuid(map.get("legacy_project_id"))
                && map.get("request_sha256")
                    == map
                        .get("legacy_project_id")
                        .and_then(Value::as_str)
                        .and_then(bootstrap_request_sha256)
                        .map(Value::String)
                        .as_ref()
                && [
                    "staging_name",
                    "destination_name",
                    "clearance_receipt_id",
                    "confirmation_id",
                ]
                .iter()
                .all(|key| is_null(map.get(*key)))
                && ["staging_", "destination_"].iter().all(|prefix| {
                    IDENTITY_FIELDS
                        .iter()
                        .all(|field| is_null(map.get(&identity_key(prefix, field))))
                })
        }
        // Creating stages a directory under one name and moves it to another,
        // so both names are real components and they differ — a move onto
        // itself is not a move, and recovery could not tell the two apart.
        Some("create") => {
            map.get("binding_revision") == Some(&json!(1))
                && internal_component(map.get("staging_name"))
                && internal_component(map.get("destination_name"))
                && map.get("staging_name") != map.get("destination_name")
                && map.get("request_sha256")
                    == map
                        .get("display_name")
                        .and_then(Value::as_str)
                        .and_then(create_request_sha256)
                        .map(Value::String)
                        .as_ref()
                && ["legacy_project_id", "clearance_receipt_id", "confirmation_id"]
                    .iter()
                    .all(|key| is_null(map.get(*key)))
                // Once the directory exists, both identities are recorded.
                && (is(map, "phase", "prepared")
                    || ["staging_", "destination_"].iter().all(|prefix| {
                        IDENTITY_FIELDS
                            .iter()
                            .all(|field| !is_null(map.get(&identity_key(prefix, field))))
                    }))
        }
        _ => false,
    }
}

/// `validLegacyJournal:`. A narrower, older shape: bootstrap only, no display
/// name, no physical identity, no request digest. It stays readable so an
/// operation interrupted before this field set grew can still be recovered.
pub fn legacy_journal_shape(journal: Option<&Value>) -> bool {
    let Some(map) = exact_keys(journal, LEGACY_KEYS) else {
        return false;
    };
    is(map, "operation", "bootstrap_legacy")
        && common(map)
        && canonical_uuid(map.get("legacy_project_id"))
        && [
            "staging_name",
            "destination_name",
            "clearance_receipt_id",
            "confirmation_id",
        ]
        .iter()
        .all(|key| is_null(map.get(*key)))
}

/// Either shape.
pub fn readable_journal(journal: Option<&Value>, folded_display_name: Option<&str>) -> bool {
    journal_shape(journal, folded_display_name) || legacy_journal_shape(journal)
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_journal_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    let journal = envelope.get("journal");
    let folded = text(envelope, "folded_display_name");
    Some(match text(envelope, "op")? {
        "journal_shape" => json!({ "ok": true, "valid": journal_shape(journal, folded) }),
        "legacy_journal_shape" => {
            json!({ "ok": true, "valid": legacy_journal_shape(journal) })
        }
        "readable_journal" => {
            json!({ "ok": true, "valid": readable_journal(journal, folded) })
        }
        "identity_present" => json!({
            "ok": true, "present": identity_present(journal, text(envelope, "prefix")?)
        }),
        "identity_matches" => json!({
            "ok": true,
            "matches": identity_matches(
                journal, text(envelope, "prefix")?, envelope.get("observed")
            ),
        }),
        "owned_authority_matches" => json!({
            "ok": true,
            "matches": owned_authority_matches_journal(envelope.get("authority"), journal),
        }),
        "create_request_sha256" => json!({
            "ok": true, "digest": create_request_sha256(text(envelope, "display_name")?)
        }),
        "bootstrap_request_sha256" => json!({
            "ok": true, "digest": bootstrap_request_sha256(text(envelope, "project_id")?)
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_journal_tests.rs"]
mod tests;
