use super::*;

const WORKSPACE: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const PROJECT: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

fn owned_record() -> Value {
    json!({ "origin": "rish_created", "workspace_id": WORKSPACE, "binding_revision": 3 })
}

fn owned_authority() -> Value {
    json!({
        "schema_version": 1,
        "device_id": "16777232", "inode_id": "1234567",
        "directory_name_sha256": digest('a'),
        "root_fingerprint_sha256": digest('f'),
    })
}

#[test]
fn an_owned_authority_fingerprints_over_its_own_contents() {
    let record = owned_record();
    let mut authority = owned_authority();
    let input = fingerprint_input(&record, &authority).expect("input");
    assert!(input_shape(Some(&input)), "{input}");
    let expected = fingerprint(Some(&input)).expect("fingerprint");
    authority["root_fingerprint_sha256"] = json!(expected);
    assert!(fingerprint_valid(&authority, &record));
}

/// The fingerprint folds in the digest of the authority *without* its own
/// fingerprint, so it covers everything the record says about itself and
/// cannot be carried to a record that says something different.
#[test]
fn a_fingerprint_does_not_survive_a_changed_authority() {
    let record = owned_record();
    let mut authority = owned_authority();
    let input = fingerprint_input(&record, &authority).expect("input");
    authority["root_fingerprint_sha256"] = json!(fingerprint(Some(&input)).expect("fp"));
    assert!(fingerprint_valid(&authority, &record));
    for (key, value) in [
        ("device_id", json!("16777233")),
        ("inode_id", json!("7654321")),
        ("directory_name_sha256", json!(digest('b'))),
    ] {
        let mut moved = authority.clone();
        moved[key] = value;
        assert!(!fingerprint_valid(&moved, &record), "{key}");
    }
    // A different workspace or a later binding is a different root.
    for (key, value) in [
        ("workspace_id", json!(PROJECT)),
        ("binding_revision", json!(4)),
    ] {
        let mut other = record.clone();
        other[key] = value;
        assert!(!fingerprint_valid(&authority, &other), "{key}");
    }
}

/// An authority carries a `root_fingerprint_sha256` of its own; removing it
/// before digesting is what makes the fingerprint computable at all. A stray
/// extra field still changes the answer, because the digest covers the record.
#[test]
fn the_authority_digest_ignores_only_the_fingerprint_itself() {
    let base = owned_authority();
    let without = {
        let mut map = base.as_object().expect("object").clone();
        map.remove("root_fingerprint_sha256");
        Value::Object(map)
    };
    assert_eq!(
        authority_digest(Some(&base)),
        authority_digest(Some(&without)),
    );
    let mut different = base.clone();
    different["root_fingerprint_sha256"] = json!(digest('e'));
    assert_eq!(
        authority_digest(Some(&base)),
        authority_digest(Some(&different))
    );
    let mut extra = base.clone();
    extra["note"] = json!("hello");
    assert_ne!(
        authority_digest(Some(&base)),
        authority_digest(Some(&extra))
    );
}

#[test]
fn each_origin_has_its_own_shape_and_they_do_not_borrow_each_others_keys() {
    let granted_record =
        json!({ "origin": "granted_folder", "workspace_id": WORKSPACE, "binding_revision": 1 });
    let granted_authority = json!({
        "schema_version": 1,
        "volume_identifier_sha256": digest('1'),
        "resource_identifier_sha256": digest('2'),
        "device_id": "1", "inode_id": "2",
        "bookmark_sha256": digest('3'),
        "root_fingerprint_sha256": digest('f'),
    });
    let input = fingerprint_input(&granted_record, &granted_authority).expect("input");
    assert_eq!(input["root_locator_kind"], json!("security_scoped"));
    assert!(input_shape(Some(&input)));

    let legacy_record =
        json!({ "origin": "legacy_app_owned", "workspace_id": WORKSPACE, "binding_revision": 2 });
    let legacy_authority = json!({
        "legacy_project_id": PROJECT,
        "project_metadata_sha256": digest('4'),
        "projects_root_device_id": "1", "projects_root_inode_id": "2",
        "repository_device_id": "3", "repository_inode_id": "4",
        "git_device_id": "5", "git_inode_id": "6",
    });
    let input = fingerprint_input(&legacy_record, &legacy_authority).expect("input");
    assert_eq!(input["root_locator_kind"], json!("legacy_app_owned"));
    // The legacy shape folds in no authority digest: its records predate one.
    assert!(input.get("authority_sha256").is_none());
    assert!(input_shape(Some(&input)));

    // An owned input with a granted key, or vice versa, is not a shape.
    let mut hybrid = fingerprint_input(&owned_record(), &owned_authority()).expect("input");
    hybrid["bookmark_sha256"] = json!(digest('3'));
    assert!(!input_shape(Some(&hybrid)));
    assert_eq!(fingerprint(Some(&hybrid)), None);
}

/// Device and inode numbers travel as their shortest decimal spelling, because
/// they outrun a safe integer on some filesystems and two spellings of one
/// number would be two roots.
#[test]
fn a_device_number_has_exactly_one_spelling() {
    let mut input = fingerprint_input(&owned_record(), &owned_authority()).expect("input");
    for good in ["0", "1", "18446744073709551615"] {
        input["device_id"] = json!(good);
        assert!(input_shape(Some(&input)), "{good}");
    }
    for bad in [
        "",
        "01",
        "+1",
        "-1",
        " 1",
        "1 ",
        "1.0",
        "0x10",
        "18446744073709551616",
    ] {
        input["device_id"] = json!(bad);
        assert!(!input_shape(Some(&input)), "{bad:?}");
    }
    input["device_id"] = json!(16777232u64);
    assert!(!input_shape(Some(&input)), "a number, not a string");
}

#[test]
fn a_binding_revision_starts_at_one() {
    let mut input = fingerprint_input(&owned_record(), &owned_authority()).expect("input");
    for bad in [json!(0), json!(-1), json!("3"), json!(1.5), Value::Null] {
        input["binding_revision"] = bad.clone();
        assert!(!input_shape(Some(&input)), "{bad}");
    }
    input["binding_revision"] = json!(1);
    assert!(input_shape(Some(&input)));
}

#[test]
fn an_unknown_origin_gets_no_fingerprint() {
    let record =
        json!({ "origin": "somewhere_else", "workspace_id": WORKSPACE, "binding_revision": 1 });
    assert_eq!(fingerprint_input(&record, &owned_authority()), None);
    assert_eq!(
        fingerprint(Some(&json!({ "origin": "somewhere_else" }))),
        None
    );
    assert!(!input_shape(Some(&json!([]))));
    assert!(!input_shape(None));
}

#[test]
fn the_reducer_answers_its_ops() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    let reply = run(json!({
        "op": "fingerprint_input",
        "record": owned_record(), "authority": owned_authority(),
    }));
    assert_eq!(reply["ok"], json!(true));
    let input = reply["input"].clone();
    let reply = run(json!({ "op": "fingerprint", "input": input }));
    assert!(canonical_sha256(Some(&reply["fingerprint"])), "{reply}");
    let reply = run(json!({ "op": "authority_digest", "authority": owned_authority() }));
    assert!(canonical_sha256(Some(&reply["digest"])));
    assert_eq!(run(json!({ "op": "teleport" }))["ok"], json!(false));
}

/// Sealing and recognising are the same step read in two directions. Whatever
/// `seal` produces is exactly what `fingerprint_valid` will later accept, for
/// every origin — which is the only reason a freshly written authority opens
/// on the next launch.
#[test]
fn what_seal_writes_is_what_fingerprint_valid_accepts() {
    let cases = [
        ("rish_created", owned_record(), owned_authority()),
        (
            "granted_folder",
            json!({
                "origin": "granted_folder", "workspace_id": WORKSPACE,
                "binding_revision": 2
            }),
            json!({
                "schema_version": 1,
                "volume_identifier_sha256": digest('1'),
                "resource_identifier_sha256": digest('2'),
                "device_id": "16777232", "inode_id": "42",
                "bookmark_sha256": digest('3'),
                "root_fingerprint_sha256": digest('f'),
            }),
        ),
        (
            "legacy_app_owned",
            json!({
                "origin": "legacy_app_owned", "workspace_id": WORKSPACE,
                "binding_revision": 5
            }),
            json!({
                "schema_version": 1,
                "legacy_project_id": PROJECT,
                "project_metadata_sha256": digest('4'),
                "projects_root_device_id": "16777232",
                "projects_root_inode_id": "11",
                "repository_device_id": "16777232",
                "repository_inode_id": "22",
                "git_device_id": "16777232",
                "git_inode_id": "33",
                "root_fingerprint_sha256": digest('f'),
            }),
        ),
    ];
    for (origin, record, mut authority) in cases {
        let sha = seal(&record, &authority).unwrap_or_else(|| panic!("{origin}"));
        authority["root_fingerprint_sha256"] = json!(sha.clone());
        assert!(fingerprint_valid(&authority, &record), "{origin}");
        // And it is the same answer as building the input by hand, so the
        // one-step form is not a second rule.
        let input = fingerprint_input(&record, &authority).expect("input");
        assert_eq!(fingerprint(Some(&input)), Some(sha), "{origin}");
    }
    // An origin the rule does not know seals to nothing.
    assert!(seal(
        &json!({ "origin": "elsewhere", "workspace_id": WORKSPACE, "binding_revision": 1 }),
        &owned_authority()
    )
    .is_none());
}

/// The reducer's `seal` op answers with the same digest, and refuses an
/// envelope missing either half rather than sealing over a default.
#[test]
fn the_reducer_seals() {
    let record = owned_record();
    let authority = owned_authority();
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({ "op": "seal", "record": record, "authority": authority }).to_string(),
    ))
    .expect("reply");
    assert_eq!(
        reply["fingerprint"],
        json!(seal(&record, &authority).expect("seal"))
    );
    for input in [
        json!({ "op": "seal", "record": record }).to_string(),
        json!({ "op": "seal", "authority": authority }).to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
