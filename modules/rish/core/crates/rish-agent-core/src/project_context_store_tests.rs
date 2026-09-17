use super::*;

const CONVERSATION: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const OLD: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const NEW: &str = "c3d4e5f6-3333-4333-8333-3333abcd3333";

fn refs(pairs: &[(&str, &str)]) -> Map<String, Value> {
    pairs
        .iter()
        .map(|(key, value)| ((*key).to_string(), json!(value)))
        .collect()
}

fn ids(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_string()).collect()
}

fn active() -> String {
    format!("active:{CONVERSATION}")
}

fn transaction() -> String {
    format!("txn:prepare:{CONVERSATION}")
}

#[test]
fn a_snapshot_id_is_a_lowercase_uuid_that_is_not_the_sentinel() {
    assert!(canonical_snapshot_id(CONVERSATION));
    // The sentinel is a well-formed UUID and is still refused: rolling back to
    // it would point a conversation at a snapshot that never existed.
    assert_eq!(NO_PRIOR_SNAPSHOT_ID, "00000000-0000-0000-0000-000000000000");
    assert!(!canonical_snapshot_id(NO_PRIOR_SNAPSHOT_ID));
    for bad in [
        "",
        "A1B2C3D4-1111-4111-8111-1111ABCD1111",
        "a1b2c3d4-1111-4111-8111-1111abcd111",
        "a1b2c3d41111411181111111abcd1111",
        "g1b2c3d4-1111-4111-8111-1111abcd1111",
    ] {
        assert!(!canonical_snapshot_id(bad), "{bad:?}");
    }
}

/// A key comes from a closed alphabet so it can never be a path component that
/// escapes the store.
#[test]
fn a_reference_key_cannot_escape_the_store() {
    assert!(safe_reference_key(&active()));
    assert!(safe_reference_key("retry:abc-1_2.3"));
    for bad in ["", "a/b", "a\\b", "../x", "a b", "a\u{0}b", "ké"] {
        assert!(!safe_reference_key(bad), "{bad:?}");
    }
    assert!(safe_reference_key(&"a".repeat(MAX_REFERENCE_KEY_LEN)));
    assert!(!safe_reference_key(&"a".repeat(MAX_REFERENCE_KEY_LEN + 1)));
}

/// Only `retry:` may be set by a caller. A caller that could write `active:`
/// or `txn:prepare:` could point a conversation at a snapshot of its choosing.
#[test]
fn only_a_retry_key_may_be_set_by_a_caller() {
    assert!(settable_reference_key("retry:abc"));
    assert!(!settable_reference_key(&active()));
    assert!(!settable_reference_key(&transaction()));
    assert!(!settable_reference_key("retry:a/b"));
    assert!(!settable_reference_key(""));
    // Both of the first two survive a sweep, though; only one is settable.
    assert!(retained_reference_key(&active()));
    assert!(retained_reference_key("retry:abc"));
    assert!(!retained_reference_key(&transaction()));
    assert!(!retained_reference_key("something:else"));
}

#[test]
fn a_transaction_key_pairs_with_its_active_key() {
    assert_eq!(prepare_transaction_key(&active()), Some(transaction()));
    assert_eq!(active_key_for_transaction(&transaction()), Some(active()));
    // The conversation has to be a real id, not just any text.
    assert_eq!(prepare_transaction_key("active:not-a-uuid"), None);
    assert_eq!(prepare_transaction_key("retry:abc"), None);
    assert_eq!(active_key_for_transaction(&active()), None);
}

/// The plain case: the process died after `active:` was swapped to the new
/// snapshot. Recovery puts the old one back and hands the new one over to be
/// collected.
#[test]
fn an_interrupted_swap_rolls_back_to_the_recorded_snapshot() {
    let stored = refs(&[(&active(), NEW), (&transaction(), OLD)]);
    let recovery = recover_references(&stored, &ids(&[OLD, NEW]));
    assert_eq!(recovery.references.get(&active()), Some(&json!(OLD)));
    assert!(!recovery.references.contains_key(&transaction()));
    assert_eq!(recovery.transaction_new_ids, ids(&[NEW]));
}

/// **The subtle case.** When `active:` still holds the id the transaction
/// recorded, the swap never happened — there is nothing to undo, and the
/// snapshot is *not* collected. Undoing here would throw away the snapshot the
/// conversation is actually using.
#[test]
fn a_crash_before_the_swap_leaves_everything_alone() {
    let stored = refs(&[(&active(), OLD), (&transaction(), OLD)]);
    let recovery = recover_references(&stored, &ids(&[OLD]));
    assert_eq!(recovery.references.get(&active()), Some(&json!(OLD)));
    assert!(!recovery.references.contains_key(&transaction()));
    assert!(recovery.transaction_new_ids.is_empty());
}

/// A transaction that recorded "no prior snapshot" has nothing to roll back
/// to, so the conversation ends with none — and the equality with the sentinel
/// is *not* read as a crash-before-swap.
#[test]
fn a_transaction_with_no_prior_snapshot_leaves_the_conversation_bare() {
    let stored = refs(&[(&active(), NEW), (&transaction(), NO_PRIOR_SNAPSHOT_ID)]);
    let recovery = recover_references(&stored, &ids(&[NEW]));
    assert!(!recovery.references.contains_key(&active()));
    assert_eq!(recovery.transaction_new_ids, ids(&[NEW]));

    // Even when both sides hold the sentinel, which is not a snapshot anyone
    // can be using.
    let sentinel_both = refs(&[
        (&active(), NO_PRIOR_SNAPSHOT_ID),
        (&transaction(), NO_PRIOR_SNAPSHOT_ID),
    ]);
    let recovery = recover_references(&sentinel_both, &ids(&[NEW]));
    assert!(!recovery.references.contains_key(&active()));
    assert!(recovery.transaction_new_ids.is_empty());
}

/// Rolling back to a snapshot that is no longer on disk is not rolling back.
#[test]
fn a_rollback_target_that_is_gone_leaves_the_conversation_bare() {
    let stored = refs(&[(&active(), NEW), (&transaction(), OLD)]);
    let recovery = recover_references(&stored, &ids(&[NEW]));
    assert!(!recovery.references.contains_key(&active()));
    assert_eq!(recovery.transaction_new_ids, ids(&[NEW]));
}

/// After the transactions are resolved, anything that is not a live `active:`
/// or `retry:` pointing at a real snapshot is dropped.
#[test]
fn the_sweep_drops_keys_that_name_nothing() {
    let stored = refs(&[
        ("active:x", OLD),
        ("retry:one", OLD),
        ("retry:two", NEW),
        ("stray:key", OLD),
    ]);
    let recovery = recover_references(&stored, &ids(&[OLD]));
    assert!(recovery.references.contains_key("active:x"));
    assert!(recovery.references.contains_key("retry:one"));
    // Points at a snapshot that is gone.
    assert!(!recovery.references.contains_key("retry:two"));
    // Not a namespace the store keeps.
    assert!(!recovery.references.contains_key("stray:key"));
    assert!(recovery.transaction_new_ids.is_empty());
}

/// A transaction key is removed whatever else it implies, because it is
/// bookkeeping that was never meant to outlive the swap.
#[test]
fn a_transaction_key_never_survives() {
    for stored in [
        refs(&[(&transaction(), OLD)]),
        refs(&[(&transaction(), NO_PRIOR_SNAPSHOT_ID)]),
        refs(&[(&active(), "not-an-id"), (&transaction(), OLD)]),
    ] {
        let recovery = recover_references(&stored, &ids(&[OLD, NEW]));
        assert!(
            !recovery.references.contains_key(&transaction()),
            "{stored:?}"
        );
    }
}

/// Three checks inside the recovery loop are redundant with the sweep that
/// follows: refusing to roll back to the sentinel, refusing to roll back to an
/// id that is gone, and removing the transaction key. Each mutation leaves
/// every test green, because the sweep drops the same key a moment later.
///
/// This pins *why*, so that anyone loosening the sweep knows those three stop
/// being redundant the moment they do.
#[test]
fn the_sweep_is_what_actually_drops_them() {
    // The sentinel is not a snapshot id, so it can never be in `valid_ids` —
    // which is exactly why rolling back to it and being swept are the same
    // outcome.
    assert!(!canonical_snapshot_id(NO_PRIOR_SNAPSHOT_ID));
    // A transaction key is not retained by the sweep either.
    assert!(!retained_reference_key(&transaction()));
    // And a reference to an id that is gone does not survive it.
    let stored = refs(&[(&active(), OLD)]);
    let recovery = recover_references(&stored, &ids(&[NEW]));
    assert!(recovery.references.is_empty());
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "canonical_snapshot_id", "value": CONVERSATION })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "settable_reference_key", "value": active() })),
        json!({ "ok": true, "valid": false })
    );
    assert_eq!(
        run(json!({ "op": "prepare_transaction_key", "active_key": active() })),
        json!({ "ok": true, "key": transaction() })
    );
    assert_eq!(
        run(json!({ "op": "hex_digest", "value": "a".repeat(64) })),
        json!({ "ok": true, "valid": true })
    );
    let reply = run(json!({
        "op": "recover_references",
        "references": refs(&[(&active(), NEW), (&transaction(), OLD)]),
        "valid_ids": [OLD, NEW],
    }));
    assert_eq!(reply["references"][active()], json!(OLD));
    assert_eq!(reply["transaction_new_ids"], json!([NEW]));
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "op": "canonical_snapshot_id" }).to_string(),
        json!({ "op": "recover_references", "references": {} }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
