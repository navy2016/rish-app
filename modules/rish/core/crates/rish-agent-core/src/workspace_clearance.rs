//! What a workspace clearance operation and its receipt look like.
//!
//! Ported from `DSHWorkspaceClearanceCanonicalOperationFields`,
//! `DSHWorkspaceClearanceReceiptFields` and
//! `DSHWorkspaceClearanceSessionReferenceValid` in
//! `WorkspaceClearanceStore.mm`.
//!
//! A clearance is the proof that a destructive workspace operation — forget,
//! or delete the owned content — was authorised against a *specific committed
//! session*. That is the whole point of the receipt: it names the session
//! generation and digest the person was looking at when they agreed. Without
//! that, "they said yes" could mean yes to a different state.
//!
//! **Its numbers are the workspace receipt store's numbers**, and deliberately
//! so: 2048 receipts, thirty days. They are re-exported from
//! `workspace_receipt` rather than written again, because two stores that
//! expire on different schedules would be two policies nobody decided on.

use serde_json::{json, Map, Value};

use crate::schema::{
    canonical_sha256, canonical_timestamp, canonical_uuid, exact_keys, safe_integer,
    MAX_SAFE_INTEGER,
};
pub use crate::workspace_receipt::{MAX_RECEIPTS, RECEIPT_TTL_SECONDS};

/// The destructive operations a clearance can authorise. Closed: a clearance
/// is only ever asked for before one of these two.
pub const ACTIONS: &[&str] = &["forget", "delete_owned"];

/// The clearance store holds at most this many bytes.
pub const MAX_STORE_BYTES: usize = 512 * 1024;

/// `DSHWorkspaceClearanceCanonicalOperationFields`.
pub fn operation_shape(operation: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        operation,
        &[
            "schema_version",
            "operation_id",
            "action",
            "workspace_id",
            "binding_revision",
            "clearance_receipt_id",
            "created_at",
        ],
    ) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && canonical_uuid(map.get("operation_id"))
        && map
            .get("action")
            .and_then(Value::as_str)
            .is_some_and(|action| ACTIONS.contains(&action))
        && canonical_uuid(map.get("workspace_id"))
        && safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_some()
        && canonical_uuid(map.get("clearance_receipt_id"))
        && canonical_timestamp(map.get("created_at"))
}

/// `DSHWorkspaceClearanceReceiptFields`.
///
/// The receipt carries the committed session it was issued against. An
/// operation holding a receipt for a different session is holding consent the
/// person never gave for *this* state.
pub fn receipt_shape(receipt: Option<&Value>) -> bool {
    let Some(map) = exact_keys(
        receipt,
        &[
            "schema_version",
            "clearance_receipt_id",
            "operation_id",
            "workspace_id",
            "binding_revision",
            "committed_session_generation",
            "committed_session_sha256",
            "issued_at",
        ],
    ) else {
        return false;
    };
    map.get("schema_version") == Some(&json!(1))
        && canonical_uuid(map.get("clearance_receipt_id"))
        && canonical_uuid(map.get("operation_id"))
        && canonical_uuid(map.get("workspace_id"))
        && safe_integer(map.get("binding_revision"), MAX_SAFE_INTEGER, false).is_some()
        // A session generation counts from one: generation zero is "no session
        // has ever been committed", which nobody can have agreed to.
        && safe_integer(
            map.get("committed_session_generation"),
            MAX_SAFE_INTEGER,
            false,
        )
        .is_some()
        && canonical_sha256(map.get("committed_session_sha256"))
        && canonical_timestamp(map.get("issued_at"))
}

/// `DSHWorkspaceClearanceSessionReferenceValid`: whether a generation and
/// digest name a session that can have been agreed to.
pub fn session_reference_valid(generation: Option<&Value>, digest: Option<&Value>) -> bool {
    safe_integer(generation, MAX_SAFE_INTEGER, false).is_some_and(|value| value < MAX_SAFE_INTEGER)
        && canonical_sha256(digest)
}

/// Whether a receipt belongs to the operation about to be carried out. All
/// four have to agree: a receipt for the right workspace at the wrong binding
/// is consent for a root that has since been rebound.
pub fn receipt_authorises(receipt: Option<&Value>, operation: Option<&Value>) -> bool {
    if !receipt_shape(receipt) || !operation_shape(operation) {
        return false;
    }
    let (Some(receipt), Some(operation)) = (receipt, operation) else {
        return false;
    };
    receipt.get("clearance_receipt_id") == operation.get("clearance_receipt_id")
        && receipt.get("operation_id") == operation.get("operation_id")
        && receipt.get("workspace_id") == operation.get("workspace_id")
        && receipt.get("binding_revision") == operation.get("binding_revision")
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_clearance_reduce`.
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
        "operation_shape" => json!({
            "ok": true, "valid": operation_shape(envelope.get("operation"))
        }),
        "receipt_shape" => json!({
            "ok": true, "valid": receipt_shape(envelope.get("receipt"))
        }),
        "session_reference_valid" => json!({
            "ok": true,
            "valid": session_reference_valid(
                envelope.get("generation"),
                envelope.get("sha256"),
            ),
        }),
        "receipt_authorises" => json!({
            "ok": true,
            "authorises": receipt_authorises(
                envelope.get("receipt"),
                envelope.get("operation"),
            ),
        }),
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_clearance_tests.rs"]
mod tests;
