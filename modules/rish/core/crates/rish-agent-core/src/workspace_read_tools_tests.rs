use super::*;

/// The list is closed. These run against a folder a person granted, so the
/// surface is six named readers and nothing else.
#[test]
fn only_the_six_named_readers_are_tools() {
    assert_eq!(TOOLS, ["cat", "grep", "head", "tail", "wc", "sha256sum"]);
    for name in TOOLS {
        assert!(tool_name_valid(Some(&json!(name))), "{name}");
    }
    for bad in [
        "",
        "sh",
        "rm",
        "CAT",
        "cat ",
        " cat",
        "cat file",
        "catx",
        "sha256",
        "sha256sum ",
        "echo",
    ] {
        assert!(!tool_name_valid(Some(&json!(bad))), "{bad:?}");
    }
    assert!(!tool_name_valid(Some(&json!(1))));
    assert!(!tool_name_valid(None));
}

/// An option key the rule does not recognise is refused, not ignored.
/// Ignoring it would run a different command than the caller asked for and
/// report success.
#[test]
fn an_unknown_option_is_refused_rather_than_ignored() {
    assert!(tool_options_valid(Some(&json!({}))));
    assert!(tool_options_valid(Some(&json!({ "lines": 10 }))));
    for bad in [
        json!({ "limit": 10 }),
        json!({ "lines": 10, "extra": 1 }),
        json!({ "Lines": 10 }),
        json!({ "": 1 }),
    ] {
        assert!(!tool_options_valid(Some(&bad)), "{bad}");
    }
    assert!(!tool_options_valid(Some(&json!([]))));
    assert!(!tool_options_valid(Some(&Value::Null)));
    assert!(!tool_options_valid(None));
}

#[test]
fn each_option_is_the_shape_its_key_takes() {
    // lines: a positive count within the bound.
    assert!(tool_options_valid(Some(&json!({ "lines": 1 }))));
    assert!(tool_options_valid(Some(&json!({ "lines": MAX_LINES }))));
    for bad in [
        json!(0),
        json!(-1),
        json!(MAX_LINES + 1),
        json!("10"),
        json!(true),
        json!(1.5),
    ] {
        assert!(
            !tool_options_valid(Some(&json!({ "lines": bad }))),
            "lines={bad}"
        );
    }
    // metric: one of three.
    for metric in METRICS {
        assert!(
            tool_options_valid(Some(&json!({ "metric": metric }))),
            "{metric}"
        );
    }
    for bad in [json!("chars"), json!(""), json!("Lines"), json!(1)] {
        assert!(
            !tool_options_valid(Some(&json!({ "metric": bad }))),
            "metric={bad}"
        );
    }
    // pattern: non-empty and bounded.
    assert!(tool_options_valid(Some(&json!({ "pattern": "x" }))));
    assert!(tool_options_valid(Some(
        &json!({ "pattern": "x".repeat(MAX_PATTERN_BYTES) })
    )));
    for bad in [
        json!(""),
        json!("x".repeat(MAX_PATTERN_BYTES + 1)),
        json!(1),
        json!(Value::Null),
    ] {
        assert!(
            !tool_options_valid(Some(&json!({ "pattern": bad }))),
            "pattern"
        );
    }
    // case_insensitive: a boolean, and 1 is not a boolean.
    assert!(tool_options_valid(Some(
        &json!({ "case_insensitive": true })
    )));
    assert!(tool_options_valid(Some(
        &json!({ "case_insensitive": false })
    )));
    for bad in [json!(1), json!(0), json!("true"), json!(Value::Null)] {
        assert!(
            !tool_options_valid(Some(&json!({ "case_insensitive": bad }))),
            "case_insensitive={bad}"
        );
    }
    // All four together.
    assert!(tool_options_valid(Some(&json!({
        "lines": 5, "metric": "words", "pattern": "todo", "case_insensitive": true
    }))));
}

#[test]
fn output_is_bounded() {
    assert_eq!(MAX_OUTPUT_BYTES, 262_144);
    assert!(output_length_valid(Some(0)));
    assert!(output_length_valid(Some(MAX_OUTPUT_BYTES as u64)));
    assert!(!output_length_valid(Some(MAX_OUTPUT_BYTES as u64 + 1)));
    assert!(!output_length_valid(None));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "tool_name_valid", "value": "grep" })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "tool_options_valid", "options": { "lines": 5 } })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "output_length_valid", "length": 10 })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(run(json!({ "op": "tools" }))["tools"], json!(TOOLS));
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({}).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
