//! How the project-context store names what it keeps, and what an interrupted
//! prepare transaction resolves to on the next launch.
//!
//! Ported from `DSHStoreCanonicalId`, `DSHStoreSafeReferenceKey`,
//! `DSHStoreHexDigest`, `DSHPrepareTransactionKey`, the reference-key
//! permissions in `setReferenceKey:` and the recovery sweep in
//! `ProjectContextStore.mm`.
//!
//! **A reference is a name pointing at a snapshot.** Three namespaces:
//!
//! - `active:<conversation>` — what a conversation is currently using.
//! - `retry:<…>` — a snapshot held so a retry can reuse it. The only kind a
//!   caller may set directly.
//! - `txn:prepare:<conversation>` — written *before* `active:` is swapped, and
//!   holding the id to go back to. It is the store's own bookkeeping, never a
//!   caller's, and it is not supposed to outlive the swap.
//!
//! A `txn:prepare:` key still present at launch means the process died
//! mid-swap, and resolving it is the one real decision in this file.

use serde_json::{json, Map, Value};

/// A record is at most this many bytes.
pub const MAX_RECORD_BYTES: usize = 1024 * 1024;

/// The reference file is at most this many bytes.
pub const MAX_REFERENCE_BYTES: usize = 1024 * 1024;

/// A reference key is at most this many characters.
pub const MAX_REFERENCE_KEY_LEN: usize = 256;

/// The id a prepare transaction records when there was **no prior snapshot**
/// to roll back to. It is the nil UUID, and it is deliberately not a valid
/// snapshot id: rolling "back" to it would mean pointing a conversation at a
/// snapshot that never existed.
pub const NO_PRIOR_SNAPSHOT_ID: &str = "00000000-0000-0000-0000-000000000000";

const ACTIVE_PREFIX: &str = "active:";
const RETRY_PREFIX: &str = "retry:";
const TRANSACTION_PREFIX: &str = "txn:prepare:";

/// `DSHStoreCanonicalId`: a lowercase canonical UUID that is not the sentinel.
pub fn canonical_snapshot_id(value: &str) -> bool {
    if value.len() != 36 || value == NO_PRIOR_SNAPSHOT_ID {
        return false;
    }
    value.bytes().enumerate().all(|(index, byte)| {
        if matches!(index, 8 | 13 | 18 | 23) {
            byte == b'-'
        } else {
            byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
        }
    })
}

/// `DSHStoreSafeReferenceKey`: a bounded key from a closed alphabet, so a key
/// can never be a path component that escapes the store.
pub fn safe_reference_key(value: &str) -> bool {
    !value.is_empty()
        && value.chars().count() <= MAX_REFERENCE_KEY_LEN
        && value
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, ':' | '-' | '_' | '.'))
}

/// `DSHStoreHexDigest`.
pub fn hex_digest(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

/// `DSHPrepareTransactionKey`: the transaction key that pairs with an active
/// key, or `None` when the active key is not one.
pub fn prepare_transaction_key(active_key: &str) -> Option<String> {
    let conversation = active_key.strip_prefix(ACTIVE_PREFIX)?;
    canonical_snapshot_id(conversation).then(|| format!("{TRANSACTION_PREFIX}{conversation}"))
}

/// The inverse, used by recovery to find the active key a transaction was
/// swapping.
pub fn active_key_for_transaction(transaction_key: &str) -> Option<String> {
    let conversation = transaction_key.strip_prefix(TRANSACTION_PREFIX)?;
    Some(format!("{ACTIVE_PREFIX}{conversation}"))
}

/// Which keys a caller may set. Only `retry:` — `active:` is the store's to
/// move, and `txn:prepare:` is its bookkeeping. A caller that could write
/// either could point a conversation at a snapshot of its choosing.
pub fn settable_reference_key(key: &str) -> bool {
    key.starts_with(RETRY_PREFIX) && safe_reference_key(key)
}

/// Which keys survive a recovery sweep at all.
pub fn retained_reference_key(key: &str) -> bool {
    key.starts_with(ACTIVE_PREFIX) || key.starts_with(RETRY_PREFIX)
}

/// What recovery makes of the stored references.
pub struct Recovery {
    /// The references to keep.
    pub references: Map<String, Value>,
    /// Snapshots a transaction had newly written and that are now unreferenced
    /// — the caller collects them.
    pub transaction_new_ids: Vec<String>,
}

/// Resolves every interrupted prepare transaction, then drops what no longer
/// names a live snapshot.
///
/// **Three of the checks inside the loop are redundant with the sweep that
/// follows**, and are kept because they mirror the original line for line and
/// because the sweep is a separate rule that could change: refusing to roll
/// back to the sentinel, refusing to roll back to an id that is gone, and
/// removing the transaction key. In each case the sweep would drop the same
/// key a moment later, so no input the host can produce tells them apart. Said
/// here rather than left to look load-bearing; see
/// `the_sweep_is_what_actually_drops_them`.
///
/// A transaction key holds the id to go **back** to. The subtle case is
/// `crash_before_swap`: when the active key still holds the same id the
/// transaction recorded, `active:` was never moved, so there is nothing to
/// undo and the new snapshot is *not* collected. Undoing there would throw
/// away the snapshot the conversation is actually using.
pub fn recover_references(references: &Map<String, Value>, valid_ids: &[String]) -> Recovery {
    let mut result = references.clone();
    let mut transaction_new_ids: Vec<String> = Vec::new();
    let mut transaction_keys: Vec<String> = references
        .keys()
        .filter(|key| key.starts_with(TRANSACTION_PREFIX))
        .cloned()
        .collect();
    transaction_keys.sort();

    for key in transaction_keys {
        let Some(active_key) = active_key_for_transaction(&key) else {
            continue;
        };
        let new_id = result
            .get(&active_key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        let rollback_id = result
            .get(&key)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if canonical_snapshot_id(&new_id) {
            let crash_before_swap = new_id == rollback_id && rollback_id != NO_PRIOR_SNAPSHOT_ID;
            if !crash_before_swap {
                if rollback_id != NO_PRIOR_SNAPSHOT_ID && valid_ids.contains(&rollback_id) {
                    result.insert(active_key.clone(), json!(rollback_id));
                } else {
                    // Nothing to go back to: the conversation had no snapshot
                    // before this transaction, so it has none after it.
                    result.remove(&active_key);
                }
                transaction_new_ids.push(new_id);
            }
        }
        result.remove(&key);
    }

    let stale: Vec<String> = result
        .iter()
        .filter(|(key, value)| {
            !retained_reference_key(key)
                || !value
                    .as_str()
                    .is_some_and(|id| valid_ids.iter().any(|valid| valid == id))
        })
        .map(|(key, _)| key.clone())
        .collect();
    for key in stale {
        result.remove(&key);
    }

    Recovery {
        references: result,
        transaction_new_ids,
    }
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

fn string_list(value: Option<&Value>) -> Option<Vec<String>> {
    value?
        .as_array()?
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

/// One envelope in, one reply out; see
/// `rish_agent_project_context_store_reduce`.
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
        "canonical_snapshot_id" => json!({
            "ok": true, "valid": canonical_snapshot_id(text(envelope, "value")?)
        }),
        "safe_reference_key" => json!({
            "ok": true, "valid": safe_reference_key(text(envelope, "value")?)
        }),
        "hex_digest" => json!({
            "ok": true, "valid": hex_digest(text(envelope, "value")?)
        }),
        "settable_reference_key" => json!({
            "ok": true, "valid": settable_reference_key(text(envelope, "value")?)
        }),
        "prepare_transaction_key" => json!({
            "ok": true, "key": prepare_transaction_key(text(envelope, "active_key")?)
        }),
        "recover_references" => {
            let references = envelope.get("references")?.as_object()?;
            let valid = string_list(envelope.get("valid_ids"))?;
            let recovery = recover_references(references, &valid);
            json!({
                "ok": true,
                "references": Value::Object(recovery.references),
                "transaction_new_ids": recovery.transaction_new_ids,
            })
        }
        _ => return None,
    })
}

#[cfg(test)]
#[path = "project_context_store_tests.rs"]
mod tests;
