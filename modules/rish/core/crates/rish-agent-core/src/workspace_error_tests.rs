use super::*;

/// Every code the stored enum defines has a name and a message, the numbers
/// run 1..=19 with no gaps, and nothing repeats. A gap would mean a failure
/// the host can raise and no caller can read.
#[test]
fn the_table_is_dense_and_unique() {
    assert_eq!(FAILURES.len(), 19);
    for (index, (number, name, message)) in FAILURES.iter().enumerate() {
        assert_eq!(*number, index as u64 + 1, "{name}");
        assert!(name.starts_with("E_WORKSPACE_"), "{name}");
        assert!(message.ends_with('.'), "{message}");
        assert!(!message.is_empty(), "{name}");
    }
    let mut names: Vec<&str> = FAILURES.iter().map(|(_, name, _)| *name).collect();
    names.sort_unstable();
    let count = names.len();
    names.dedup();
    assert_eq!(names.len(), count, "a code name appears twice");
    let mut messages: Vec<&str> = FAILURES.iter().map(|(_, _, m)| *m).collect();
    messages.sort_unstable();
    let count = messages.len();
    messages.dedup();
    assert_eq!(messages.len(), count, "a message appears twice");
}

/// The numbers are on the wire, so the ones a caller already branches on are
/// pinned here rather than left to the order of the list.
#[test]
fn the_numbers_are_the_stored_ones() {
    for (code, name) in [
        (1u64, "E_WORKSPACE_INVALID"),
        (3, "E_WORKSPACE_BUSY"),
        (10, "E_WORKSPACE_UNAVAILABLE"),
        (14, "E_WORKSPACE_ROOT_CHANGED"),
        (17, "E_WORKSPACE_CONFLICT"),
        // Persistence is 18 and IO is 19, in that order. The switch in the
        // original lists IO first, which changes nothing and is worth saying
        // so nobody "fixes" the order here to match it.
        (18, "E_WORKSPACE_PERSISTENCE"),
        (19, "E_WORKSPACE_IO"),
    ] {
        assert_eq!(public_code(Some(code)), Some(name), "{code}");
    }
}

/// A number that is not a failure this engine defines has no code and no
/// message. Inventing one would let a caller branch on a failure that does not
/// exist.
#[test]
fn an_undefined_code_projects_to_nothing() {
    for code in [0u64, 20, 21, 100, u64::MAX] {
        assert!(public_code(Some(code)).is_none(), "{code}");
        assert!(public_message(Some(code)).is_none(), "{code}");
        assert!(projection(Some(code)).is_none(), "{code}");
    }
    assert!(public_code(None).is_none());
    assert!(projection(None).is_none());
}

/// The two halves always agree: a code that has a name has a message.
#[test]
fn a_code_and_its_message_come_together() {
    for (number, name, message) in FAILURES {
        assert_eq!(public_code(Some(*number)), Some(*name));
        assert_eq!(public_message(Some(*number)), Some(*message));
        assert_eq!(
            projection(Some(*number)),
            Some(json!({ "code": name, "message": message }))
        );
    }
}

/// Codes a caller's behaviour depends on must stay distinguishable: "try
/// again" and "this store cannot be read" are different answers.
#[test]
fn retryable_and_terminal_failures_are_distinct() {
    assert_ne!(public_code(Some(17)), public_code(Some(18)));
    assert_eq!(
        public_message(Some(17)),
        Some("Workspace storage changed concurrently.")
    );
    assert_eq!(
        public_message(Some(18)),
        Some("Workspace storage is invalid.")
    );
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "projection", "code": 17 })),
        json!({
            "ok": true,
            "projection": {
                "code": "E_WORKSPACE_CONFLICT",
                "message": "Workspace storage changed concurrently."
            }
        })
    );
    // An undefined code is answered, not refused: the envelope was one the
    // rule acts on, and its answer is "there is no such failure".
    assert_eq!(
        run(json!({ "op": "projection", "code": 99 })),
        json!({ "ok": true, "projection": Value::Null })
    );
    assert_eq!(
        run(json!({ "op": "projection" })),
        json!({ "ok": true, "projection": Value::Null })
    );
    let codes = run(json!({ "op": "codes" }));
    assert_eq!(codes["codes"].as_array().expect("array").len(), 19);
    assert_eq!(codes["codes"][0]["name"], json!("E_WORKSPACE_INVALID"));
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({}).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
