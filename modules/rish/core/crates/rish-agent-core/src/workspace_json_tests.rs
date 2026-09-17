use super::*;

fn ok(text: &str) -> bool {
    bounded_exact_structure(text.as_bytes())
}

#[test]
fn it_accepts_one_complete_value() {
    for good in [
        r#"{}"#,
        r#"[]"#,
        r#"{"schema_version":1,"records":[]}"#,
        r#"  {"a": [1, 2, {"b": null}]}  "#,
        r#"null"#,
        r#"true"#,
        r#"-1.5"#,
        r#""text""#,
        // The top level may be any value here, unlike the other two scanners.
        r#"[{"a":1},{"a":2}]"#,
    ] {
        assert!(ok(good), "{good}");
    }
}

/// Trailing bytes mean the file is two things, and the second was never asked
/// about.
#[test]
fn nothing_may_follow_the_value() {
    for bad in [
        r#"{} {}"#,
        r#"{}x"#,
        r#"{}]"#,
        r#"1 2"#,
        r#""a" "b""#,
        "",
        "   ",
    ] {
        assert!(!ok(bad), "{bad:?}");
    }
    assert!(!bounded_exact_structure(&[]));
}

/// Two spellings of one key are one key, and the second is not a second field.
/// A parser that took the last would read a different object than one that
/// took the first, so neither is allowed to happen.
#[test]
fn an_object_refuses_a_duplicate_key_however_it_is_spelled() {
    assert!(!ok(r#"{"a":1,"a":2}"#));
    // The escaped spellings are written as ordinary Rust strings so the
    // backslash survives; these are the cases that make the rule about
    // decoded keys rather than about bytes.
    assert!(!ok("{\"a\":1,\"\\u0061\":2}"));
    assert!(!ok("{\"\\u0061\":1,\"a\":2}"));
    // Different keys are fine, including ones that only look alike.
    assert!(ok(r#"{"a":1,"A":2}"#));
    assert!(ok(r#"{"a":1,"ab":2}"#));
    // Nested objects have their own key spaces.
    assert!(ok(r#"{"a":{"a":1}}"#));
}

/// Negative zero is refused: Foundation folds it into +0, so the bytes and the
/// value they decode to would disagree, and a digest taken over one would not
/// describe the other.
#[test]
fn negative_zero_is_refused_in_every_spelling() {
    for bad in ["-0", "-0.0", "-0e5", "-0.000", "-0E-7"] {
        assert!(!ok(bad), "{bad}");
        assert!(!ok(&format!(r#"{{"a":{bad}}}"#)), "{bad}");
    }
    for good in ["0", "-1", "-0.5", "-1e-7", "0.0"] {
        assert!(ok(good), "{good}");
    }
}

/// The scanner's own `< 0x20` check mirrors the ObjC line for line, but it is
/// **not load-bearing here**: removing it leaves every test green, because
/// serde refuses the same bytes when the token is decoded. Said out loud so
/// the guard is understood as redundant-by-construction rather than as
/// something these assertions prove.
#[test]
fn a_string_refuses_a_raw_control_byte() {
    assert!(!bounded_exact_structure(b"\"a\x01b\""));
    assert!(!bounded_exact_structure(b"\"a\nb\""));
    assert!(!bounded_exact_structure(b"\"a\tb\""));
    // Escaped is fine; it is the raw byte that is not.
    // Written as an ordinary Rust string so the backslash survives: the
    // point is a JSON escape, not the byte it denotes.
    assert!(ok("\"a\\u0001b\""));
    assert!(ok(r#""a\nb""#));
    // The redundancy, stated: serde alone would refuse them too.
    assert!(serde_json::from_str::<String>("\"a\u{1}b\"").is_err());
}

/// **0x7f is accepted**, and that is the one place this scanner is looser than
/// the other two in the core. It is deliberate: tightening it would refuse a
/// stored registry the current engine accepts. See the module note.
#[test]
fn a_raw_del_byte_is_accepted_here_unlike_the_other_scanners() {
    assert!(bounded_exact_structure(b"\"a\x7fb\""));
    assert!(bounded_exact_structure(b"{\"a\":\"\x7f\"}"));
    // The session scanner refuses the same bytes, which is what makes this a
    // difference rather than an accident.
    assert!(crate::session_schema::scanner::parse_object(b"{\"a\":\"\x7f\"}", 1000).is_none());
    assert!(crate::session_schema::scanner::parse_object(b"{\"a\":\"b\"}", 1000).is_some());
}

/// Depth and node bounds, so a corrupt file costs a refusal rather than an
/// unbounded walk.
#[test]
fn it_is_bounded_in_depth_and_in_nodes() {
    let nest = |depth: usize| format!("{}{}", "[".repeat(depth), "]".repeat(depth));
    // The value itself is depth 1, so 64 brackets is the deepest that fits.
    assert!(ok(&nest(MAX_DEPTH)));
    assert!(!ok(&nest(MAX_DEPTH + 1)));

    // One array node plus its elements.
    let wide = |count: usize| {
        format!(
            "[{}]",
            std::iter::repeat_n("1", count)
                .collect::<Vec<_>>()
                .join(",")
        )
    };
    assert!(ok(&wide(MAX_NODES - 1)));
    assert!(!ok(&wide(MAX_NODES)));
    assert_eq!(MAX_NODES, 100_000);
    assert_eq!(MAX_DEPTH, 64);
}

#[test]
fn it_refuses_what_is_not_json_at_all() {
    for bad in [
        "{",
        "}",
        "[1,",
        r#"{"a"}"#,
        r#"{"a":}"#,
        r#"{a:1}"#,
        r#"{'a':1}"#,
        r#""unterminated"#,
        "tru",
        "01",
        "+1",
        "NaN",
        "Infinity",
        "[1,,2]",
        "[,]",
    ] {
        assert!(!ok(bad), "{bad:?}");
    }
    // Invalid UTF-8 is not a string.
    assert!(!bounded_exact_structure(b"\"\xff\""));
}
