use super::*;

const OPERATION: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const WORKSPACE: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const PROJECT: &str = "c3d4e5f6-3333-4333-8333-3333abcd3333";
const STAMP: &str = "2026-02-03T04:05:06.789Z";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

/// The host's folding of "Scratch". Nothing here depends on the exact
/// spelling, only that it is a folded name the display rule accepts.
const FOLDED: &str = "scratch";

fn identity(prefix: &str, device: &str, inode: &str) -> Vec<(String, Value)> {
    vec![
        (format!("{prefix}device_id"), json!(device)),
        (format!("{prefix}inode_id"), json!(inode)),
        (format!("{prefix}uid"), json!("501")),
        (format!("{prefix}gid"), json!("20")),
    ]
}

fn create_journal() -> Value {
    let mut journal = json!({
        "schema_version": 1,
        "operation_id": OPERATION,
        "workspace_id": WORKSPACE,
        "operation": "create",
        "phase": "authority_ready",
        "binding_revision": 1,
        "previous_registry_generation": 0,
        "previous_registry_sha256": digest('a'),
        "authority_sha256": digest('b'),
        "record_sha256": digest('c'),
        "staging_name": ".rish-staging-a1b2c3d4-1111-4111-8111-1111abcd1111",
        "destination_name": "Scratch",
        "display_name": "Scratch",
        "request_sha256": create_request_sha256("Scratch").expect("digest"),
        "legacy_project_id": Value::Null,
        "clearance_receipt_id": Value::Null,
        "confirmation_id": Value::Null,
        "created_at": STAMP,
        "last_opened_at": STAMP,
        "updated_at": STAMP,
    });
    let map = journal.as_object_mut().expect("object");
    for (key, value) in identity("staging_", "16777232", "111") {
        map.insert(key, value);
    }
    for (key, value) in identity("destination_", "16777232", "222") {
        map.insert(key, value);
    }
    journal
}

fn bootstrap_journal() -> Value {
    let mut journal = create_journal();
    let map = journal.as_object_mut().expect("object");
    map.insert("operation".into(), json!("bootstrap_legacy"));
    map.insert("legacy_project_id".into(), json!(PROJECT));
    map.insert(
        "request_sha256".into(),
        json!(bootstrap_request_sha256(PROJECT).expect("digest")),
    );
    for key in ["staging_name", "destination_name"] {
        map.insert(key.into(), Value::Null);
    }
    for prefix in ["staging_", "destination_"] {
        for field in ["device_id", "inode_id", "uid", "gid"] {
            map.insert(format!("{prefix}{field}"), Value::Null);
        }
    }
    journal
}

fn legacy_journal() -> Value {
    json!({
        "schema_version": 1,
        "operation_id": OPERATION,
        "workspace_id": WORKSPACE,
        "operation": "bootstrap_legacy",
        "phase": "registry_committed",
        "binding_revision": 1,
        "previous_registry_generation": 0,
        "previous_registry_sha256": digest('a'),
        "authority_sha256": digest('b'),
        "record_sha256": digest('c'),
        "staging_name": Value::Null,
        "destination_name": Value::Null,
        "legacy_project_id": PROJECT,
        "clearance_receipt_id": Value::Null,
        "confirmation_id": Value::Null,
        "created_at": STAMP,
        "updated_at": STAMP,
    })
}

#[test]
fn the_three_shapes_accept_what_the_engine_writes() {
    assert!(journal_shape(Some(&create_journal()), Some(FOLDED)));
    assert!(journal_shape(Some(&bootstrap_journal()), Some(FOLDED)));
    assert!(legacy_journal_shape(Some(&legacy_journal())));
    assert!(readable_journal(Some(&legacy_journal()), Some(FOLDED)));
    // The shapes are each exact, so neither passes as the other.
    assert!(!legacy_journal_shape(Some(&bootstrap_journal())));
    assert!(!journal_shape(Some(&legacy_journal()), Some(FOLDED)));
}

#[test]
fn every_shape_is_exact() {
    for (name, journal) in [
        ("create", create_journal()),
        ("bootstrap", bootstrap_journal()),
        ("legacy", legacy_journal()),
    ] {
        let check = |candidate: &Value| {
            if name == "legacy" {
                legacy_journal_shape(Some(candidate))
            } else {
                journal_shape(Some(candidate), Some(FOLDED))
            }
        };
        assert!(check(&journal), "{name} baseline");
        let mut extra = journal.clone();
        extra["extra"] = json!(1);
        assert!(!check(&extra), "{name} with an extra key");
        for key in journal.as_object().expect("object").keys() {
            let mut short = journal.clone();
            short.as_object_mut().expect("object").remove(key);
            assert!(!check(&short), "{name} without {key}");
        }
    }
}

/// A journal binds itself to the request it claims to be carrying out, so it
/// cannot be replayed as a different operation than the one that was asked
/// for. Rename the workspace in the journal and the digest no longer matches.
#[test]
fn a_journal_is_bound_to_its_own_request() {
    let mut renamed = create_journal();
    renamed["display_name"] = json!("Other");
    renamed["destination_name"] = json!("Other");
    assert!(!journal_shape(Some(&renamed), Some("other")));
    renamed["request_sha256"] = json!(create_request_sha256("Other").expect("digest"));
    assert!(journal_shape(Some(&renamed), Some("other")));

    let mut reprojected = bootstrap_journal();
    reprojected["legacy_project_id"] = json!(WORKSPACE);
    assert!(!journal_shape(Some(&reprojected), Some(FOLDED)));
    reprojected["request_sha256"] = json!(bootstrap_request_sha256(WORKSPACE).expect("digest"));
    assert!(journal_shape(Some(&reprojected), Some(FOLDED)));
}

/// The two request digests are over canonical JSON and are not
/// interchangeable: a bootstrap digest in a create journal is a journal for a
/// different operation.
#[test]
fn the_two_request_digests_are_distinct() {
    let create = create_request_sha256("Scratch").expect("digest");
    let bootstrap = bootstrap_request_sha256(PROJECT).expect("digest");
    assert_eq!(create.len(), 64);
    assert_eq!(bootstrap.len(), 64);
    assert_ne!(create, bootstrap);
    // Same input, different operation, different digest.
    assert_ne!(
        create_request_sha256(PROJECT).expect("digest"),
        bootstrap.clone()
    );
    // Stable across calls; nothing in it depends on a clock or a nonce.
    assert_eq!(create, create_request_sha256("Scratch").expect("digest"));
    let mut swapped = create_journal();
    swapped["request_sha256"] = json!(bootstrap);
    assert!(!journal_shape(Some(&swapped), Some(FOLDED)));
}

/// A phase says which digests exist yet. Nothing has been written at
/// `prepared`, so a journal claiming one there describes a state that cannot
/// have occurred; every later phase has both.
#[test]
fn a_phase_says_which_digests_exist_yet() {
    let mut prepared = create_journal();
    prepared["phase"] = json!("prepared");
    // Still carrying digests from a phase it has not reached.
    assert!(!journal_shape(Some(&prepared), Some(FOLDED)));
    prepared["authority_sha256"] = Value::Null;
    prepared["record_sha256"] = Value::Null;
    assert!(journal_shape(Some(&prepared), Some(FOLDED)));
    // One of the two is not enough either way.
    for phase in ["authority_ready", "registry_committed"] {
        let mut half = create_journal();
        half["phase"] = json!(phase);
        half["record_sha256"] = Value::Null;
        assert!(!journal_shape(Some(&half), Some(FOLDED)), "{phase}");
    }
    // A phase outside the three is not a phase.
    for phase in ["", "committed", "Prepared", "rolled_back"] {
        let mut wrong = create_journal();
        wrong["phase"] = json!(phase);
        assert!(!journal_shape(Some(&wrong), Some(FOLDED)), "{phase}");
    }
}

/// Physical identity is recorded in fours. Three of four is not partial
/// evidence; it is a journal no recovery engine can check against a directory.
#[test]
fn physical_identity_is_recorded_in_fours() {
    assert!(identity_present(Some(&create_journal()), "staging_"));
    assert!(identity_present(Some(&create_journal()), "destination_"));
    for prefix in ["staging_", "destination_"] {
        for field in ["device_id", "inode_id", "uid", "gid"] {
            let mut partial = create_journal();
            partial[format!("{prefix}{field}")] = Value::Null;
            assert!(
                !journal_shape(Some(&partial), Some(FOLDED)),
                "{prefix}{field}"
            );
            assert!(!identity_present(Some(&partial), prefix));
        }
    }
    // A create that has not staged anything yet may have neither set, but only
    // while it is still `prepared`.
    let mut prepared = create_journal();
    prepared["phase"] = json!("prepared");
    prepared["authority_sha256"] = Value::Null;
    prepared["record_sha256"] = Value::Null;
    for prefix in ["staging_", "destination_"] {
        for field in ["device_id", "inode_id", "uid", "gid"] {
            prepared[format!("{prefix}{field}")] = Value::Null;
        }
    }
    assert!(journal_shape(Some(&prepared), Some(FOLDED)));
    // The same journal one phase later must have them.
    let mut later = prepared.clone();
    later["phase"] = json!("authority_ready");
    later["authority_sha256"] = json!(digest('b'));
    later["record_sha256"] = json!(digest('c'));
    assert!(!journal_shape(Some(&later), Some(FOLDED)));
    // Identifiers are canonical unsigned strings, never numbers.
    let mut numeric = create_journal();
    numeric["staging_uid"] = json!(501);
    assert!(!journal_shape(Some(&numeric), Some(FOLDED)));
    let mut padded = create_journal();
    padded["staging_uid"] = json!("0501");
    assert!(!journal_shape(Some(&padded), Some(FOLDED)));
    assert!(!identity_present(None, "staging_"));
}

/// Staging under one name and moving to another is what a create *is*. A move
/// onto itself is not a move, and recovery could not tell the two directories
/// apart.
#[test]
fn a_create_stages_under_a_different_name_than_it_lands_on() {
    let mut same = create_journal();
    same["staging_name"] = same["destination_name"].clone();
    assert!(!journal_shape(Some(&same), Some(FOLDED)));
    for (key, value) in [
        ("staging_name", json!("a/b")),
        ("staging_name", Value::Null),
        ("destination_name", json!("..")),
        ("destination_name", Value::Null),
    ] {
        let mut broken = create_journal();
        broken[key] = value.clone();
        assert!(!journal_shape(Some(&broken), Some(FOLDED)), "{key}={value}");
    }
}

/// Bootstrapping adopts a project that is already on disk: there is no
/// directory to stage or move, so every name and identity is absent, and it is
/// always the first binding.
#[test]
fn a_bootstrap_stages_nothing() {
    for key in [
        "staging_name",
        "destination_name",
        "staging_device_id",
        "destination_inode_id",
        "clearance_receipt_id",
        "confirmation_id",
    ] {
        let mut occupied = bootstrap_journal();
        occupied[key] = json!("something");
        assert!(!journal_shape(Some(&occupied), Some(FOLDED)), "{key}");
    }
    let mut rebound = bootstrap_journal();
    rebound["binding_revision"] = json!(2);
    assert!(!journal_shape(Some(&rebound), Some(FOLDED)));
    let mut projectless = bootstrap_journal();
    projectless["legacy_project_id"] = Value::Null;
    assert!(!journal_shape(Some(&projectless), Some(FOLDED)));
    // A create may not carry a legacy project.
    let mut confused = create_journal();
    confused["legacy_project_id"] = json!(PROJECT);
    assert!(!journal_shape(Some(&confused), Some(FOLDED)));
}

/// Only the operations with a recovery engine are readable. Anything else
/// fails closed rather than being half-finished by a path that does not know
/// what it is looking at.
#[test]
fn only_recoverable_operations_are_readable() {
    assert_eq!(OPERATIONS, ["bootstrap_legacy", "create"]);
    for operation in ["import", "regrant", "forget", "delete_owned", "", "CREATE"] {
        let mut other = create_journal();
        other["operation"] = json!(operation);
        assert!(!journal_shape(Some(&other), Some(FOLDED)), "{operation}");
    }
    let mut legacy_create = legacy_journal();
    legacy_create["operation"] = json!("create");
    assert!(!legacy_journal_shape(Some(&legacy_create)));
}

/// The recorded identity has to be the one the host just stat'd — all four
/// facts, not two.
#[test]
fn a_recorded_identity_is_checked_against_what_is_on_disk() {
    let journal = create_journal();
    let seen = json!({
        "device_id": "16777232", "inode_id": "111", "uid": "501", "gid": "20"
    });
    assert!(identity_matches(Some(&journal), "staging_", Some(&seen)));
    // The destination is a different directory.
    assert!(!identity_matches(
        Some(&journal),
        "destination_",
        Some(&seen)
    ));
    for field in ["device_id", "inode_id", "uid", "gid"] {
        let mut moved = seen.clone();
        moved[field] = json!("999");
        assert!(
            !identity_matches(Some(&journal), "staging_", Some(&moved)),
            "{field}"
        );
    }
    // A host that could not state all four has not matched anything.
    let mut partial = seen.clone();
    partial.as_object_mut().expect("object").remove("gid");
    assert!(!identity_matches(
        Some(&journal),
        "staging_",
        Some(&partial)
    ));
    assert!(!identity_matches(Some(&journal), "staging_", None));
    // Nor has one that stated them as numbers.
    let numeric = json!({
        "device_id": 16_777_232, "inode_id": 111, "uid": 501, "gid": 20
    });
    assert!(!identity_matches(
        Some(&journal),
        "staging_",
        Some(&numeric)
    ));
}

/// Once the directory has moved, the destination is where the workspace lives;
/// the staging identity names something that no longer exists. So the
/// destination is preferred whenever it is recorded.
#[test]
fn an_authority_is_matched_against_the_destination_once_there_is_one() {
    let journal = create_journal();
    let destination = json!({ "device_id": "16777232", "inode_id": "222" });
    let staging = json!({ "device_id": "16777232", "inode_id": "111" });
    assert!(owned_authority_matches_journal(
        Some(&destination),
        Some(&journal)
    ));
    assert!(!owned_authority_matches_journal(
        Some(&staging),
        Some(&journal)
    ));
    // Before the move, the staging identity is all there is.
    let mut mid_flight = create_journal();
    for field in ["device_id", "inode_id", "uid", "gid"] {
        mid_flight[format!("destination_{field}")] = Value::Null;
    }
    assert!(owned_authority_matches_journal(
        Some(&staging),
        Some(&mid_flight)
    ));
    assert!(!owned_authority_matches_journal(
        Some(&destination),
        Some(&mid_flight)
    ));
    // A journal with no identity at all and an authority with none either do
    // "match", because null equals null — `[NSNull isEqual:NSNull]` is YES and
    // this reproduces it. That is not a hole: an owned authority is checked by
    // `workspace_authority::owned_authority` first, which requires canonical
    // unsigned strings, so an identity-less authority never reaches here.
    // Named rather than tightened, because tightening it would be a second
    // reading of the same rule on one platform only.
    let mut empty = create_journal();
    for prefix in ["staging_", "destination_"] {
        for field in ["device_id", "inode_id", "uid", "gid"] {
            empty[format!("{prefix}{field}")] = Value::Null;
        }
    }
    let identityless = json!({ "device_id": Value::Null, "inode_id": Value::Null });
    assert!(owned_authority_matches_journal(
        Some(&identityless),
        Some(&empty)
    ));
    assert!(!crate::workspace_authority::owned_authority(
        Some(&identityless),
        &json!({ "owned_directory_name": "Scratch" })
    ));
    // A real authority does not match an identity-less journal.
    assert!(!owned_authority_matches_journal(
        Some(&destination),
        Some(&empty)
    ));
    assert!(!owned_authority_matches_journal(None, Some(&journal)));
    assert!(!owned_authority_matches_journal(Some(&destination), None));
}

/// A journal's display name is a display name, folded by the host for the same
/// reason a record's is.
#[test]
fn a_journal_display_name_is_a_display_name() {
    assert!(!journal_shape(Some(&create_journal()), None));
    let mut reserved = create_journal();
    reserved["display_name"] = json!("Rish Workspaces");
    reserved["request_sha256"] = json!(create_request_sha256("Rish Workspaces").expect("digest"));
    assert!(!journal_shape(Some(&reserved), Some("rish workspaces")));
}

#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({
            "op": "journal_shape", "journal": create_journal(),
            "folded_display_name": FOLDED,
        })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "legacy_journal_shape", "journal": legacy_journal() })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({
            "op": "readable_journal", "journal": legacy_journal(),
            "folded_display_name": FOLDED,
        })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({
            "op": "identity_present", "journal": create_journal(), "prefix": "staging_"
        })),
        json!({ "ok": true, "present": true })
    );
    assert_eq!(
        run(json!({
            "op": "identity_matches", "journal": create_journal(), "prefix": "staging_",
            "observed": { "device_id": "16777232", "inode_id": "111", "uid": "501", "gid": "20" },
        })),
        json!({ "ok": true, "matches": true })
    );
    assert_eq!(
        run(json!({
            "op": "owned_authority_matches", "journal": create_journal(),
            "authority": { "device_id": "16777232", "inode_id": "222" },
        })),
        json!({ "ok": true, "matches": true })
    );
    assert_eq!(
        run(json!({ "op": "create_request_sha256", "display_name": "Scratch" }))["digest"],
        json!(create_request_sha256("Scratch").expect("digest"))
    );
    assert_eq!(
        run(json!({ "op": "bootstrap_request_sha256", "project_id": PROJECT }))["digest"],
        json!(bootstrap_request_sha256(PROJECT).expect("digest"))
    );
    for input in [
        json!({ "op": "unknown" }).to_string(),
        // A prefix is not optional: guessing one would check a different
        // directory than the caller asked about.
        json!({ "op": "identity_present", "journal": create_journal() }).to_string(),
        json!({ "op": "create_request_sha256" }).to_string(),
        json!({ "op": "bootstrap_request_sha256", "project_id": 1 }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}
