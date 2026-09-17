//! What a stored workspace operation receipt looks like, what a caller is
//! shown of one, and which receipts have outlived their purpose.
//!
//! Ported from `validReceipt:`, `validLegacyReceipt:`,
//! `DSHPublicOperationReceipt`, the receipt-store checks in `loadReceipts:`
//! and the expiry test in `pruneReceipts:` in `LocalWorkspaceAccess.mm`.
//!
//! One known tightening, shared with `workspace_record`: Foundation accepts an
//! integral *double* as a safe integer, so ObjC reads `3.0` as revision 3. The
//! core does not. Nothing writes a fractional revision, and a record carrying
//! one is already invalid under `record_shape`, so the only reachable case is
//! a hand-edited receipt — which is refused rather than read generously.
//!
//! A receipt is how a retried operation is recognised as the one that already
//! happened. That makes two things load-bearing: the operation id is unique
//! across the store, and `request_sha256` binds the receipt to the request
//! that produced it. The second is why the public projection leaves it out —
//! it is an idempotency secret, not a fact about the workspace.

use serde_json::{json, Map, Value};

use crate::schema::{
    canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys, safe_integer,
    MAX_SAFE_INTEGER,
};

/// The operations a receipt may record. Closed: a receipt naming anything else
/// is not one this engine wrote.
pub const OPERATIONS: &[&str] = &[
    "create",
    "import",
    "regrant",
    "forget",
    "delete_owned",
    "bootstrap_legacy",
];

/// The receipt store holds at most this many.
pub const MAX_RECEIPTS: usize = 2048;

/// A receipt is kept for thirty days. After that the operation it records can
/// no longer be retried, so remembering it only costs storage.
pub const RECEIPT_TTL_SECONDS: f64 = 30.0 * 24.0 * 60.0 * 60.0;

const BASE_KEYS: &[&str] = &[
    "schema_version",
    "operation_id",
    "workspace_id",
    "operation",
    "binding_revision",
    "registry_generation",
    "registry_sha256",
    "outcome",
    "committed_at",
];

fn is(map: &Map<String, Value>, key: &str, value: &str) -> bool {
    map.get(key) == Some(&json!(value))
}

fn shape(receipt: Option<&Value>, keys: &[&str]) -> bool {
    let Some(map) = exact_keys(receipt, keys) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1))
        || !canonical_uuid(map.get("operation_id"))
        || !canonical_uuid(map.get("workspace_id"))
        || !map
            .get("operation")
            .and_then(Value::as_str)
            .is_some_and(|op| OPERATIONS.contains(&op))
        // A binding revision counts from one; a registry generation counts
        // from zero, because an empty registry is a generation.
        || safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_none()
        || safe_integer(map.get("registry_generation"), MAX_SAFE_INTEGER, true).is_none()
        || !canonical_sha256(map.get("registry_sha256"))
        || !(is(map, "outcome", "committed") || is(map, "outcome", "purge_pending"))
        || !canonical_timestamp(map.get("committed_at"))
    {
        return false;
    }
    // Only a delete leaves content behind to purge.
    if is(map, "outcome", "purge_pending") && !is(map, "operation", "delete_owned") {
        return false;
    }
    // Bootstrapping a legacy project is what *creates* the binding, so it can
    // only have committed, and only at the first revision.
    if is(map, "operation", "bootstrap_legacy")
        && (!is(map, "outcome", "committed") || map.get("binding_revision") != Some(&json!(1)))
    {
        return false;
    }
    true
}

/// `validReceipt:`. Every receipt this engine writes carries the digest of the
/// request that produced it.
pub fn receipt_shape(receipt: Option<&Value>) -> bool {
    let mut keys = BASE_KEYS.to_vec();
    keys.push("request_sha256");
    shape(receipt, &keys) && canonical_sha256(receipt.and_then(|r| r.get("request_sha256")))
}

/// `validLegacyReceipt:`. A1 receipts predate `request_sha256`. They stay
/// readable and are **not** rewritten in place: the registry record and the
/// authority are what a retry is validated against, so nothing is gained by
/// inventing a digest for a request nobody kept.
pub fn legacy_receipt_shape(receipt: Option<&Value>) -> bool {
    shape(receipt, BASE_KEYS)
}

/// Either form.
pub fn readable_receipt(receipt: Option<&Value>) -> bool {
    receipt_shape(receipt) || legacy_receipt_shape(receipt)
}

/// `DSHPublicOperationReceipt`: what a caller querying an operation is shown.
///
/// The keys are enumerated rather than copied, and `request_sha256` is not
/// among them. It is a private idempotency binding — it stays in the protected
/// store for retry and conflict detection, and handing it out would let a
/// caller forge the recognition of an operation it never made.
pub fn public_receipt(receipt: Option<&Value>) -> Option<Value> {
    let map = receipt?.as_object()?;
    let field = |key: &str| map.get(key).cloned().unwrap_or(Value::Null);
    Some(json!({
        "schema_version": field("schema_version"),
        "operation_id": field("operation_id"),
        "workspace_id": field("workspace_id"),
        "operation": field("operation"),
        "binding_revision": field("binding_revision"),
        "registry_generation": field("registry_generation"),
        "registry_sha256": field("registry_sha256"),
        "outcome": field("outcome"),
        "committed_at": field("committed_at"),
    }))
}

/// The store's own shape, from `loadReceipts:`: the envelope, the capacity,
/// every receipt readable in one form or the other, and no operation id twice.
///
/// A repeated operation id is not a duplicate to be tolerated: the whole point
/// of a receipt is that one operation id names one outcome, and a store that
/// holds two of them cannot say which retry is the one that happened.
pub fn receipt_store_shape(envelope: Option<&Value>) -> bool {
    let Some(map) = exact_keys(envelope, &["schema_version", "receipts"]) else {
        return false;
    };
    if map.get("schema_version") != Some(&json!(1)) {
        return false;
    }
    let Some(Value::Array(receipts)) = map.get("receipts") else {
        return false;
    };
    if receipts.len() > MAX_RECEIPTS {
        return false;
    }
    let mut seen: Vec<&Value> = Vec::with_capacity(receipts.len());
    for receipt in receipts {
        if !readable_receipt(Some(receipt)) {
            return false;
        }
        let id = receipt.get("operation_id").unwrap_or(&Value::Null);
        if seen.contains(&id) {
            return false;
        }
        seen.push(id);
    }
    true
}

/// Whether one more receipt fits. The store is bounded so that a caller
/// replaying operations cannot grow it without limit; a full store refuses the
/// operation rather than dropping a receipt that a retry may still need.
pub fn has_room(count: Option<u64>) -> bool {
    match count {
        Some(count) => count < MAX_RECEIPTS as u64,
        None => false,
    }
}

/// Whether a receipt has outlived its retry window, given how long ago the
/// host says it was committed. Parsing the timestamp stays with the host — it
/// has the calendar — and a receipt whose timestamp will not parse is expired
/// too: it can never be matched against a retry, so keeping it is pure cost.
pub fn receipt_expired(age_seconds: Option<f64>) -> bool {
    match age_seconds {
        Some(age) => age > RECEIPT_TTL_SECONDS,
        None => true,
    }
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_receipt_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    let receipt = envelope.get("receipt");
    Some(match text(envelope, "op")? {
        "receipt_shape" => json!({ "ok": true, "valid": receipt_shape(receipt) }),
        "legacy_receipt_shape" => {
            json!({ "ok": true, "valid": legacy_receipt_shape(receipt) })
        }
        "readable_receipt" => json!({ "ok": true, "valid": readable_receipt(receipt) }),
        "store_shape" => json!({
            "ok": true, "valid": receipt_store_shape(envelope.get("envelope"))
        }),
        "public_receipt" => json!({ "ok": true, "receipt": public_receipt(receipt) }),
        "has_room" => json!({
            "ok": true,
            "has_room": has_room(envelope.get("count").and_then(Value::as_u64)),
        }),
        "expired" => json!({
            "ok": true,
            "expired": receipt_expired(envelope.get("age_seconds").and_then(Value::as_f64)),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_receipt_tests.rs"]
mod tests;
