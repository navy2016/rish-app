use super::*;

const WORKSPACE: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const PROJECT: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

fn root_ref() -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": WORKSPACE,
        "binding_revision": 3,
        "project_id": PROJECT,
    })
}

fn binding() -> Value {
    json!({
        "schema_version": 2,
        "workspace_id": WORKSPACE,
        "binding_revision": 3,
        "project_id": PROJECT,
        "display_name": "Notes",
        "git_topology": GIT_TOPOLOGY,
        "git_directory_url": "file:///private/git/notes",
        "root_fingerprint_sha256": digest('a'),
    })
}

fn git() -> GitDirectory<'static> {
    GitDirectory {
        is_file_url: true,
        path: Some("/private/git/notes"),
    }
}

#[test]
fn a_root_reference_names_a_workspace_and_maybe_a_project() {
    assert!(root_ref_valid(Some(&root_ref()), true));
    assert!(root_ref_valid(Some(&root_ref()), false));
    let mut projectless = root_ref();
    projectless["project_id"] = Value::Null;
    // The same reference answers both questions; which one is asked is the
    // caller's, not the shape's.
    assert!(root_ref_valid(Some(&projectless), false));
    assert!(!root_ref_valid(Some(&projectless), true));
}

#[test]
fn a_root_reference_is_exact_and_typed() {
    for (key, value) in [
        ("schema_version", json!(2)),
        ("schema_version", json!("1")),
        ("schema_version", json!(true)),
        ("workspace_id", json!("not-a-uuid")),
        ("workspace_id", json!(Value::Null)),
        ("binding_revision", json!(0)),
        ("binding_revision", json!(-1)),
        ("binding_revision", json!("3")),
        ("project_id", json!("not-a-uuid")),
    ] {
        let mut broken = root_ref();
        broken[key] = value.clone();
        assert!(!root_ref_valid(Some(&broken), false), "{key} = {value}");
    }
    let mut extra = root_ref();
    extra["extra"] = json!(1);
    assert!(!root_ref_valid(Some(&extra), false));
    for key in root_ref().as_object().expect("object").keys() {
        let mut short = root_ref();
        short.as_object_mut().expect("object").remove(key);
        assert!(!root_ref_valid(Some(&short), false), "without {key}");
    }
    assert!(!root_ref_valid(None, false));
}

/// The canonical form enumerates its keys and re-renders the revision, so two
/// references naming one root have the same bytes.
#[test]
fn the_canonical_reference_is_one_spelling() {
    let canonical = canonical_root_ref(Some(&root_ref())).expect("canonical");
    assert_eq!(canonical, root_ref());
    // Key order in the input does not change the output.
    let shuffled = json!({
        "project_id": PROJECT,
        "binding_revision": 3,
        "workspace_id": WORKSPACE,
        "schema_version": 1,
    });
    assert_eq!(canonical_root_ref(Some(&shuffled)), Some(root_ref()));
    // A reference the rule refuses has no canonical form.
    assert!(canonical_root_ref(Some(&json!({}))).is_none());
    assert!(canonical_root_ref(None).is_none());
    let mut projectless = root_ref();
    projectless["project_id"] = Value::Null;
    assert_eq!(
        canonical_root_ref(Some(&projectless)),
        Some(projectless.clone())
    );
}

/// A binding restates its root reference's identity. One found beside a
/// project must prove it was written for *this* root at *this* revision, or it
/// is a binding for something else that happens to be in the way.
#[test]
fn a_binding_must_belong_to_the_root_it_was_loaded_for() {
    assert!(binding_valid(
        Some(&binding()),
        Some(&root_ref()),
        Some(&digest('a')),
        &git()
    ));
    for (key, value) in [
        ("workspace_id", json!(PROJECT)),
        ("binding_revision", json!(4)),
        ("project_id", json!(WORKSPACE)),
    ] {
        let mut elsewhere = root_ref();
        elsewhere[key] = value.clone();
        assert!(
            !binding_valid(
                Some(&binding()),
                Some(&elsewhere),
                Some(&digest('a')),
                &git()
            ),
            "{key}"
        );
    }
    // And to the root fingerprint it names.
    assert!(!binding_valid(
        Some(&binding()),
        Some(&root_ref()),
        Some(&digest('b')),
        &git()
    ));
    assert!(!binding_valid(
        Some(&binding()),
        Some(&root_ref()),
        None,
        &git()
    ));
    assert!(!binding_valid(
        Some(&binding()),
        None,
        Some(&digest('a')),
        &git()
    ));
}

#[test]
fn a_binding_is_the_topology_this_engine_produces() {
    assert_eq!(GIT_TOPOLOGY, "private_split_gitdir");
    for topology in ["", "shared_gitdir", "worktree", "Private_Split_Gitdir"] {
        let mut other = binding();
        other["git_topology"] = json!(topology);
        assert!(
            !binding_valid(Some(&other), Some(&root_ref()), Some(&digest('a')), &git()),
            "{topology}"
        );
    }
    // Version 2; a version 1 binding is a different shape, not this one.
    let mut older = binding();
    older["schema_version"] = json!(1);
    assert!(!binding_valid(
        Some(&older),
        Some(&root_ref()),
        Some(&digest('a')),
        &git()
    ));
}

#[test]
fn a_binding_display_name_is_a_single_visible_component() {
    for bad in ["", "a/b", "a\\b", ".", "..", "a\u{7f}b", "a\u{200e}b"] {
        let mut broken = binding();
        broken["display_name"] = json!(bad);
        assert!(
            !binding_valid(Some(&broken), Some(&root_ref()), Some(&digest('a')), &git()),
            "{bad:?}"
        );
    }
    let mut wide = binding();
    wide["display_name"] = json!("x".repeat(MAX_DISPLAY_NAME_BYTES));
    assert!(binding_valid(
        Some(&wide),
        Some(&root_ref()),
        Some(&digest('a')),
        &git()
    ));
    wide["display_name"] = json!("x".repeat(MAX_DISPLAY_NAME_BYTES + 1));
    assert!(!binding_valid(
        Some(&wide),
        Some(&root_ref()),
        Some(&digest('a')),
        &git()
    ));
    // A leading dot is allowed here, unlike a workspace directory name: the
    // project's display name is not its folder name.
    let mut dotted = binding();
    dotted["display_name"] = json!(".config");
    assert!(binding_valid(
        Some(&dotted),
        Some(&root_ref()),
        Some(&digest('a')),
        &git()
    ));
}

/// The git directory has to be an absolute file path this process could open.
#[test]
fn a_binding_names_an_absolute_local_git_directory() {
    let cases = [
        (
            "not a file url",
            GitDirectory {
                is_file_url: false,
                path: Some("/private/git/notes"),
            },
        ),
        (
            "relative",
            GitDirectory {
                is_file_url: true,
                path: Some("private/git/notes"),
            },
        ),
        (
            "control byte",
            GitDirectory {
                is_file_url: true,
                path: Some("/private/\u{1}notes"),
            },
        ),
        (
            "absent",
            GitDirectory {
                is_file_url: true,
                path: None,
            },
        ),
    ];
    for (name, directory) in cases {
        assert!(
            !binding_valid(
                Some(&binding()),
                Some(&root_ref()),
                Some(&digest('a')),
                &directory
            ),
            "{name}"
        );
    }
    let long = format!("/{}", "x".repeat(MAX_PATH_BYTES));
    assert!(!binding_valid(
        Some(&binding()),
        Some(&root_ref()),
        Some(&digest('a')),
        &GitDirectory {
            is_file_url: true,
            path: Some(&long)
        }
    ));
}

/// The git directory path is a local fact that differs between installs of the
/// same project, so it is **not** in the digest — two devices must agree about
/// a binding they agree about.
#[test]
fn a_binding_digest_leaves_out_the_private_git_path() {
    let here = binding_digest(Some(&binding())).expect("digest");
    let mut elsewhere = binding();
    elsewhere["git_directory_url"] = json!("file:///somewhere/else/notes");
    assert_eq!(
        binding_digest(Some(&elsewhere)).as_deref(),
        Some(here.as_str())
    );
    // Everything else does change it.
    for (key, value) in [
        ("display_name", json!("Other")),
        ("binding_revision", json!(4)),
        ("root_fingerprint_sha256", json!(digest('b'))),
        ("project_id", json!(WORKSPACE)),
    ] {
        let mut changed = binding();
        changed[key] = value.clone();
        assert_ne!(
            binding_digest(Some(&changed)).as_deref(),
            Some(here.as_str()),
            "{key}"
        );
    }
    assert_eq!(here.len(), 64);
    assert!(binding_digest(None).is_none());
    assert!(binding_digest(Some(&json!([]))).is_none());
}

#[test]
fn stored_metadata_is_a_name_two_dates_and_an_optional_origin() {
    let record = json!({
        "schema_version": 1,
        "name": "Notes",
        "created_at": "2026-02-03T04:05:06.789Z",
        "updated_at": "2026-02-03T04:05:06.789Z",
        "origin_url": "https://example.invalid/notes.git",
    });
    assert!(stored_metadata_valid(Some(&record)));
    let mut originless = record.clone();
    originless["origin_url"] = Value::Null;
    assert!(stored_metadata_valid(Some(&originless)));
    // Absent is not the same as null: the key is part of the shape.
    let mut missing = record.clone();
    missing
        .as_object_mut()
        .expect("object")
        .remove("origin_url");
    assert!(!stored_metadata_valid(Some(&missing)));

    for (key, value) in [
        ("schema_version", json!(2)),
        ("name", json!("")),
        ("name", json!("a/b")),
        ("name", json!("a\\b")),
        ("name", json!("a\u{7f}b")),
        ("name", json!("x".repeat(MAX_DISPLAY_NAME_BYTES + 1))),
        // The dates are bounded, not parsed — but a nineteen-character one is
        // too short to be a timestamp at all.
        ("created_at", json!("2026-02-03T04:05:0")),
        ("updated_at", json!("x".repeat(65))),
        ("created_at", json!("2026-02-03T04:05:06\u{1}")),
        ("origin_url", json!("x".repeat(MAX_ORIGIN_BYTES + 1))),
        ("origin_url", json!("https://example.invalid/\u{1}")),
        ("origin_url", json!(1)),
    ] {
        let mut broken = record.clone();
        broken[key] = value.clone();
        assert!(!stored_metadata_valid(Some(&broken)), "{key} = {value}");
    }
    assert!(!stored_metadata_valid(None));
}

/// The trimming comes from the host because Foundation's
/// `whitespaceAndNewlineCharacterSet` includes U+200B and Rust's `trim` does
/// not.
///
/// **It is not load-bearing for anything these tests can reach**, and saying
/// so is better than implying otherwise: U+200B — the one character the two
/// sets are known to disagree about — is a format character, so
/// `path_control_or_format` already refuses it. Replacing the host's answer
/// with `name.trim()` leaves every test here green. The projection stays
/// because Foundation's set cannot be enumerated from this side, and being
/// wrong about it would mean accepting a padded name the writing device
/// refuses; it is a guard against an unknown, held deliberately rather than
/// by accident.
#[test]
fn a_legacy_display_name_is_trimmed_by_the_host() {
    assert!(legacy_display_name(Some(&json!("Notes")), Some("Notes")));
    // The host says it trims to something shorter: padded, so refused.
    assert!(!legacy_display_name(
        Some(&json!("Notes\u{200b}")),
        Some("Notes")
    ));
    // Without the host's answer there is nothing to compare against.
    assert!(!legacy_display_name(Some(&json!("Notes")), None));
    // The redundancy, stated: Rust's trim leaves the zero-width space alone,
    // and the format-character rule refuses it anyway.
    assert_eq!("Notes\u{200b}".trim(), "Notes\u{200b}");
    assert!(!legacy_display_name(
        Some(&json!("Notes\u{200b}")),
        Some("Notes\u{200b}")
    ));
    // An ordinary trailing space is caught by the trimming, on both sides.
    assert!(!legacy_display_name(Some(&json!("Notes ")), Some("Notes")));

    for bad in [".hidden", ".", "..", "a/b", "a\\b", "a:b", "a\u{7f}b", ""] {
        assert!(
            !legacy_display_name(Some(&json!(bad)), Some(bad)),
            "{bad:?}"
        );
    }
    // Decomposed is not the stored spelling.
    let decomposed = "e\u{301}";
    assert!(!legacy_display_name(
        Some(&json!(decomposed)),
        Some(decomposed)
    ));
    assert!(legacy_display_name(Some(&json!("é")), Some("é")));
    let wide = "x".repeat(MAX_DISPLAY_NAME_BYTES);
    assert!(legacy_display_name(Some(&json!(wide)), Some(&wide)));
    let wider = "x".repeat(MAX_DISPLAY_NAME_BYTES + 1);
    assert!(!legacy_display_name(Some(&json!(wider)), Some(&wider)));
    assert!(!legacy_display_name(None, Some("Notes")));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({ "op": "root_ref_valid", "root_ref": root_ref(), "project_required": true })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "canonical_root_ref", "root_ref": root_ref() }))["root_ref"],
        root_ref()
    );
    assert_eq!(
        run(json!({
            "op": "binding_valid", "binding": binding(), "root_ref": root_ref(),
            "root_fingerprint_sha256": digest('a'),
            "git_is_file_url": true, "git_directory_path": "/private/git/notes",
        })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "binding_digest", "binding": binding() }))["digest"],
        json!(binding_digest(Some(&binding())).expect("digest"))
    );
    assert_eq!(
        run(json!({
            "op": "legacy_display_name", "value": "Notes", "foundation_trimmed": "Notes"
        })),
        json!({ "ok": true, "valid": true })
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        json!({ "root_ref": root_ref() }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
