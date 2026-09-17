use super::*;

/// Foundation cuts on composed character sequences. Splitting one would write
/// a different character, so a cluster goes in whole or not at all.
fn graphemes(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

fn ascii(text: &str) -> Vec<String> {
    text.chars().map(|c| c.to_string()).collect()
}

/// Ordinal 0 is the name itself, untouched. It is already within the bound,
/// because a display name has to be.
#[test]
fn the_first_candidate_is_the_name_itself() {
    assert_eq!(candidate(&ascii("Rish"), 0).as_deref(), Some("Rish"));
    let long = "x".repeat(MAX_DISPLAY_NAME_BYTES);
    assert_eq!(candidate(&ascii(&long), 0).as_deref(), Some(long.as_str()));
}

#[test]
fn an_occupied_name_gets_an_ordinal() {
    assert_eq!(candidate(&ascii("Rish"), 1).as_deref(), Some("Rish (1)"));
    assert_eq!(candidate(&ascii("Rish"), 12).as_deref(), Some("Rish (12)"));
}

/// The suffix is paid for out of the same 120-byte budget the name has, so a
/// name at the bound loses exactly as many bytes as the suffix takes.
#[test]
fn the_suffix_is_paid_for_by_the_name() {
    let long = "x".repeat(MAX_DISPLAY_NAME_BYTES);
    let named = candidate(&ascii(&long), 1).expect("candidate");
    assert_eq!(named.len(), MAX_DISPLAY_NAME_BYTES);
    assert!(named.ends_with(" (1)"));
    assert_eq!(named.len() - " (1)".len(), MAX_DISPLAY_NAME_BYTES - 4);
    // A wider ordinal costs one more byte of name.
    let wider = candidate(&ascii(&long), 100).expect("candidate");
    assert_eq!(wider.len(), MAX_DISPLAY_NAME_BYTES);
    assert!(wider.ends_with(" (100)"));
}

/// A multi-byte name is cut by bytes, not by characters: the budget is a
/// storage bound.
#[test]
fn the_budget_is_in_bytes() {
    // Each of these is three bytes.
    let name = graphemes(&["中"; 40]);
    assert_eq!(name.concat().len(), 120);
    let named = candidate(&name, 1).expect("candidate");
    assert!(named.len() <= MAX_DISPLAY_NAME_BYTES);
    // 116 bytes of budget holds 38 clusters, not 38.66.
    assert_eq!(named, format!("{} (1)", "中".repeat(38)));
}

/// A cluster goes in whole or not at all. Cutting a flag in half writes two
/// letters nobody typed.
#[test]
fn a_cluster_is_never_split() {
    let flag = "🇯🇵"; // two regional indicators, eight bytes
    assert_eq!(flag.len(), 8);
    // Fourteen flags is 112 bytes; with " (1)" that is 116, and a fifteenth
    // would not fit, so the cut has to fall on a cluster boundary.
    let name: Vec<String> = std::iter::repeat_n(flag.to_owned(), 15).collect();
    let named = candidate(&name, 1).expect("candidate");
    assert_eq!(named, format!("{} (1)", flag.repeat(14)));
    assert_eq!(named.len(), 116);
    // Nothing partial survived: the flags in the result are whole.
    assert_eq!(named.matches(flag).count(), 14);
}

/// A name that cannot hold even one cluster is still a name — the suffix
/// alone. Only a suffix that fills the whole budget has nothing to attach to.
#[test]
fn a_name_can_be_crowded_out_entirely() {
    let wide = "中".repeat(40);
    let name = graphemes(&[&wide]);
    assert_eq!(candidate(&name, 1).as_deref(), Some(" (1)"));
    // The bound is on the suffix, and it is the same 120 bytes.
    let huge = 10u64.pow(18);
    assert!(candidate(&ascii("Rish"), huge).is_some());
    assert!(suffix(u64::MAX).len() < MAX_DISPLAY_NAME_BYTES);
    assert_eq!(candidate(&[], 3).as_deref(), Some(" (3)"));
    assert_eq!(candidate(&[], 0).as_deref(), Some(""));
}

/// `DSHInternalComponent`: what the registry writes as a component of its own.
#[test]
fn an_internal_component_is_one_path_component() {
    for good in [
        ".rish-staging-a1b2c3d4-1111-4111-8111-1111abcd1111",
        "Rish",
        "中文",
        "  ",
        &"x".repeat(MAX_COMPONENT_BYTES),
    ] {
        assert!(internal_component(Some(&json!(good))), "{good}");
    }
    for bad in [
        json!(""),
        json!("."),
        json!(".."),
        json!("a/b"),
        json!("a\\b"),
        json!("a\0b"),
        json!("a\nb"),
        json!("a\u{7f}b"),
        // Cf, not Cc: Foundation's controlCharacterSet is both.
        json!("a\u{200e}b"),
        json!("x".repeat(MAX_COMPONENT_BYTES + 1)),
        json!(1),
        json!(Value::Null),
    ] {
        assert!(!internal_component(Some(&bad)), "{bad}");
    }
    assert!(!internal_component(None));
    assert_eq!(MAX_COMPONENT_BYTES, 255);
}

/// The reducer answers every op it claims to, and refuses the rest.
#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let reply = reduce_json(&json!({ "op": "internal_component", "value": "Rish" }).to_string());
    assert_eq!(reply, r#"{"ok":true,"valid":true}"#);
    let reply = reduce_json(
        &json!({ "op": "candidate", "graphemes": ["R", "i", "s", "h"], "ordinal": 2 }).to_string(),
    );
    assert_eq!(reply, r#"{"candidate":"Rish (2)","ok":true}"#);
    for input in [
        json!({ "op": "unknown" }).to_string(),
        // Clusters that are not strings are not clusters.
        json!({ "op": "candidate", "graphemes": [1], "ordinal": 1 }).to_string(),
        json!({ "op": "candidate", "graphemes": "Rish", "ordinal": 1 }).to_string(),
        json!({ "op": "candidate", "graphemes": ["R"] }).to_string(),
        json!({ "op": "candidate", "graphemes": ["R"], "ordinal": -1 }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
