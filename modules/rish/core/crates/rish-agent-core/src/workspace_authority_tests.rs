use super::*;

use crate::workspace_fingerprint::{fingerprint, fingerprint_input};

const WORKSPACE: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const OTHER: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";
const PROJECT: &str = "c3d4e5f6-3333-4333-8333-3333abcd3333";
const STAMP: &str = "2026-02-03T04:05:06.789Z";
const LATER: &str = "2026-02-03T04:05:07.000Z";

fn digest(seed: char) -> String {
    std::iter::repeat_n(seed, 64).collect()
}

/// Seals an authority with the fingerprint its own contents imply, the way the
/// host does when it writes one.
fn sealed(mut authority: Value, record: &Value) -> Value {
    let input = fingerprint_input(record, &authority).expect("input");
    let sha = fingerprint(Some(&input)).expect("fingerprint");
    authority["root_fingerprint_sha256"] = json!(sha);
    authority
}

fn owned_record() -> Value {
    json!({
        "origin": "rish_created",
        "root_locator_kind": "documents_owned",
        "workspace_id": WORKSPACE,
        "binding_revision": 3,
        "owned_directory_name": "ws-a1b2c3d4",
    })
}

fn owned() -> Value {
    let record = owned_record();
    sealed(
        json!({
            "schema_version": 1,
            "workspace_id": WORKSPACE,
            "binding_revision": 3,
            "device_id": "16777232",
            "inode_id": "1234567",
            "directory_name_sha256": sha256_hex(b"ws-a1b2c3d4"),
            "recorded_at": STAMP,
            "root_fingerprint_sha256": digest('f'),
        }),
        &record,
    )
}

fn granted_record() -> Value {
    json!({
        "origin": "granted_folder",
        "root_locator_kind": "security_scoped",
        "workspace_id": WORKSPACE,
        "binding_revision": 5,
    })
}

fn bookmark() -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": WORKSPACE,
        "binding_revision": 5,
        "bookmark_sha256": digest('b'),
        "bookmark_bytes_base64": "Ym9va21hcms=",
        "recorded_at": STAMP,
    })
}

fn bookmark_bytes(sha: &str) -> BookmarkBytes<'_> {
    BookmarkBytes {
        sha256: Some(sha),
        length: 8,
    }
}

fn granted() -> Value {
    let record = granted_record();
    sealed(
        json!({
            "schema_version": 1,
            "workspace_id": WORKSPACE,
            "binding_revision": 5,
            "volume_identifier_sha256": digest('c'),
            "resource_identifier_sha256": digest('d'),
            "device_id": "16777232",
            "inode_id": "7654321",
            "bookmark_sha256": digest('b'),
            "classified_at": STAMP,
            "root_fingerprint_sha256": digest('f'),
        }),
        &record,
    )
}

fn legacy_record() -> Value {
    json!({
        "origin": "legacy_app_owned",
        "root_locator_kind": "legacy_app_owned",
        "workspace_id": WORKSPACE,
        "binding_revision": 7,
        "legacy_project_id": PROJECT,
        "display_name": "Rish",
        "created_at": STAMP,
        "last_opened_at": LATER,
    })
}

fn legacy() -> Value {
    let record = legacy_record();
    sealed(
        json!({
            "schema_version": 1,
            "workspace_id": WORKSPACE,
            "binding_revision": 7,
            "legacy_project_id": PROJECT,
            "root_identity_sha256": digest('1'),
            "display_name": "Rish",
            "capabilities": ["read", "write", "git"],
            "created_at": STAMP,
            "last_opened_at": LATER,
            "recorded_at": LATER,
            "project_metadata_sha256": digest('2'),
            "projects_root_device_id": "16777232",
            "projects_root_inode_id": "11",
            "repository_device_id": "16777232",
            "repository_inode_id": "22",
            "git_device_id": "16777232",
            "git_inode_id": "33",
            "root_fingerprint_sha256": digest('f'),
        }),
        &record,
    )
}

/// Each fixture is the thing the rule accepts. If one of these ever stops
/// passing, every rejection test below stops proving anything.
#[test]
fn the_four_shapes_accept_what_the_host_writes() {
    assert!(owned_authority(Some(&owned()), &owned_record()));
    assert!(bookmark_authority(
        Some(&bookmark()),
        &granted_record(),
        &bookmark_bytes(&digest('b'))
    ));
    assert!(granted_authority(
        Some(&granted()),
        &granted_record(),
        &bookmark()
    ));
    assert!(legacy_authority(Some(&legacy()), &legacy_record()));
}

/// The shape is exact: an authority carrying one key more, or one key less,
/// than the rule names is not that authority.
#[test]
fn every_shape_is_exact() {
    for (name, authority, record) in [
        ("owned", owned(), owned_record()),
        ("bookmark", bookmark(), granted_record()),
        ("granted", granted(), granted_record()),
        ("legacy", legacy(), legacy_record()),
    ] {
        let check = |candidate: &Value, record: &Value| match name {
            "owned" => owned_authority(Some(candidate), record),
            "bookmark" => {
                bookmark_authority(Some(candidate), record, &bookmark_bytes(&digest('b')))
            }
            "granted" => granted_authority(Some(candidate), record, &bookmark()),
            _ => legacy_authority(Some(candidate), record),
        };
        assert!(check(&authority, &record), "{name} baseline");
        let mut extra = authority.clone();
        extra["extra"] = json!(1);
        assert!(!check(&extra, &record), "{name} with an extra key");
        for key in authority.as_object().expect("object").keys() {
            let mut short = authority.clone();
            short.as_object_mut().expect("object").remove(key);
            assert!(!check(&short, &record), "{name} without {key}");
        }
    }
}

/// An authority names the workspace and binding it belongs to, and a
/// well-formed authority for one root must not read as an authority for
/// another.
#[test]
fn an_authority_cannot_be_moved_to_another_record() {
    for (name, authority, record, keys) in [
        (
            "owned",
            owned(),
            owned_record(),
            vec![
                ("workspace_id", json!(OTHER)),
                ("binding_revision", json!(4)),
            ],
        ),
        (
            "bookmark",
            bookmark(),
            granted_record(),
            vec![
                ("workspace_id", json!(OTHER)),
                ("binding_revision", json!(6)),
            ],
        ),
        (
            "granted",
            granted(),
            granted_record(),
            vec![
                ("workspace_id", json!(OTHER)),
                ("binding_revision", json!(6)),
            ],
        ),
        (
            "legacy",
            legacy(),
            legacy_record(),
            vec![
                ("workspace_id", json!(OTHER)),
                ("binding_revision", json!(8)),
                ("legacy_project_id", json!(OTHER)),
                ("display_name", json!("Other")),
                ("created_at", json!(LATER)),
                ("last_opened_at", json!(STAMP)),
            ],
        ),
    ] {
        let check = |candidate: &Value, record: &Value| match name {
            "owned" => owned_authority(Some(candidate), record),
            "bookmark" => {
                bookmark_authority(Some(candidate), record, &bookmark_bytes(&digest('b')))
            }
            "granted" => granted_authority(Some(candidate), record, &bookmark()),
            _ => legacy_authority(Some(candidate), record),
        };
        for (key, value) in keys {
            let mut moved = record.clone();
            moved[key] = value;
            assert!(!check(&authority, &moved), "{name} moved by {key}");
        }
    }
}

/// The owned authority's digest is of the directory the *record* names, so an
/// authority cannot claim a folder the registry never bound.
#[test]
fn an_owned_authority_names_the_records_own_directory() {
    let mut record = owned_record();
    let authority = owned();
    assert!(owned_authority(Some(&authority), &record));
    record["owned_directory_name"] = json!("ws-somewhere-else");
    assert!(!owned_authority(Some(&authority), &record));
    // A record with no directory at all has no digest to match.
    record
        .as_object_mut()
        .expect("object")
        .remove("owned_directory_name");
    assert!(!owned_authority(Some(&authority), &record));
    record["owned_directory_name"] = json!(7);
    assert!(!owned_authority(Some(&authority), &record));
}

/// Device and inode are unsigned integer strings — canonical, in range, and
/// never a number. Tested against the rule directly: a non-canonical
/// identifier also breaks the fingerprint shape, so composing the two would
/// not show which one did the work.
#[test]
fn identifiers_are_canonical_unsigned_strings() {
    for good in ["0", "1", "16777232", &u64::MAX.to_string()] {
        assert!(unsigned_string(Some(&json!(good))), "{good}");
    }
    assert_eq!(u64::MAX.to_string().len(), 20);
    for bad in [
        json!("016777232"),
        json!(""),
        json!("-1"),
        json!("1.0"),
        json!(" 1"),
        json!("1 "),
        json!("+1"),
        json!("0x10"),
        json!("१"),
        json!(16_777_232),
        json!(true),
        // Twenty digits, but past what an unsigned 64-bit identifier holds.
        json!("18446744073709551616"),
        json!("99999999999999999999999"),
        json!(Value::Null),
    ] {
        assert!(!unsigned_string(Some(&bad)), "{bad}");
    }
    assert!(!unsigned_string(None));
    // Zero is a value an inode can report; only the legacy shape refuses it.
    assert!(unsigned_string(Some(&json!("0"))) && !positive_string(Some(&json!("0"))));
    assert!(positive_string(Some(&json!("1"))));
}

/// The legacy shape's six device/inode fields are *positive*: zero names
/// nothing, and a legacy root that reports it is not verifiable.
#[test]
fn legacy_identifiers_reject_zero() {
    let record = legacy_record();
    for key in [
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        let mut authority = legacy();
        authority[key] = json!("0");
        let resealed = sealed(authority, &record);
        assert!(!legacy_authority(Some(&resealed), &record), "{key} = 0");
    }
}

/// The host decodes the bookmark; the rule is that the claimed digest is the
/// digest of what decoded, and that what decoded fits the cap.
#[test]
fn a_bookmark_must_match_the_bytes_the_host_decoded() {
    let record = granted_record();
    let authority = bookmark();
    assert!(bookmark_authority(
        Some(&authority),
        &record,
        &bookmark_bytes(&digest('b'))
    ));
    // Base64 that did not decode is not a bookmark.
    assert!(!bookmark_authority(
        Some(&authority),
        &record,
        &BookmarkBytes {
            sha256: None,
            length: 8
        }
    ));
    // A digest that is not the bytes' digest is someone else's bookmark.
    assert!(!bookmark_authority(
        Some(&authority),
        &record,
        &bookmark_bytes(&digest('c'))
    ));
    // The cap is inclusive.
    assert!(bookmark_authority(
        Some(&authority),
        &record,
        &BookmarkBytes {
            sha256: Some(&digest('b')),
            length: MAX_BOOKMARK_BYTES
        }
    ));
    assert!(!bookmark_authority(
        Some(&authority),
        &record,
        &BookmarkBytes {
            sha256: Some(&digest('b')),
            length: MAX_BOOKMARK_BYTES + 1
        }
    ));
    assert_eq!(MAX_BOOKMARK_BYTES, 262_144);
}

/// The granted authority carries the bookmark's digest rather than the
/// bookmark. The two halves have to name the same bookmark.
#[test]
fn a_granted_authority_is_tied_to_its_bookmark() {
    let record = granted_record();
    assert!(granted_authority(Some(&granted()), &record, &bookmark()));
    let mut other = bookmark();
    other["bookmark_sha256"] = json!(digest('c'));
    assert!(!granted_authority(Some(&granted()), &record, &other));
    // A bookmark with no digest at all cannot stand in for one.
    other
        .as_object_mut()
        .expect("object")
        .remove("bookmark_sha256");
    assert!(!granted_authority(Some(&granted()), &record, &other));
    assert!(!granted_authority(Some(&granted()), &record, &Value::Null));
}

/// Every shape that carries a fingerprint ends in it: an authority whose
/// contents have been edited no longer matches the fingerprint it was sealed
/// with, whatever else still lines up.
#[test]
fn an_edited_authority_loses_its_fingerprint() {
    for (name, authority, record, key, value) in [
        (
            "owned",
            owned(),
            owned_record(),
            "device_id",
            json!("16777233"),
        ),
        (
            "granted",
            granted(),
            granted_record(),
            "volume_identifier_sha256",
            json!(digest('e')),
        ),
        (
            "legacy",
            legacy(),
            legacy_record(),
            "project_metadata_sha256",
            json!(digest('3')),
        ),
    ] {
        let check = |candidate: &Value, record: &Value| match name {
            "owned" => owned_authority(Some(candidate), record),
            "granted" => granted_authority(Some(candidate), record, &bookmark()),
            _ => legacy_authority(Some(candidate), record),
        };
        assert!(check(&authority, &record), "{name} baseline");
        let mut edited = authority.clone();
        edited[key] = value;
        assert!(!check(&edited, &record), "{name} edited {key}");
        // And a fingerprint that is not a digest at all is not a fingerprint.
        let mut blank = authority.clone();
        blank["root_fingerprint_sha256"] = json!("not-a-digest");
        assert!(!check(&blank, &record), "{name} with a junk fingerprint");
    }
}

/// `schema_version` is the number 1. Not "1", not true, not 1.0 written as
/// something else — the stored bytes say 1.
#[test]
fn the_schema_version_is_the_number_one() {
    let record = owned_record();
    for bad in [json!("1"), json!(true), json!(2), json!(Value::Null)] {
        let mut authority = owned();
        authority["schema_version"] = bad.clone();
        let resealed = sealed(authority, &record);
        assert!(!owned_authority(Some(&resealed), &record), "{bad}");
    }
}

/// Timestamps and digests are the canonical spellings the registry writes.
#[test]
fn timestamps_and_digests_are_canonical() {
    let record = owned_record();
    for bad in [
        json!("2026-02-03T04:05:06Z"),
        json!("2026-02-03 04:05:06.789Z"),
        json!("2026-02-03T04:05:06.789+00:00"),
        json!(0),
        json!(Value::Null),
    ] {
        let mut authority = owned();
        authority["recorded_at"] = bad.clone();
        let resealed = sealed(authority, &record);
        assert!(!owned_authority(Some(&resealed), &record), "{bad}");
    }
    // `classified_at` is not part of the fingerprint input, so this is the
    // authority's own timestamp check being exercised, not the seal's.
    let granted_record = granted_record();
    for bad in [json!("2026-02-03T04:05:06Z"), json!(0), json!(Value::Null)] {
        let mut authority = granted();
        authority["classified_at"] = bad.clone();
        let resealed = sealed(authority, &granted_record);
        assert!(
            !granted_authority(Some(&resealed), &granted_record, &bookmark()),
            "{bad}"
        );
    }
    // Digests are lowercase hex of exactly the right width.
    for bad in [json!(digest('A')), json!("abc"), json!(0)] {
        let mut authority = bookmark();
        authority["bookmark_sha256"] = bad.clone();
        assert!(
            !bookmark_authority(
                Some(&authority),
                &granted_record,
                &bookmark_bytes(bad.as_str().unwrap_or(""))
            ),
            "{bad}"
        );
    }
}

/// The legacy authority restates the record's capability list, and it must be
/// the canonical one.
#[test]
fn legacy_capabilities_are_the_canonical_list() {
    let record = legacy_record();
    for bad in [
        json!(["write", "read"]),
        json!(["read", "read"]),
        json!(["read", "launch"]),
        json!("read"),
        json!(Value::Null),
    ] {
        let mut authority = legacy();
        authority["capabilities"] = bad.clone();
        let resealed = sealed(authority, &record);
        assert!(!legacy_authority(Some(&resealed), &record), "{bad}");
    }
}

/// Nothing that is not a dictionary is an authority.
#[test]
fn a_non_object_is_never_an_authority() {
    let record = owned_record();
    for value in [
        None,
        Some(&Value::Null),
        Some(&json!([])),
        Some(&json!("x")),
    ] {
        assert!(!owned_authority(value, &record));
        assert!(!legacy_authority(value, &legacy_record()));
        assert!(!granted_authority(value, &granted_record(), &bookmark()));
        assert!(!bookmark_authority(
            value,
            &granted_record(),
            &bookmark_bytes(&digest('b'))
        ));
    }
}

/// The reducer answers every op it claims to, and refuses the ones it does
/// not. A reply of `{"ok":false}` means the host keeps its own answer, so an
/// op that silently fell through would look like a rejection everywhere.
#[test]
fn the_reducer_answers_every_op_it_claims_to() {
    let cases = [
        (
            "owned",
            json!({ "op": "owned", "authority": owned(), "record": owned_record() }),
        ),
        (
            "bookmark",
            json!({
                "op": "bookmark", "authority": bookmark(), "record": granted_record(),
                "bookmark_bytes_sha256": digest('b'), "bookmark_bytes_length": 8,
            }),
        ),
        (
            "granted",
            json!({
                "op": "granted", "authority": granted(), "record": granted_record(),
                "bookmark_authority": bookmark(),
            }),
        ),
        (
            "legacy",
            json!({ "op": "legacy", "authority": legacy(), "record": legacy_record() }),
        ),
    ];
    for (name, envelope) in &cases {
        let reply: Value = serde_json::from_str(&reduce_json(&envelope.to_string())).expect("json");
        assert_eq!(reply, json!({ "ok": true, "valid": true }), "{name}");
    }
    // An unknown op, a missing record and malformed input are all refusals,
    // never a silent `valid: false`.
    for input in [
        json!({ "op": "unknown", "authority": owned(), "record": owned_record() }).to_string(),
        json!({ "op": "owned", "authority": owned() }).to_string(),
        json!({ "authority": owned(), "record": owned_record() }).to_string(),
        "not json".to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
    // A bookmark envelope with no host-observed length is not a bookmark that
    // happens to fit; it is one the host never decoded.
    let reply = reduce_json(
        &json!({
            "op": "bookmark", "authority": bookmark(), "record": granted_record(),
            "bookmark_bytes_sha256": digest('b'),
        })
        .to_string(),
    );
    assert_eq!(reply, r#"{"ok":true,"valid":false}"#);
}

/// Foundation's `isEqual:` compares two `NSNumber`s by value, so an authority
/// whose binding revision was written `3.0` still names binding 3. A boolean
/// is not a revision, however much `NSNumber` says `@YES` equals `@1`.
#[test]
fn a_revision_is_compared_by_value() {
    let record = owned_record();
    let mut wide = owned();
    wide["binding_revision"] = json!(3.0);
    assert!(owned_authority(Some(&wide), &record));
    for bad in [json!(true), json!("3"), json!(4), json!(Value::Null)] {
        let mut authority = owned();
        authority["binding_revision"] = bad.clone();
        assert!(!owned_authority(Some(&authority), &record), "{bad}");
    }
}

// MARK: - migration

/// The pre-fingerprint form of a sealed authority: the same object, minus the
/// one key that did not exist when it was written.
fn unsealed(authority: &Value) -> Value {
    let mut map = authority.as_object().expect("object").clone();
    map.remove("root_fingerprint_sha256");
    Value::Object(map)
}

/// What the host re-read from the project on disk. Its metadata digest is the
/// authority's own `root_identity_sha256`: the caller only reaches the
/// migration once the evidence it found agrees with what the authority claims,
/// and the rule re-checks that rather than taking the caller's word.
fn physical_identity() -> Value {
    json!({
        "project_metadata_sha256": digest('1'),
        "projects_root_device_id": "16777232",
        "projects_root_inode_id": "11",
        "repository_device_id": "16777232",
        "repository_inode_id": "22",
        "git_device_id": "16777232",
        "git_inode_id": "33",
    })
}

/// Upgrading is sealing: the contents are untouched and the fingerprint they
/// imply is added. So a migrated authority is exactly the one the validator
/// already accepts — which is the only reason upgrading is safe at all.
#[test]
fn migrating_an_authority_produces_one_the_validator_accepts() {
    let record = owned_record();
    let migrated = owned_migration(Some(&unsealed(&owned())), &record).expect("migrated");
    assert_eq!(migrated, owned());
    assert!(owned_authority(Some(&migrated), &record));

    let granted_record = granted_record();
    let migrated = granted_migration(Some(&unsealed(&granted())), &granted_record, &bookmark())
        .expect("migrated");
    assert_eq!(migrated, granted());
    assert!(granted_authority(
        Some(&migrated),
        &granted_record,
        &bookmark()
    ));
}

/// The legacy migration folds in what the host re-read from disk before
/// sealing, because the fingerprint is taken over all three device/inode
/// pairs. The result validates once its capabilities are added.
#[test]
fn a_legacy_migration_folds_in_the_physical_identity_before_sealing() {
    let record = legacy_record();
    let mut bare = unsealed(&legacy());
    let map = bare.as_object_mut().expect("object");
    for key in [
        "capabilities",
        "project_metadata_sha256",
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        map.remove(key);
    }
    let migrated =
        legacy_migration(Some(&bare), &record, Some(&physical_identity())).expect("migrated");
    assert_eq!(migrated["git_inode_id"], json!("33"));
    assert_eq!(migrated["project_metadata_sha256"], json!(digest('1')));
    // Not yet valid: the capability list is added by the caller afterwards.
    assert!(!legacy_authority(Some(&migrated), &record));
    let mut whole = migrated.clone();
    whole["capabilities"] = json!(ordered_capabilities(&[
        "git".to_string(),
        "read".to_string(),
        "write".to_string()
    ]));
    assert!(legacy_authority(Some(&whole), &record));
}

/// The legacy fingerprint folds in no authority digest, so adding the
/// capability list after sealing does not disturb the seal. That is load
/// bearing — the caller relies on it — and it is also the honest limit of a
/// legacy fingerprint: it covers the identity, not the whole object.
#[test]
fn a_legacy_seal_survives_a_later_capability_list() {
    let record = legacy_record();
    let sealed = legacy();
    assert!(legacy_authority(Some(&sealed), &record));
    for capabilities in [
        json!(["read"]),
        json!(["read", "write"]),
        json!(["read", "write", "git", "project_context"]),
    ] {
        let mut changed = sealed.clone();
        changed["capabilities"] = capabilities.clone();
        assert!(legacy_authority(Some(&changed), &record), "{capabilities}");
    }
    // The owned shape does fold in its digest, so it does not behave this way.
    let owned_record = owned_record();
    let mut tampered = owned();
    tampered["recorded_at"] = json!(LATER);
    assert!(!owned_authority(Some(&tampered), &owned_record));
}

/// The migration checks a legacy authority's timestamps are canonical but does
/// not require them to be the record's, while the validator does. So an old
/// authority whose timestamps have drifted upgrades into one that still fails
/// to validate. This is the original's behaviour, named rather than quietly
/// changed: the upgrade never invents agreement it did not find.
#[test]
fn a_migrated_legacy_authority_can_still_fail_to_validate() {
    let record = legacy_record();
    let mut bare = unsealed(&legacy());
    let map = bare.as_object_mut().expect("object");
    for key in [
        "capabilities",
        "project_metadata_sha256",
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        map.remove(key);
    }
    bare["created_at"] = json!(LATER);
    let migrated =
        legacy_migration(Some(&bare), &record, Some(&physical_identity())).expect("migrated");
    let mut whole = migrated.clone();
    whole["capabilities"] = json!(["read"]);
    assert_eq!(whole["created_at"], json!(LATER));
    assert!(!legacy_authority(Some(&whole), &record));
}

/// An authority that already carries a fingerprint is not a pre-fingerprint
/// authority, and re-sealing one would let a broken seal be repaired into a
/// working one. The shape is exact, so it is refused.
#[test]
fn an_already_sealed_authority_is_not_migrated() {
    assert!(owned_migration(Some(&owned()), &owned_record()).is_none());
    assert!(granted_migration(Some(&granted()), &granted_record(), &bookmark()).is_none());
    assert!(legacy_migration(
        Some(&legacy()),
        &legacy_record(),
        Some(&physical_identity())
    )
    .is_none());
    // And a broken one stays broken rather than being resealed.
    let mut broken = owned();
    broken["root_fingerprint_sha256"] = json!(digest('9'));
    assert!(!owned_authority(Some(&broken), &owned_record()));
    assert!(owned_migration(Some(&broken), &owned_record()).is_none());
}

/// A migration checks everything the validator checks, less the fingerprint.
/// An authority that would not validate once sealed is not upgraded.
#[test]
fn a_migration_refuses_what_the_validator_would_refuse() {
    let record = owned_record();
    let bare = unsealed(&owned());
    assert!(owned_migration(Some(&bare), &record).is_some());
    for (key, value) in [
        ("schema_version", json!(2)),
        ("workspace_id", json!(OTHER)),
        ("binding_revision", json!(4)),
        ("device_id", json!("0x10")),
        ("inode_id", json!(7)),
        ("directory_name_sha256", json!(digest('a'))),
        ("recorded_at", json!("2026-02-03T04:05:06Z")),
    ] {
        let mut broken = bare.clone();
        broken[key] = value;
        assert!(owned_migration(Some(&broken), &record).is_none(), "{key}");
    }
    // A record naming a different directory is a different root.
    let mut moved = record.clone();
    moved["owned_directory_name"] = json!("elsewhere");
    assert!(owned_migration(Some(&bare), &moved).is_none());
}

/// The physical identity is what the host re-read from the project on disk. It
/// has to be about the same project the authority names, and every identifier
/// has to be positive — a legacy root reporting device or inode zero names
/// nothing.
#[test]
fn a_physical_identity_is_about_the_authoritys_own_project() {
    let expected = json!(digest('1'));
    assert!(legacy_physical_identity(
        Some(&physical_identity()),
        Some(&expected)
    ));
    // A different project's metadata is a different project.
    assert!(!legacy_physical_identity(
        Some(&physical_identity()),
        Some(&json!(digest('3')))
    ));
    assert!(!legacy_physical_identity(Some(&physical_identity()), None));
    for key in [
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        let mut zeroed = physical_identity();
        zeroed[key] = json!("0");
        assert!(
            !legacy_physical_identity(Some(&zeroed), Some(&expected)),
            "{key}"
        );
    }
    // The shape is exact.
    let mut extra = physical_identity();
    extra["extra"] = json!(1);
    assert!(!legacy_physical_identity(Some(&extra), Some(&expected)));
    let mut short = physical_identity();
    short
        .as_object_mut()
        .expect("object")
        .remove("git_device_id");
    assert!(!legacy_physical_identity(Some(&short), Some(&expected)));
    assert!(!legacy_physical_identity(None, Some(&expected)));
    // A legacy migration with no identity at all has nothing to fold in.
    assert!(legacy_migration(Some(&unsealed(&legacy())), &legacy_record(), None).is_none());
}

/// Capabilities go in the one order a stored authority may spell them,
/// whatever order the host verified them in, and a name the host invented is
/// not a capability.
#[test]
fn verified_capabilities_are_put_in_the_stored_order() {
    let names = |items: &[&str]| items.iter().map(|s| (*s).to_string()).collect::<Vec<_>>();
    assert_eq!(
        ordered_capabilities(&names(&["project_context", "git", "read"])),
        names(&["read", "git", "project_context"])
    );
    assert_eq!(
        ordered_capabilities(&names(&["write", "write"])),
        names(&["write"])
    );
    assert_eq!(
        ordered_capabilities(&names(&["teleport"])),
        Vec::<String>::new()
    );
    assert_eq!(ordered_capabilities(&[]), Vec::<String>::new());
    // Whatever comes out is a list the record rule accepts.
    assert!(capabilities_array(Some(&json!(ordered_capabilities(
        &names(&["git", "project_context", "read", "write"])
    )))));
}

/// The migration ops answer with an authority, not a verdict, and the two
/// record-free ops are answered without demanding a record.
#[test]
fn the_reducer_answers_the_migration_ops_too() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    let reply = run(json!({
        "op": "owned_migration", "authority": unsealed(&owned()), "record": owned_record()
    }));
    assert_eq!(reply["ok"], json!(true));
    assert_eq!(reply["authority"], owned());
    // A refusal is a null authority, not `ok: false`: the envelope was one the
    // rule acts on, and its answer is "this cannot be upgraded".
    let reply = run(json!({
        "op": "owned_migration", "authority": owned(), "record": owned_record()
    }));
    assert_eq!(reply, json!({ "ok": true, "authority": Value::Null }));

    let reply = run(json!({
        "op": "granted_migration", "authority": unsealed(&granted()),
        "record": granted_record(), "bookmark_authority": bookmark(),
    }));
    assert_eq!(reply["authority"], granted());

    let reply = run(json!({
        "op": "legacy_physical_identity",
        "identity": physical_identity(), "expected_metadata_sha256": digest('1'),
    }));
    assert_eq!(reply, json!({ "ok": true, "valid": true }));

    let reply = run(json!({
        "op": "ordered_capabilities", "available": ["git", "read"]
    }));
    assert_eq!(
        reply,
        json!({ "ok": true, "capabilities": ["read", "git"] })
    );

    for input in [
        json!({ "op": "ordered_capabilities", "available": [1] }).to_string(),
        json!({ "op": "ordered_capabilities" }).to_string(),
        json!({ "op": "legacy_migration", "authority": unsealed(&legacy()) }).to_string(),
    ] {
        assert_eq!(reduce_json(&input), r#"{"ok":false}"#, "{input}");
    }
}

/// The migration insists the evidence is about the project the authority
/// names — the physical identity's metadata digest must be the authority's own
/// `root_identity_sha256`. The *validator* never compares those two, so a
/// stored legacy authority may carry different ones. Migration is the
/// narrower gate, and deliberately: it is the step that decides what a root is
/// worth, from evidence, rather than reading back what someone already wrote.
#[test]
fn a_migration_requires_the_evidence_to_be_about_this_project() {
    let record = legacy_record();
    let mut bare = unsealed(&legacy());
    let map = bare.as_object_mut().expect("object");
    for key in [
        "capabilities",
        "project_metadata_sha256",
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        map.remove(key);
    }
    assert!(legacy_migration(Some(&bare), &record, Some(&physical_identity())).is_some());
    let mut elsewhere = physical_identity();
    elsewhere["project_metadata_sha256"] = json!(digest('7'));
    assert!(legacy_migration(Some(&bare), &record, Some(&elsewhere)).is_none());
    // And the stored shape is wider than the migration's: this one validates
    // with the two digests disagreeing, because nothing re-reads the project
    // at validation time.
    assert_ne!(
        legacy()["root_identity_sha256"],
        legacy()["project_metadata_sha256"]
    );
    assert!(legacy_authority(Some(&legacy()), &record));
}

// MARK: - legacy evidence

fn evidence() -> Value {
    json!({
        "project_id": PROJECT,
        "display_name": "Rish",
        "metadata_sha256": digest('1'),
        "capabilities": ["git", "read"],
        "projects_root_device_id": "16777232",
        "projects_root_inode_id": "11",
        "repository_device_id": "16777232",
        "repository_inode_id": "22",
        "git_device_id": "16777232",
        "git_inode_id": "33",
    })
}

/// Evidence is about one project, and the caller says which. Evidence for a
/// different project is not weaker evidence; it is about something else.
#[test]
fn evidence_is_about_the_project_the_caller_asked_about() {
    let project = json!(PROJECT);
    assert!(legacy_evidence(
        Some(&evidence()),
        Some(&project),
        Some("rish")
    ));
    assert!(!legacy_evidence(
        Some(&evidence()),
        Some(&json!(OTHER)),
        Some("rish")
    ));
    assert!(!legacy_evidence(Some(&evidence()), None, Some("rish")));
    // A display name is a display name, folded by the host as everywhere else.
    assert!(!legacy_evidence(Some(&evidence()), Some(&project), None));
    let mut reserved = evidence();
    reserved["display_name"] = json!("Rish Workspaces");
    assert!(!legacy_evidence(
        Some(&reserved),
        Some(&project),
        Some("rish workspaces")
    ));
    assert!(!legacy_evidence(None, Some(&project), Some("rish")));
}

#[test]
fn evidence_is_exact_and_every_identifier_is_positive() {
    let project = json!(PROJECT);
    let mut extra = evidence();
    extra["extra"] = json!(1);
    assert!(!legacy_evidence(Some(&extra), Some(&project), Some("rish")));
    for key in evidence().as_object().expect("object").keys() {
        let mut short = evidence();
        short.as_object_mut().expect("object").remove(key);
        assert!(
            !legacy_evidence(Some(&short), Some(&project), Some("rish")),
            "without {key}"
        );
    }
    for key in [
        "projects_root_device_id",
        "projects_root_inode_id",
        "repository_device_id",
        "repository_inode_id",
        "git_device_id",
        "git_inode_id",
    ] {
        for bad in [json!("0"), json!(11), json!("011"), json!(Value::Null)] {
            let mut broken = evidence();
            broken[key] = bad.clone();
            assert!(
                !legacy_evidence(Some(&broken), Some(&project), Some("rish")),
                "{key} = {bad}"
            );
        }
    }
    let mut digestless = evidence();
    digestless["metadata_sha256"] = json!("abc");
    assert!(!legacy_evidence(
        Some(&digestless),
        Some(&project),
        Some("rish")
    ));
}

/// Evidence carries a *set*, so the order it was collected in does not matter
/// — only that every member is a capability and none repeats. The stored
/// authority's list is the ordered one; that is what `ordered_capabilities` is
/// for, and the two are not the same rule.
#[test]
fn evidence_capabilities_are_a_set_not_a_list() {
    for good in [
        json!([]),
        json!(["read"]),
        json!(["project_context", "read"]),
        json!(["read", "write", "git", "project_context"]),
    ] {
        assert!(capabilities_set(Some(&good)), "{good}");
    }
    for bad in [
        json!(["read", "read"]),
        json!(["launch"]),
        json!([1]),
        json!("read"),
        json!(Value::Null),
    ] {
        assert!(!capabilities_set(Some(&bad)), "{bad}");
    }
    assert!(!capabilities_set(None));
    // Out of order is fine for a set and not for a stored list.
    let unordered = json!(["git", "read"]);
    assert!(capabilities_set(Some(&unordered)));
    assert!(!capabilities_array(Some(&unordered)));
}

/// **Device ids are deliberately not compared.** iOS renumbers the data volume
/// across reboots, so a persisted `st_dev` is not evidence about a directory:
/// comparing it would fail a perfectly good legacy root after a restart. The
/// three inodes, all reached from this app's own container, carry the identity.
#[test]
fn a_legacy_identity_is_matched_on_inodes_alone() {
    let authority = legacy();
    assert!(legacy_identity_matches_authority(
        Some(&evidence()),
        Some(&authority)
    ));
    // A renumbered volume does not break the match.
    let mut rebooted = evidence();
    for key in [
        "projects_root_device_id",
        "repository_device_id",
        "git_device_id",
    ] {
        rebooted[key] = json!("16777299");
    }
    assert!(legacy_identity_matches_authority(
        Some(&rebooted),
        Some(&authority)
    ));
    // A different inode is a different directory.
    for key in [
        "projects_root_inode_id",
        "repository_inode_id",
        "git_inode_id",
    ] {
        let mut moved = evidence();
        moved[key] = json!("99");
        assert!(
            !legacy_identity_matches_authority(Some(&moved), Some(&authority)),
            "{key}"
        );
        let mut absent = evidence();
        absent.as_object_mut().expect("object").remove(key);
        assert!(
            !legacy_identity_matches_authority(Some(&absent), Some(&authority)),
            "{key} absent"
        );
    }
    assert!(!legacy_identity_matches_authority(None, Some(&authority)));
    assert!(!legacy_identity_matches_authority(Some(&evidence()), None));
}

#[test]
fn the_reducer_answers_the_evidence_ops_too() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    assert_eq!(
        run(json!({
            "op": "legacy_evidence", "identity": evidence(),
            "expected_project_id": PROJECT, "folded_display_name": "rish",
        })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({ "op": "capabilities_set", "value": ["git", "read"] })),
        json!({ "ok": true, "valid": true })
    );
    assert_eq!(
        run(json!({
            "op": "legacy_identity_matches_authority",
            "identity": evidence(), "authority": legacy(),
        })),
        json!({ "ok": true, "matches": true })
    );
}

/// An open directory is the root an authority was sealed over when its inode
/// matches — and **only** its inode. iOS renumbers the data volume across
/// reboots, so comparing a persisted device id would fail a perfectly good
/// root after a restart.
#[test]
fn a_descriptor_is_matched_on_its_inode_alone() {
    let authority = owned();
    let inode = authority["inode_id"].clone();
    assert!(descriptor_matches_authority(
        Some(&authority),
        Some(&inode),
        true
    ));
    // A different directory.
    assert!(!descriptor_matches_authority(
        Some(&authority),
        Some(&json!("999")),
        true
    ));
    // Something that is not a directory is not this root, whatever its inode.
    assert!(!descriptor_matches_authority(
        Some(&authority),
        Some(&inode),
        false
    ));
    // The inode has to be the canonical spelling the authority holds, so a
    // number or a padded string is not a match rather than a lucky one.
    for bad in [
        json!(1234567),
        json!("01234567"),
        json!(""),
        json!(Value::Null),
    ] {
        assert!(
            !descriptor_matches_authority(Some(&authority), Some(&bad), true),
            "{bad}"
        );
    }
    assert!(!descriptor_matches_authority(Some(&authority), None, true));
    assert!(!descriptor_matches_authority(None, Some(&inode), true));
    // The device id is deliberately not consulted: an authority whose stored
    // device id no longer exists still matches its directory.
    let mut renumbered = owned();
    renumbered["device_id"] = json!("16777299");
    assert!(descriptor_matches_authority(
        Some(&renumbered),
        Some(&inode),
        true
    ));
}

#[test]
fn the_reducer_answers_the_descriptor_op() {
    let authority = owned();
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({
            "op": "descriptor_matches_authority",
            "authority": authority.clone(),
            "inode_id": authority["inode_id"].clone(),
            "is_directory": true,
        })
        .to_string(),
    ))
    .expect("reply");
    assert_eq!(reply, json!({ "ok": true, "matches": true }));
    // A host that did not say whether it is a directory has not matched.
    let reply = reduce_json(
        &json!({
            "op": "descriptor_matches_authority",
            "authority": authority.clone(),
            "inode_id": authority["inode_id"].clone(),
        })
        .to_string(),
    );
    assert_eq!(reply, r#"{"matches":false,"ok":true}"#);
}
