use super::*;

#[test]
fn a_reported_path_stays_inside_the_project() {
    for good in ["a", "a/b", "a/b/c.txt", "src/main.rs", "中文/文件.txt"] {
        assert!(safe_relative_path(Some(&json!(good))), "{good:?}");
    }
    for bad in [
        "",
        "/a",
        "a\\b",
        "a\u{0}b",
        "a//b",
        "./a",
        "a/./b",
        "../a",
        "a/../b",
        "a/",
        "/",
        "..",
        ".",
        "a\u{1}b",
        "a\u{7f}b",
        "a\u{200e}b",
    ] {
        assert!(!safe_relative_path(Some(&json!(bad))), "{bad:?}");
    }
    assert!(safe_relative_path(Some(&json!("x".repeat(MAX_PATH_BYTES)))));
    assert!(!safe_relative_path(Some(&json!(
        "x".repeat(MAX_PATH_BYTES + 1)
    ))));
    assert!(!safe_relative_path(Some(&json!(1))));
    assert!(!safe_relative_path(None));
}

/// This rule and `execution_ledger::relative_path_argument` are deliberately
/// different, and each accepts something the other refuses. Merging them would
/// change what one of the two surfaces allows, so the difference is pinned
/// rather than left to be discovered.
#[test]
fn it_is_not_the_agents_tool_argument_rule() {
    // Longer than a tool argument may be, but fine as a reported path.
    let long = "x".repeat(1024);
    assert!(safe_relative_path(Some(&json!(long))));
    assert!(crate::execution_ledger::relative_path_argument(Some(&json!(long)), false).is_none());

    // A `.` component is refused here and accepted there.
    assert!(!safe_relative_path(Some(&json!("a/./b"))));
    assert!(
        crate::execution_ledger::relative_path_argument(Some(&json!("a/./b")), false).is_some()
    );

    // A decomposed name is refused there and accepted here: this path
    // describes a file that already exists, whatever the disk spelled it.
    let decomposed = "e\u{301}.txt";
    assert!(safe_relative_path(Some(&json!(decomposed))));
    assert!(
        crate::execution_ledger::relative_path_argument(Some(&json!(decomposed)), false).is_none()
    );
}

#[test]
fn a_bounded_string_is_bounded() {
    assert!(bounded_string(Some(&json!("hi")), 4, false));
    assert!(bounded_string(Some(&json!("")), 4, true));
    assert!(!bounded_string(Some(&json!("")), 4, false));
    assert!(!bounded_string(Some(&json!("hello")), 4, false));
    assert!(!bounded_string(Some(&json!(1)), 4, false));
    assert!(!bounded_string(None, 4, false));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "safe_relative_path", "value": "src/main.rs" })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "bounded_string", "value": "hi", "maximum_bytes": 4 })),
        json!({ "ok": true, "valid": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "op": "bounded_string", "value": "hi" }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
