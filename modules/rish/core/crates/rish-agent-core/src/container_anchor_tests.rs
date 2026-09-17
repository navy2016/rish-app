use super::*;

const APP: &str = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const DEVICE: &str = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";

fn parts(items: &[&str]) -> Vec<String> {
    items.iter().map(|item| (*item).to_owned()).collect()
}

/// The device layout, as `pathComponents` produces it — leading "/" included,
/// which is why splitting stays with the host.
fn device_root() -> Vec<String> {
    parts(&[
        "/",
        "private",
        "var",
        "mobile",
        "Containers",
        "Data",
        "Application",
        APP,
    ])
}

/// The simulator layout, which holds a *second* UUID further up.
fn simulator_root() -> Vec<String> {
    parts(&[
        "/",
        "Users",
        "someone",
        "Library",
        "Developer",
        "CoreSimulator",
        "Devices",
        DEVICE,
        "data",
        "Containers",
        "Data",
        "Application",
        APP,
    ])
}

fn inside(root: &[String], tail: &[&str]) -> Vec<String> {
    let mut path = root.to_vec();
    path.extend(tail.iter().map(|item| (*item).to_owned()));
    path
}

#[test]
fn a_container_root_anchors_at_its_own_uuid() {
    let root = device_root();
    let target = inside(&root, &["Library", "Application Support", "workspace"]);
    let index = anchor_segment_count(&target, &root).expect("anchor");
    assert_eq!(index, root.len() - 1);
    assert_eq!(target[index], APP);
    // The root itself is an accepted target.
    assert_eq!(anchor_segment_count(&root, &root), Some(root.len() - 1));
}

/// Two container tails in one path: the innermost wins. This is the case the
/// rule exists for, and a path with only one tail cannot show it — the first
/// version of this test used the simulator layout, where the CoreSimulator
/// device UUID is *not* preceded by the container tail, so scanning from
/// either end gave the same answer and the rule could have been reversed
/// without any test noticing.
#[test]
fn the_innermost_of_two_containers_wins() {
    let outer = parts(&[
        "/",
        "private",
        "var",
        "mobile",
        "Containers",
        "Data",
        "Application",
        "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
    ]);
    let nested = inside(&outer, &["Data", "Containers", "Data", "Application", APP]);
    let index = last_app_container_index(&nested).expect("index");
    assert_eq!(index, nested.len() - 1);
    assert_eq!(nested[index], APP);
    assert_ne!(nested[index], "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb");
    // Both are real tails, which is what makes the choice a choice.
    assert!(ends_with_app_container(&nested, outer.len() - 1));
    assert!(ends_with_app_container(&nested, nested.len() - 1));
}

/// The CoreSimulator device UUID sits further up the simulator path and is a
/// perfectly good UUID — but it is not preceded by the container tail, so it
/// was never a candidate.
#[test]
fn the_simulator_device_uuid_is_not_a_container() {
    let root = simulator_root();
    let target = inside(&root, &["Library", "Application Support"]);
    let index = anchor_segment_count(&target, &root).expect("anchor");
    assert_eq!(target[index], APP);
    assert_ne!(target[index], DEVICE);
    assert_eq!(last_app_container_index(&root), Some(root.len() - 1));
    // The device UUID is a UUID, and is *not* preceded by the container tail,
    // so it was never a candidate in the first place.
    assert!(canonical_uuid_text(DEVICE));
    assert!(!ends_with_app_container(&root, 7));
}

/// A container root that carries anything after its own UUID is not a
/// container root. Anchoring there would let the caller choose where the walk
/// starts.
#[test]
fn a_root_must_end_at_its_container_uuid() {
    let root = inside(&device_root(), &["Library"]);
    let target = inside(&root, &["Application Support"]);
    assert_eq!(anchor_segment_count(&target, &root), None);
}

/// The target has to be inside the root, component for component. A shared
/// string prefix is not a shared path.
#[test]
fn the_target_must_be_inside_the_root() {
    let root = device_root();
    let mut sibling = root.clone();
    let last = sibling.len() - 1;
    sibling[last] = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb".to_string();
    let target = inside(&sibling, &["Library"]);
    assert_eq!(anchor_segment_count(&target, &root), None);
    // Shorter than the root is not inside it.
    assert_eq!(anchor_segment_count(&root[..4], &root), None);
}

/// Traversal is refused at derivation time as well as during the walk, so an
/// anchor is never derived from a traversal-shaped path in the first place.
#[test]
fn traversal_is_refused_before_an_anchor_is_derived() {
    let root = device_root();
    let target = inside(&root, &["Library", "..", "Documents"]);
    assert_eq!(anchor_segment_count(&target, &root), None);
    let mut dotted_root = root.clone();
    dotted_root.insert(3, ".".to_string());
    assert_eq!(anchor_segment_count(&dotted_root, &dotted_root), None);
    assert!(contains_traversal(&parts(&["a", ".."])));
    assert!(contains_traversal(&parts(&["a", "."])));
    assert!(!contains_traversal(&parts(&["a", "...", "..a"])));
}

/// A container directory is named by the system, so anything else in that
/// position was not put there by the system.
#[test]
fn only_a_canonical_uuid_names_a_container() {
    assert!(canonical_uuid_text(APP));
    assert!(canonical_uuid_text("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"));
    for bad in [
        "",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaa",
        "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaaa",
        "aaaaaaaaxaaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "gaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        "aaaaaaaa aaaa 4aaa 8aaa aaaaaaaaaaaa",
        "Application",
    ] {
        assert!(!canonical_uuid_text(bad), "{bad:?}");
    }
    // A tail that is not Containers/Data/Application is not a container.
    for tail in [
        parts(&["/", "Containers", "Data", "Applications", APP]),
        parts(&["/", "Containers", "Shared", "Application", APP]),
        parts(&["/", "Data", "Application", APP]),
        parts(&["/", APP]),
    ] {
        assert_eq!(last_app_container_index(&tail), None, "{tail:?}");
    }
}

/// The scan is the same rule without a root to check against, so traversal
/// still has no anchor and the innermost container still wins.
#[test]
fn a_scan_without_a_root_is_the_same_rule() {
    let root = device_root();
    let target = inside(&root, &["Library", "Application Support"]);
    assert_eq!(scan_segment_count(&target), Some(root.len() - 1));
    assert_eq!(scan_segment_count(&root), Some(root.len() - 1));
    assert_eq!(scan_segment_count(&inside(&root, &["..", "Library"])), None);
    assert_eq!(scan_segment_count(&parts(&["/", "elsewhere"])), None);
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let root = device_root();
    let target = inside(&root, &["Library"]);
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({
            "op": "anchor_segment_count", "target": target, "container_root": root
        })),
        json!({ "ok": true, "segments": root.len() - 1 })
    );
    // Not anchorable is an answer, not a refusal.
    assert_eq!(
        run(json!({
            "op": "anchor_segment_count",
            "target": parts(&["/", "elsewhere"]),
            "container_root": root,
        })),
        json!({ "ok": true, "segments": Value::Null })
    );
    assert_eq!(
        run(json!({ "op": "scan_segment_count", "target": target }))["segments"],
        json!(root.len() - 1)
    );
    assert_eq!(
        run(json!({ "op": "canonical_uuid_text", "value": APP })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "last_app_container_index", "components": simulator_root() }))["index"],
        json!(simulator_root().len() - 1)
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        // Components that are not strings are not path components.
        json!({ "op": "last_app_container_index", "components": [1] }).to_string(),
        json!({ "op": "anchor_segment_count", "target": target }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
