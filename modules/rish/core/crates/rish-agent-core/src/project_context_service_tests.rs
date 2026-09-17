use super::*;

const WORKSPACE: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const OTHER_WORKSPACE: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const PROJECT: &str = "c3d4e5f6-3333-4333-8333-3333abcd3333";
const CONVERSATION: &str = "d4e5f6a7-4444-4444-8444-4444abcd4444";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

fn root(workspace: &str) -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": workspace,
        "binding_revision": 3,
        "project_id": PROJECT,
    })
}

fn id_for(root: &Value, fingerprint: &str, conversation: &str) -> Option<String> {
    reference_id(
        Some(root),
        Some(&json!(fingerprint)),
        Some(&json!(conversation)),
    )
}

/// **The property the derivation exists for.** `ProjectContextStore` names a
/// prepare transaction by the suffix of an `active:<uuid>` key. If that uuid
/// were the conversation's, two workspaces using the same conversation id
/// could evict or authorise one another's snapshot. Every part of the
/// authority tuple has to change the id.
#[test]
fn every_part_of_the_authority_changes_the_id() {
    let base = id_for(&root(WORKSPACE), &digest('a'), CONVERSATION).expect("id");
    let same_conversation_other_workspace =
        id_for(&root(OTHER_WORKSPACE), &digest('a'), CONVERSATION).expect("id");
    assert_ne!(base, same_conversation_other_workspace);

    let mut rebound = root(WORKSPACE);
    rebound["binding_revision"] = json!(4);
    assert_ne!(
        base,
        id_for(&rebound, &digest('a'), CONVERSATION).expect("id")
    );

    let mut other_project = root(WORKSPACE);
    other_project["project_id"] = json!(OTHER_WORKSPACE);
    assert_ne!(
        base,
        id_for(&other_project, &digest('a'), CONVERSATION).expect("id")
    );

    assert_ne!(
        base,
        id_for(&root(WORKSPACE), &digest('b'), CONVERSATION).expect("id")
    );
    assert_ne!(
        base,
        id_for(&root(WORKSPACE), &digest('a'), OTHER_WORKSPACE).expect("id")
    );
}

/// The id is stable: nothing in it depends on a clock, a nonce or key order.
#[test]
fn the_id_is_stable_and_order_independent() {
    let base = id_for(&root(WORKSPACE), &digest('a'), CONVERSATION).expect("id");
    assert_eq!(
        Some(base.clone()),
        id_for(&root(WORKSPACE), &digest('a'), CONVERSATION)
    );
    let shuffled = json!({
        "project_id": PROJECT,
        "binding_revision": 3,
        "workspace_id": WORKSPACE,
        "schema_version": 1,
    });
    assert_eq!(
        Some(base),
        id_for(&shuffled, &digest('a'), CONVERSATION),
        "the canonical root is what is digested, not the caller's spelling"
    );
}

/// The store checks that a reference id is a canonical snapshot id, so the
/// derivation has to produce one — version and variant bits included.
#[test]
fn the_id_is_a_well_formed_snapshot_id() {
    let id = id_for(&root(WORKSPACE), &digest('a'), CONVERSATION).expect("id");
    assert_eq!(id.len(), 36);
    assert!(crate::project_context_store::canonical_snapshot_id(&id));
    assert_eq!(id.as_bytes()[14], b'4', "version nibble");
    assert!(
        matches!(id.as_bytes()[19], b'8' | b'9' | b'a' | b'b'),
        "variant"
    );
    // Across many inputs, not just this one.
    for index in 0..64u32 {
        let conversation = format!("d4e5f6a7-4444-4444-8444-{index:012x}");
        let id = id_for(&root(WORKSPACE), &digest('a'), &conversation)
            .unwrap_or_else(|| panic!("{conversation}"));
        assert!(crate::project_context_store::canonical_snapshot_id(&id));
        assert_eq!(id.as_bytes()[14], b'4');
        assert!(matches!(id.as_bytes()[19], b'8' | b'9' | b'a' | b'b'));
    }
}

/// Every input has to be the thing it claims to be. An id derived from a
/// half-valid tuple would name a snapshot no authority backs.
#[test]
fn a_malformed_tuple_derives_nothing() {
    assert!(id_for(&json!({}), &digest('a'), CONVERSATION).is_none());
    assert!(id_for(&root(WORKSPACE), "abc", CONVERSATION).is_none());
    assert!(id_for(&root(WORKSPACE), &digest('A'), CONVERSATION).is_none());
    assert!(id_for(&root(WORKSPACE), &digest('a'), "not-a-uuid").is_none());
    // The nil sentinel is not a conversation.
    assert!(id_for(
        &root(WORKSPACE),
        &digest('a'),
        crate::project_context_store::NO_PRIOR_SNAPSHOT_ID
    )
    .is_none());
    assert!(reference_id(None, Some(&json!(digest('a'))), Some(&json!(CONVERSATION))).is_none());
    assert!(reference_id(Some(&root(WORKSPACE)), None, Some(&json!(CONVERSATION))).is_none());
    assert!(reference_id(Some(&root(WORKSPACE)), Some(&json!(digest('a'))), None).is_none());
}

/// Two roots are the same root when their canonical forms are equal.
/// Comparing the given dictionaries would let key order make one root look
/// like two.
#[test]
fn roots_are_compared_canonically() {
    let shuffled = json!({
        "project_id": PROJECT,
        "binding_revision": 3,
        "workspace_id": WORKSPACE,
        "schema_version": 1,
    });
    assert!(roots_equal(Some(&root(WORKSPACE)), Some(&shuffled)));
    assert!(!roots_equal(
        Some(&root(WORKSPACE)),
        Some(&root(OTHER_WORKSPACE))
    ));
    // A root the rule refuses equals nothing, including itself.
    assert!(!roots_equal(Some(&json!({})), Some(&json!({}))));
    assert!(!roots_equal(None, Some(&root(WORKSPACE))));
}

#[test]
fn a_bounded_string_is_bounded_and_free_of_control_characters() {
    assert!(bounded_string(Some(&json!("hello")), 16, false));
    assert!(bounded_string(Some(&json!("")), 16, true));
    assert!(!bounded_string(Some(&json!("")), 16, false));
    assert!(bounded_string(Some(&json!("x".repeat(16))), 16, false));
    assert!(!bounded_string(Some(&json!("x".repeat(17))), 16, false));
    // Bytes, not characters.
    assert!(!bounded_string(Some(&json!("中中中中中中")), 16, false));
    for bad in ["a\u{1}b", "a\nb", "a\u{7f}b", "a\u{200e}b"] {
        assert!(!bounded_string(Some(&json!(bad)), 16, false), "{bad:?}");
    }
    assert!(!bounded_string(Some(&json!(1)), 16, false));
    assert!(!bounded_string(None, 16, false));
}

#[test]
fn a_canonical_digest_is_lowercase_hex_of_the_right_width() {
    assert!(canonical_digest(Some(&json!(digest('a')))));
    for bad in [
        json!(digest('A')),
        json!("abc"),
        json!(1),
        json!(Value::Null),
    ] {
        assert!(!canonical_digest(Some(&bad)), "{bad}");
    }
    assert!(!canonical_digest(None));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    let reply = run(json!({
        "op": "reference_id", "root": root(WORKSPACE),
        "root_fingerprint_sha256": digest('a'), "conversation_id": CONVERSATION,
    }));
    assert_eq!(
        reply["reference_id"],
        json!(id_for(&root(WORKSPACE), &digest('a'), CONVERSATION).expect("id"))
    );
    assert_eq!(
        run(json!({ "op": "roots_equal", "left": root(WORKSPACE), "right": root(WORKSPACE) })),
        json!({ "ok": true, "equal": true })
    );
    assert_eq!(
        run(json!({ "op": "canonical_digest", "value": digest('a') })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "bounded_string", "value": "hi", "max_bytes": 4 })),
        json!({ "ok": true, "valid": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        // A bound is not optional: guessing one would accept a string the
        // caller never said was acceptable.
        json!({ "op": "bounded_string", "value": "hi" }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
    // A tuple that derives nothing is an *answer*, not a refusal: the envelope
    // was one the rule acts on, and the answer is "there is no id for this".
    assert_eq!(
        run(json!({ "op": "reference_id" })),
        json!({ "ok": true, "reference_id": Value::Null })
    );
}
