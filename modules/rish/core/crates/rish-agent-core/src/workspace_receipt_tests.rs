use super::*;

const OPERATION: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const WORKSPACE: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const STAMP: &str = "2026-02-03T04:05:06.789Z";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

fn receipt() -> Value {
    json!({
        "schema_version": 1,
        "operation_id": OPERATION,
        "workspace_id": WORKSPACE,
        "operation": "create",
        "binding_revision": 1,
        "registry_generation": 0,
        "registry_sha256": digest('a'),
        "request_sha256": digest('b'),
        "outcome": "committed",
        "committed_at": STAMP,
    })
}

fn legacy_receipt() -> Value {
    let mut map = receipt();
    map.as_object_mut()
        .expect("object")
        .remove("request_sha256");
    map
}

fn store(receipts: Vec<Value>) -> Value {
    json!({ "schema_version": 1, "receipts": receipts })
}

/// The two forms differ by exactly one key, and each refuses the other's.
#[test]
fn a_receipt_carries_its_request_digest_unless_it_predates_one() {
    assert!(receipt_shape(Some(&receipt())));
    assert!(!receipt_shape(Some(&legacy_receipt())));
    assert!(legacy_receipt_shape(Some(&legacy_receipt())));
    // An A1 receipt is not simply a receipt with a key missing: the shape is
    // exact both ways, so a new receipt cannot pass as an old one.
    assert!(!legacy_receipt_shape(Some(&receipt())));
    assert!(readable_receipt(Some(&receipt())));
    assert!(readable_receipt(Some(&legacy_receipt())));
}

#[test]
fn the_shape_is_exact_and_typed() {
    for shape_fn in [
        receipt_shape as fn(Option<&Value>) -> bool,
        legacy_receipt_shape as fn(Option<&Value>) -> bool,
    ] {
        let base = if shape_fn(Some(&receipt())) {
            receipt()
        } else {
            legacy_receipt()
        };
        assert!(shape_fn(Some(&base)));
        let mut extra = base.clone();
        extra["extra"] = json!(1);
        assert!(!shape_fn(Some(&extra)));
        for key in base.as_object().expect("object").keys() {
            let mut short = base.clone();
            short.as_object_mut().expect("object").remove(key);
            assert!(!shape_fn(Some(&short)), "without {key}");
        }
        assert!(!shape_fn(None));
        assert!(!shape_fn(Some(&Value::Null)));
        assert!(!shape_fn(Some(&json!([]))));
    }
}

#[test]
fn every_field_is_the_spelling_the_store_writes() {
    for (key, value) in [
        ("schema_version", json!(2)),
        ("schema_version", json!("1")),
        ("schema_version", json!(true)),
        ("operation_id", json!("not-a-uuid")),
        ("workspace_id", json!(Value::Null)),
        ("operation", json!("teleport")),
        ("operation", json!("")),
        ("registry_sha256", json!(digest('A'))),
        ("request_sha256", json!("abc")),
        ("outcome", json!("pending")),
        ("outcome", json!("Committed")),
        ("committed_at", json!("2026-02-03T04:05:06Z")),
        ("committed_at", json!(0)),
    ] {
        let mut broken = receipt();
        broken[key] = value.clone();
        assert!(!receipt_shape(Some(&broken)), "{key} = {value}");
    }
}

/// A binding revision counts from one; a registry generation counts from zero,
/// because an empty registry is a generation and not the absence of one.
#[test]
fn a_generation_may_be_zero_and_a_revision_may_not() {
    let mut zero_generation = receipt();
    zero_generation["registry_generation"] = json!(0);
    assert!(receipt_shape(Some(&zero_generation)));
    let mut zero_revision = receipt();
    zero_revision["binding_revision"] = json!(0);
    assert!(!receipt_shape(Some(&zero_revision)));
    for (key, value) in [
        ("binding_revision", json!(-1)),
        ("binding_revision", json!("1")),
        ("binding_revision", json!(true)),
        ("registry_generation", json!(-1)),
        // Past what a JSON consumer can hold exactly.
        ("registry_generation", json!(MAX_SAFE_INTEGER + 1)),
    ] {
        let mut broken = receipt();
        broken[key] = value.clone();
        assert!(!receipt_shape(Some(&broken)), "{key} = {value}");
    }
    let mut widest = receipt();
    widest["registry_generation"] = json!(MAX_SAFE_INTEGER);
    assert!(receipt_shape(Some(&widest)));
}

/// Only a delete leaves content behind, so only a delete can be pending a
/// purge. Any other operation claiming it is describing something that cannot
/// have happened.
#[test]
fn only_a_delete_can_be_pending_a_purge() {
    let mut deleting = receipt();
    deleting["operation"] = json!("delete_owned");
    deleting["outcome"] = json!("purge_pending");
    assert!(receipt_shape(Some(&deleting)));
    for operation in ["create", "import", "regrant", "forget", "bootstrap_legacy"] {
        let mut pending = receipt();
        pending["operation"] = json!(operation);
        pending["outcome"] = json!("purge_pending");
        assert!(!receipt_shape(Some(&pending)), "{operation}");
    }
}

/// Bootstrapping a legacy project is what creates the binding, so it can only
/// have committed, and only at the first revision. A bootstrap receipt at
/// revision 2 would claim the binding existed before it was made.
#[test]
fn a_bootstrap_can_only_be_the_first_committed_binding() {
    let mut bootstrap = receipt();
    bootstrap["operation"] = json!("bootstrap_legacy");
    assert!(receipt_shape(Some(&bootstrap)));
    let mut later = bootstrap.clone();
    later["binding_revision"] = json!(2);
    assert!(!receipt_shape(Some(&later)));
    let mut pending = bootstrap.clone();
    pending["outcome"] = json!("purge_pending");
    assert!(!receipt_shape(Some(&pending)));
    // The revision bound is only on bootstrap; other operations rebind freely.
    let mut rebound = receipt();
    rebound["operation"] = json!("regrant");
    rebound["binding_revision"] = json!(9);
    assert!(receipt_shape(Some(&rebound)));
}

/// The public projection enumerates its keys and does not include
/// `request_sha256`. That digest is how a retry is recognised; handing it out
/// would let a caller claim an operation it never made.
#[test]
fn the_public_projection_withholds_the_request_digest() {
    let projected = public_receipt(Some(&receipt())).expect("projection");
    let keys: Vec<&str> = projected
        .as_object()
        .expect("object")
        .keys()
        .map(String::as_str)
        .collect();
    assert_eq!(
        keys,
        vec![
            "binding_revision",
            "committed_at",
            "operation",
            "operation_id",
            "outcome",
            "registry_generation",
            "registry_sha256",
            "schema_version",
            "workspace_id",
        ]
    );
    assert!(projected.get("request_sha256").is_none());
    assert_eq!(projected["operation_id"], json!(OPERATION));
    // A key the receipt does not have is projected as null, never invented.
    let projected = public_receipt(Some(&json!({}))).expect("projection");
    assert_eq!(projected["workspace_id"], Value::Null);
    assert!(public_receipt(None).is_none());
    assert!(public_receipt(Some(&json!([]))).is_none());
    // A field the caller smuggled in does not reach the projection.
    let mut smuggled = receipt();
    smuggled["secret"] = json!("x");
    let projected = public_receipt(Some(&smuggled)).expect("projection");
    assert!(projected.get("secret").is_none());
}

/// One operation id names one outcome. A store holding two of them cannot say
/// which retry is the one that happened, so it is not a store.
#[test]
fn an_operation_id_appears_once() {
    assert!(receipt_store_shape(Some(&store(vec![receipt()]))));
    assert!(receipt_store_shape(Some(&store(vec![]))));
    let mut other = receipt();
    other["operation_id"] = json!(WORKSPACE);
    assert!(receipt_store_shape(Some(&store(vec![
        receipt(),
        other.clone()
    ]))));
    // The same id twice, even with everything else differing.
    let mut twin = receipt();
    twin["outcome"] = json!("purge_pending");
    twin["operation"] = json!("delete_owned");
    assert!(!receipt_store_shape(Some(&store(vec![receipt(), twin]))));
    // Mixed forms are fine; an unreadable receipt is not.
    assert!(receipt_store_shape(Some(&store(vec![
        legacy_receipt(),
        other
    ]))));
    assert!(!receipt_store_shape(Some(&store(vec![json!({})]))));
}

#[test]
fn the_store_envelope_is_exact_and_bounded() {
    assert!(!receipt_store_shape(Some(&json!({ "receipts": [] }))));
    assert!(!receipt_store_shape(Some(
        &json!({ "schema_version": 1, "receipts": [], "extra": 1 })
    )));
    assert!(!receipt_store_shape(Some(
        &json!({ "schema_version": 2, "receipts": [] })
    )));
    assert!(!receipt_store_shape(Some(
        &json!({ "schema_version": 1, "receipts": {} })
    )));
    assert!(!receipt_store_shape(None));
    // The capacity is inclusive.
    let one = |index: usize| {
        let mut value = receipt();
        value["operation_id"] = json!(format!("{:08x}-1111-4111-8111-1111abcd1111", index));
        value
    };
    let full: Vec<Value> = (0..MAX_RECEIPTS).map(one).collect();
    assert!(receipt_store_shape(Some(&store(full.clone()))));
    let mut over = full;
    over.push(one(MAX_RECEIPTS));
    assert!(!receipt_store_shape(Some(&store(over))));
    assert_eq!(MAX_RECEIPTS, 2048);
}

/// A receipt outlives its retry window after thirty days. One whose timestamp
/// the host could not read is expired too: it can never be matched against a
/// retry, so keeping it is pure cost.
#[test]
fn a_receipt_expires_after_its_retry_window() {
    assert_eq!(RECEIPT_TTL_SECONDS, 2_592_000.0);
    assert!(!receipt_expired(Some(0.0)));
    assert!(!receipt_expired(Some(RECEIPT_TTL_SECONDS)));
    assert!(receipt_expired(Some(RECEIPT_TTL_SECONDS + 1.0)));
    assert!(receipt_expired(None));
    // A clock that ran backwards has not expired anything.
    assert!(!receipt_expired(Some(-60.0)));
}

/// The store is bounded, and a full one refuses the operation rather than
/// dropping a receipt some retry may still need.
#[test]
fn a_full_store_has_no_room() {
    assert!(has_room(Some(0)));
    assert!(has_room(Some(MAX_RECEIPTS as u64 - 1)));
    assert!(!has_room(Some(MAX_RECEIPTS as u64)));
    assert!(!has_room(Some(MAX_RECEIPTS as u64 + 1)));
    // A count the host could not state is not room.
    assert!(!has_room(None));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "receipt_shape", "receipt": receipt() })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "legacy_receipt_shape", "receipt": receipt() })),
        json!({ "ok": true, "valid": false })
    );
    assert_eq!(
        run(json!({ "op": "readable_receipt", "receipt": legacy_receipt() })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "store_shape", "envelope": store(vec![receipt()]) })),
        json!({ "ok": true, "valid": true })
    );
    let reply = run(json!({ "op": "public_receipt", "receipt": receipt() }));
    assert_eq!(reply["receipt"]["operation_id"], json!(OPERATION));
    assert!(reply["receipt"].get("request_sha256").is_none());
    assert_eq!(
        run(json!({ "op": "has_room", "count": 0 })),
        json!({ "ok": true, "has_room": true })
    );
    assert_eq!(
        run(json!({ "op": "has_room" })),
        json!({ "ok": true, "has_room": false })
    );
    assert_eq!(
        run(json!({ "op": "expired", "age_seconds": 1.0 })),
        json!({ "ok": true, "expired": false })
    );
    // No age is an unreadable timestamp, which is expired.
    assert_eq!(
        run(json!({ "op": "expired" })),
        json!({ "ok": true, "expired": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "receipt": receipt() }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
