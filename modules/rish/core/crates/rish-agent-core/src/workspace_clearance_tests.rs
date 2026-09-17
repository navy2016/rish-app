use super::*;

const OPERATION: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const WORKSPACE: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const RECEIPT: &str = "c3d4e5f6-3333-4333-8333-3333abcd3333";
const STAMP: &str = "2026-02-03T04:05:06.789Z";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

fn operation() -> Value {
    json!({
        "schema_version": 1,
        "operation_id": OPERATION,
        "action": "forget",
        "workspace_id": WORKSPACE,
        "binding_revision": 3,
        "clearance_receipt_id": RECEIPT,
        "created_at": STAMP,
    })
}

fn receipt() -> Value {
    json!({
        "schema_version": 1,
        "clearance_receipt_id": RECEIPT,
        "operation_id": OPERATION,
        "workspace_id": WORKSPACE,
        "binding_revision": 3,
        "committed_session_generation": 12,
        "committed_session_sha256": digest('a'),
        "issued_at": STAMP,
    })
}

#[test]
fn both_shapes_accept_what_the_store_writes() {
    assert!(operation_shape(Some(&operation())));
    assert!(receipt_shape(Some(&receipt())));
    assert!(receipt_authorises(Some(&receipt()), Some(&operation())));
    let mut deleting = operation();
    deleting["action"] = json!("delete_owned");
    assert!(operation_shape(Some(&deleting)));
}

/// A clearance authorises exactly two destructive operations. Anything else
/// naming itself a clearance is asking for consent nobody defined.
#[test]
fn only_the_two_destructive_actions_can_be_cleared() {
    assert_eq!(ACTIONS, ["forget", "delete_owned"]);
    for action in ["create", "import", "regrant", "", "Forget", "delete"] {
        let mut other = operation();
        other["action"] = json!(action);
        assert!(!operation_shape(Some(&other)), "{action}");
    }
}

#[test]
fn both_shapes_are_exact_and_typed() {
    for (name, value, check) in [
        (
            "operation",
            operation(),
            operation_shape as fn(Option<&Value>) -> bool,
        ),
        (
            "receipt",
            receipt(),
            receipt_shape as fn(Option<&Value>) -> bool,
        ),
    ] {
        assert!(check(Some(&value)), "{name}");
        let mut extra = value.clone();
        extra["extra"] = json!(1);
        assert!(!check(Some(&extra)), "{name} with an extra key");
        for key in value.as_object().expect("object").keys() {
            let mut short = value.clone();
            short.as_object_mut().expect("object").remove(key);
            assert!(!check(Some(&short)), "{name} without {key}");
        }
        assert!(!check(None), "{name} absent");
        assert!(!check(Some(&Value::Null)), "{name} null");
        assert!(!check(Some(&json!([]))), "{name} array");
        // Identifiers are canonical UUIDs, not any old string.
        let mut sloppy = value.clone();
        sloppy["workspace_id"] = json!("not-a-uuid");
        assert!(!check(Some(&sloppy)), "{name} with a loose id");
        let mut versioned = value.clone();
        versioned["schema_version"] = json!(2);
        assert!(!check(Some(&versioned)), "{name} at another version");
    }
}

/// A binding revision and a committed session generation both count from one.
/// Generation zero is "no session has ever been committed", which nobody can
/// have agreed to.
#[test]
fn a_cleared_session_has_actually_been_committed() {
    for (key, value) in [
        ("binding_revision", json!(0)),
        ("committed_session_generation", json!(0)),
        ("committed_session_generation", json!(-1)),
        ("committed_session_generation", json!("12")),
    ] {
        let mut broken = receipt();
        broken[key] = value.clone();
        assert!(!receipt_shape(Some(&broken)), "{key} = {value}");
    }
    assert!(session_reference_valid(
        Some(&json!(1)),
        Some(&json!(digest('a')))
    ));
    assert!(!session_reference_valid(
        Some(&json!(0)),
        Some(&json!(digest('a')))
    ));
    assert!(!session_reference_valid(None, Some(&json!(digest('a')))));
    assert!(!session_reference_valid(
        Some(&json!(1)),
        Some(&json!("abc"))
    ));
    assert!(!session_reference_valid(Some(&json!(1)), None));
    // The top of the safe range is excluded, matching the original: a
    // generation there could not be advanced again.
    assert!(!session_reference_valid(
        Some(&json!(MAX_SAFE_INTEGER)),
        Some(&json!(digest('a')))
    ));
    assert!(session_reference_valid(
        Some(&json!(MAX_SAFE_INTEGER - 1)),
        Some(&json!(digest('a')))
    ));
}

/// All four identities have to agree. A receipt for the right workspace at the
/// wrong binding is consent for a root that has since been rebound; a receipt
/// for another operation is consent the person gave to something else.
#[test]
fn a_receipt_authorises_only_its_own_operation() {
    for (key, value) in [
        ("clearance_receipt_id", json!(WORKSPACE)),
        ("operation_id", json!(WORKSPACE)),
        ("workspace_id", json!(OPERATION)),
        ("binding_revision", json!(4)),
    ] {
        let mut elsewhere = receipt();
        elsewhere[key] = value.clone();
        assert!(
            !receipt_authorises(Some(&elsewhere), Some(&operation())),
            "{key}"
        );
    }
    // A malformed half authorises nothing, rather than being compared field by
    // field against something that is not an operation.
    assert!(!receipt_authorises(Some(&receipt()), Some(&json!({}))));
    assert!(!receipt_authorises(Some(&json!({})), Some(&operation())));
    assert!(!receipt_authorises(None, Some(&operation())));
    assert!(!receipt_authorises(Some(&receipt()), None));
}

/// The clearance store's bounds are the workspace receipt store's bounds, and
/// are re-exported rather than restated: two stores expiring on different
/// schedules would be two policies nobody decided on.
#[test]
fn the_bounds_are_the_workspace_receipt_stores_bounds() {
    assert_eq!(MAX_RECEIPTS, crate::workspace_receipt::MAX_RECEIPTS);
    assert_eq!(
        RECEIPT_TTL_SECONDS,
        crate::workspace_receipt::RECEIPT_TTL_SECONDS
    );
    assert_eq!(MAX_RECEIPTS, 2048);
    assert_eq!(RECEIPT_TTL_SECONDS, 2_592_000.0);
    assert_eq!(MAX_STORE_BYTES, 524_288);
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "operation_shape", "operation": operation() })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "receipt_shape", "receipt": receipt() })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "session_reference_valid", "generation": 12, "sha256": digest('a') })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({
            "op": "receipt_authorises", "receipt": receipt(), "operation": operation()
        })),
        json!({ "ok": true, "authorises": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "operation": operation() }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
