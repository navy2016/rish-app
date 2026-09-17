use super::*;

/// A stand-in for Foundation's case-and-diacritic fold, good enough for the
/// ASCII names these tests use. The real fold stays with the host.
fn fold(name: &str) -> String {
    name.to_lowercase()
}

fn record(origin: &str) -> Value {
    let mut value = json!({
        "schema_version": 1,
        "workspace_id": "a1b2c3d4-1111-4111-8111-1111abcd1111",
        "display_name": "Notes",
        "origin": origin,
        "root_locator_kind": "documents_owned",
        "location_class": "rish_owned",
        "owned_directory_name": "Notes",
        "legacy_project_id": Value::Null,
        "binding_revision": 3,
        "created_at": "2026-09-16T00:00:00.000Z",
        "last_opened_at": "2026-09-16T01:00:00.000Z",
    });
    match origin {
        "granted_folder" => {
            value["root_locator_kind"] = json!("security_scoped");
            value["location_class"] = json!("proven_local");
            value["owned_directory_name"] = Value::Null;
        }
        "legacy_app_owned" => {
            value["root_locator_kind"] = json!("legacy_app_owned");
            value["owned_directory_name"] = Value::Null;
            value["legacy_project_id"] = json!("b2c3d4e5-2222-4222-8222-2222abcd2222");
        }
        _ => {}
    }
    value
}

fn accepts(value: &Value) -> bool {
    let display = value.get("display_name").and_then(Value::as_str).map(fold);
    let directory = value
        .get("owned_directory_name")
        .and_then(Value::as_str)
        .map(fold);
    record_shape(Some(value), display.as_deref(), directory.as_deref())
}

#[test]
fn each_origin_has_a_well_formed_record() {
    for origin in [
        "rish_created",
        "imported",
        "granted_folder",
        "legacy_app_owned",
    ] {
        assert!(accepts(&record(origin)), "{origin}");
    }
}

/// The origin fixes the locator kind, the location class and which optional
/// identity is present. A record does not get to choose them separately.
#[test]
fn an_origin_cannot_borrow_another_origins_shape() {
    let mut owned = record("rish_created");
    owned["root_locator_kind"] = json!("security_scoped");
    assert!(!accepts(&owned), "owned with a granted locator");

    let mut owned = record("rish_created");
    owned["location_class"] = json!("proven_local");
    assert!(!accepts(&owned), "owned with a granted location class");

    let mut owned = record("rish_created");
    owned["legacy_project_id"] = json!("b2c3d4e5-2222-4222-8222-2222abcd2222");
    assert!(!accepts(&owned), "owned naming a legacy project");

    let mut granted = record("granted_folder");
    granted["owned_directory_name"] = json!("Notes");
    assert!(!accepts(&granted), "granted naming an owned directory");

    let mut legacy = record("legacy_app_owned");
    legacy["legacy_project_id"] = Value::Null;
    assert!(!accepts(&legacy), "legacy naming no project");

    let mut unknown = record("rish_created");
    unknown["origin"] = json!("somewhere_else");
    assert!(!accepts(&unknown), "an origin the rule does not know");
}

#[test]
fn the_eleven_keys_are_exact() {
    for key in [
        "schema_version",
        "workspace_id",
        "display_name",
        "origin",
        "root_locator_kind",
        "location_class",
        "owned_directory_name",
        "legacy_project_id",
        "binding_revision",
        "created_at",
        "last_opened_at",
    ] {
        let mut missing = record("rish_created");
        missing.as_object_mut().expect("object").remove(key);
        assert!(!accepts(&missing), "missing {key}");
    }
    let mut extra = record("rish_created");
    extra["path"] = json!("/tmp");
    assert!(!accepts(&extra), "a twelfth key");
}

/// A display name is one folder's one name: no padding, no leading dot, no
/// path separators, no controls, and not the container's own directory.
#[test]
fn a_display_name_is_one_name_for_one_folder() {
    let ok = |name: &str| display_name(Some(&json!(name)), Some(&fold(name)));
    for good in ["Notes", "My Work", "a", "Ümlaut", "项目"] {
        assert!(ok(good), "{good}");
    }
    for bad in [
        "",
        " Notes",
        "Notes ",
        "\tNotes",
        ".hidden",
        ".",
        "..",
        "a/b",
        "a\\b",
        "a:b",
        "a\u{0}b",
        "a\u{1}b",
        "a\u{200b}b",
    ] {
        assert!(!ok(bad), "{bad:?}");
    }
    // Past the byte bound, counted in UTF-8 bytes rather than characters.
    assert!(ok(&"a".repeat(MAX_DISPLAY_NAME_BYTES)));
    assert!(!ok(&"a".repeat(MAX_DISPLAY_NAME_BYTES + 1)));
    assert!(!ok(&"é".repeat(MAX_DISPLAY_NAME_BYTES / 2 + 1)));
    // A decomposed name is a second spelling of the same name.
    assert!(!display_name(
        Some(&json!("cafe\u{301}")),
        Some("cafe\u{301}")
    ));
}

/// The container's own directory and the private prefix are reserved, and the
/// check is on the folded spelling so case and diacritics cannot dodge it.
#[test]
fn the_containers_own_names_are_reserved() {
    for reserved in ["Rish Workspaces", "RISH WORKSPACES", "rish workspaces"] {
        assert!(
            !display_name(Some(&json!(reserved)), Some("rish workspaces")),
            "{reserved}"
        );
    }
    // A host that could not fold refuses rather than guessing.
    assert!(!display_name(Some(&json!("Notes")), None));
}

/// One capability set has one spelling, so a stored record digests the same
/// everywhere.
#[test]
fn a_capability_array_is_ordered_and_without_repeats() {
    for good in [
        json!([]),
        json!(["read"]),
        json!(["read", "write"]),
        json!(["read", "write", "git", "project_context"]),
        json!(["write", "project_context"]),
    ] {
        assert!(capabilities_array(Some(&good)), "{good}");
    }
    for bad in [
        json!(["write", "read"]),
        json!(["read", "read"]),
        json!(["read", "teleport"]),
        json!(["read", "write", "git", "project_context", "read"]),
        json!([1]),
        json!("read"),
    ] {
        assert!(!capabilities_array(Some(&bad)), "{bad}");
    }
}

/// A revision advances by exactly one: a gap would let two rebinds look like
/// one, and a repeat would let a stale authority pass as current.
#[test]
fn a_binding_revision_advances_by_exactly_one() {
    assert_eq!(
        binding_revision_advance(Some(&json!(3)), Some(&json!(4))),
        Advance::Ok
    );
    assert_eq!(
        binding_revision_advance(Some(&json!(3)), Some(&json!(5))),
        Advance::Conflict
    );
    assert_eq!(
        binding_revision_advance(Some(&json!(3)), Some(&json!(3))),
        Advance::Conflict
    );
    assert_eq!(
        binding_revision_advance(Some(&json!(0)), Some(&json!(1))),
        Advance::Invalid,
        "a revision starts at one"
    );
    assert_eq!(
        binding_revision_advance(Some(&json!("3")), Some(&json!(4))),
        Advance::Invalid
    );
    // At the top of the safe range a binding can never be rebound again, and
    // that is a different answer from a conflict.
    assert_eq!(
        binding_revision_advance(
            Some(&json!(MAX_SAFE_INTEGER)),
            Some(&json!(MAX_SAFE_INTEGER))
        ),
        Advance::Overflow
    );
}

#[test]
fn the_reducer_answers_its_ops() {
    let run = |value: Value| -> Value {
        serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
    };
    let value = record("rish_created");
    let reply = run(json!({
        "op": "record_shape", "record": value,
        "folded_display_name": "notes", "folded_directory_name": "notes",
    }));
    assert_eq!(reply["valid"], json!(true));
    assert_eq!(
        run(json!({ "op": "capabilities_array", "value": ["write", "read"] }))["valid"],
        json!(false)
    );
    assert_eq!(
        run(json!({ "op": "binding_revision_advance", "current": 3, "proposed": 4 }))["outcome"],
        json!("ok")
    );
    assert_eq!(run(json!({ "op": "teleport" }))["ok"], json!(false));
}

// MARK: - the registry file

fn owned(id: &str, directory: &str) -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": id,
        "display_name": directory,
        "origin": "rish_created",
        "root_locator_kind": "documents_owned",
        "location_class": "rish_owned",
        "owned_directory_name": directory,
        "legacy_project_id": Value::Null,
        "binding_revision": 1,
        "created_at": "2026-02-03T04:05:06.789Z",
        "last_opened_at": "2026-02-03T04:05:06.789Z",
    })
}

fn granted(id: &str) -> Value {
    json!({
        "schema_version": 1,
        "workspace_id": id,
        "display_name": "Folder",
        "origin": "granted_folder",
        "root_locator_kind": "security_scoped",
        "location_class": "proven_local",
        "owned_directory_name": Value::Null,
        "legacy_project_id": Value::Null,
        "binding_revision": 1,
        "created_at": "2026-02-03T04:05:06.789Z",
        "last_opened_at": "2026-02-03T04:05:06.789Z",
    })
}

fn folded_for(records: &[Value]) -> Vec<Value> {
    records
        .iter()
        .map(|record| {
            let lower = |key: &str| {
                record
                    .get(key)
                    .and_then(Value::as_str)
                    .map(str::to_lowercase)
            };
            json!({
                "display_name": lower("display_name"),
                "directory_name": lower("owned_directory_name"),
            })
        })
        .collect()
}

fn folded(records: &[Value]) -> Vec<FoldedRecord<'_>> {
    // Borrowed from a leaked vector so the test reads like the host's call.
    let owned: &'static Vec<Value> = Box::leak(Box::new(folded_for(records)));
    owned
        .iter()
        .map(|item| FoldedRecord {
            display_name: item.get("display_name").and_then(Value::as_str),
            directory_name: item.get("directory_name").and_then(Value::as_str),
        })
        .collect()
}

fn registry(records: Vec<Value>) -> Value {
    json!({ "schema_version": 1, "generation": 1, "records": records })
}

const ID_A: &str = "a1b2c3d4-1111-4111-8111-1111abcd1111";
const ID_B: &str = "b2c3d4e5-2222-4222-8222-2222abcd2222";

#[test]
fn a_registry_accepts_what_the_store_writes() {
    let records = vec![owned(ID_A, "Alpha"), granted(ID_B)];
    assert!(registry_shape(
        Some(&registry(records.clone())),
        &folded(&records)
    ));
    // Empty is a registry: a fresh install has one.
    assert!(registry_shape(Some(&registry(vec![])), &[]));
    let mut zero = registry(vec![]);
    zero["generation"] = json!(0);
    assert!(registry_shape(Some(&zero), &[]));
}

/// Workspace ids are strictly ascending, not merely unique. The registry's
/// canonical JSON is what `previous_registry_sha256` is taken over, so the
/// same records in a different order digest differently and every journal
/// written against one would be unrecoverable against the other.
#[test]
fn registry_records_are_sorted_by_workspace_id() {
    let sorted = vec![owned(ID_A, "Alpha"), owned(ID_B, "Beta")];
    assert!(registry_shape(
        Some(&registry(sorted.clone())),
        &folded(&sorted)
    ));
    let reversed = vec![owned(ID_B, "Beta"), owned(ID_A, "Alpha")];
    assert!(!registry_shape(
        Some(&registry(reversed.clone())),
        &folded(&reversed)
    ));
    // The same id twice is neither ascending nor unique.
    let twice = vec![owned(ID_A, "Alpha"), owned(ID_A, "Beta")];
    assert!(!registry_shape(
        Some(&registry(twice.clone())),
        &folded(&twice)
    ));
}

/// Two workspaces whose folders differ only by case or accent are one folder
/// on this filesystem, and the second would silently write into the first.
#[test]
fn no_two_records_share_a_folded_directory_name() {
    let records = vec![owned(ID_A, "Alpha"), owned(ID_B, "ALPHA")];
    assert!(!registry_shape(
        Some(&registry(records.clone())),
        &folded(&records)
    ));
    // Records with no owned directory occupy no name, however many there are.
    let none = vec![granted(ID_A), granted(ID_B)];
    assert!(registry_shape(
        Some(&registry(none.clone())),
        &folded(&none)
    ));
}

#[test]
fn a_registry_is_bounded_and_exactly_shaped() {
    for bad in [
        json!({ "generation": 1, "records": [] }),
        json!({ "schema_version": 2, "generation": 1, "records": [] }),
        json!({ "schema_version": 1, "generation": -1, "records": [] }),
        json!({ "schema_version": 1, "generation": 1, "records": {} }),
        json!({ "schema_version": 1, "generation": 1, "records": [], "extra": 1 }),
    ] {
        assert!(!registry_shape(Some(&bad), &[]), "{bad}");
    }
    assert!(!registry_shape(None, &[]));
    // A record the rule refuses takes the whole registry with it. The folding
    // is taken from the sound record, so it is the *record* being refused and
    // not a missing folding.
    let sound = vec![owned(ID_A, "Alpha")];
    let foldings = folded(&sound);
    let mut broken = sound.clone();
    broken[0]["origin"] = json!("elsewhere");
    assert!(!registry_shape(Some(&registry(broken)), &foldings));
    // The host must fold every record; a short list is not a registry it has
    // judged, so it is refused rather than judged halfway.
    let records = vec![owned(ID_A, "Alpha"), owned(ID_B, "Beta")];
    assert!(!registry_shape(Some(&registry(records)), &[]));
    // The bound is real and inclusive. Asserting the constant's value proves
    // nothing on its own — removing the check left this test green until a
    // registry of the actual size was built.
    let full: Vec<Value> = (0..MAX_RECORDS)
        .map(|index| {
            owned(
                &format!("{index:08x}-1111-4111-8111-1111abcd1111"),
                &format!("Alpha {index}"),
            )
        })
        .collect();
    assert!(registry_shape(
        Some(&registry(full.clone())),
        &folded(&full)
    ));
    let mut over = full;
    over.push(owned(
        &format!("{:08x}-1111-4111-8111-1111abcd1111", MAX_RECORDS),
        &format!("Alpha {MAX_RECORDS}"),
    ));
    assert!(!registry_shape(
        Some(&registry(over.clone())),
        &folded(&over)
    ));
    assert_eq!(MAX_RECORDS, 1024);
}

/// A full registry refuses the operation rather than dropping a binding
/// somebody still uses.
#[test]
fn a_full_registry_has_no_room() {
    assert!(registry_has_room(Some(0)));
    assert!(registry_has_room(Some(MAX_RECORDS as u64 - 1)));
    assert!(!registry_has_room(Some(MAX_RECORDS as u64)));
    assert!(!registry_has_room(Some(MAX_RECORDS as u64 + 1)));
    assert!(!registry_has_room(None));
}

#[test]
fn a_layout_manifest_says_only_that_the_store_was_initialised() {
    assert!(layout_manifest_shape(Some(&json!({
        "schema_version": 1, "initialized_at": "2026-02-03T04:05:06.789Z"
    }))));
    for bad in [
        json!({ "schema_version": 1 }),
        json!({ "initialized_at": "2026-02-03T04:05:06.789Z" }),
        json!({ "schema_version": 2, "initialized_at": "2026-02-03T04:05:06.789Z" }),
        json!({ "schema_version": 1, "initialized_at": "2026-02-03T04:05:06Z" }),
        json!({
            "schema_version": 1, "initialized_at": "2026-02-03T04:05:06.789Z", "extra": 1
        }),
    ] {
        assert!(!layout_manifest_shape(Some(&bad)), "{bad}");
    }
    assert!(!layout_manifest_shape(None));
}

#[test]
fn the_reducer_answers_the_registry_ops() {
    let records = vec![owned(ID_A, "Alpha"), granted(ID_B)];
    let reply: Value = serde_json::from_str(&reduce_json(
        &json!({
            "op": "registry_shape",
            "registry": registry(records.clone()),
            "folded": folded_for(&records),
        })
        .to_string(),
    ))
    .expect("reply");
    assert_eq!(reply, json!({ "ok": true, "valid": true }));
    let reply = reduce_json(
        &json!({
            "op": "layout_manifest_shape",
            "manifest": { "schema_version": 1, "initialized_at": "2026-02-03T04:05:06.789Z" },
        })
        .to_string(),
    );
    assert_eq!(reply, r#"{"ok":true,"valid":true}"#);
    // No foldings at all is not an empty list of foldings.
    assert_eq!(
        reduce_json(&json!({ "op": "registry_shape", "registry": registry(vec![]) }).to_string()),
        r#"{"ok":false}"#
    );
}
