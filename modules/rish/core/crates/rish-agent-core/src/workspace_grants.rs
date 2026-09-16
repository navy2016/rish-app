//! What a stored workspace record is allowed to do, and how that is shown.
//!
//! Ported from `operationalCapabilitiesForMetadataRecord:authority:status:`,
//! `zeroCapabilitiesForRecord:` and `descriptorForRecord:status:capabilities:`
//! in `LocalWorkspaceAccess.mm`. Together with
//! `root_projection::capabilities_for_grants` this is the whole chain from a
//! stored record to what an agent may do with it: locator kind → grants →
//! Agent capabilities.
//!
//! *Deriving the status* stays with the host, because it resolves a
//! security-scoped bookmark, starts a scope and stats a directory — none of
//! which travels. What the status *means* is here.

use serde_json::{json, Map, Value};

/// The closed set a metadata status may take. Anything else is not a status
/// this rule knows how to read, and is treated as "not ok".
pub const STATUSES: &[&str] = &["ok", "unavailable", "revoked", "stale", "not_downloaded"];

/// The grants a workspace can hold. `files_visible` is not a grant a caller
/// exercises — it says the folder shows up in Files — but it travels in the
/// same projection.
pub const GRANTS: &[&str] = &["read", "write", "git", "project_context"];

/// `operationalCapabilitiesForMetadataRecord:authority:status:`.
///
/// `verified_legacy` is the host's answer for a legacy root: it has to re-read
/// the project metadata and compare physical identity before it can say, so it
/// passes the result in. `None` there means "could not verify", which is not
/// the same as "verified as nothing".
pub fn operational_grants(
    locator_kind: Option<&str>,
    status: Option<&str>,
    verified_legacy: Option<&[String]>,
) -> Vec<String> {
    if status != Some("ok") {
        return Vec::new();
    }
    let owned = |names: &[&str]| names.iter().map(|n| (*n).to_string()).collect();
    match locator_kind {
        // A documents-owned root is produced and verified natively, so it can
        // do everything.
        Some("documents_owned") => owned(&["read", "write", "git", "project_context"]),
        // A granted folder has no native coordinated Git, project-context or
        // Files producer. The advertised contract stays honest until those
        // consumers exist; coordinated read and write are real today.
        Some("security_scoped") => owned(&["read", "write"]),
        Some("legacy_app_owned") => verified_legacy.map(<[String]>::to_vec).unwrap_or_default(),
        _ => Vec::new(),
    }
}

/// `zeroCapabilitiesForRecord:`: every grant false, except that a
/// documents-owned folder is visible in Files whatever its status.
pub fn zero_capabilities(locator_kind: Option<&str>) -> Value {
    json!({
        "read": false,
        "write": false,
        "git": false,
        "project_context": false,
        "files_visible": locator_kind == Some("documents_owned"),
    })
}

/// `descriptorForRecord:status:capabilities:` — the shape a caller is shown.
///
/// A grant is only ever projected true when the status is `ok`, and only when
/// it is one of the four the projection knows: a grant the host invented
/// cannot appear here, and `files_visible` cannot be granted by a capability
/// list.
pub fn descriptor(record: &Value, status: &str, grants: &[String]) -> Value {
    let locator = record.get("root_locator_kind").and_then(Value::as_str);
    let mut capabilities = zero_capabilities(locator);
    if status == "ok" {
        let map = capabilities.as_object_mut().expect("object");
        for grant in grants {
            if GRANTS.contains(&grant.as_str()) {
                map.insert(grant.clone(), Value::Bool(true));
            }
        }
    }
    let field = |key: &str| record.get(key).cloned().unwrap_or(Value::Null);
    json!({
        "schema_version": 2,
        "workspace_id": field("workspace_id"),
        "display_name": field("display_name"),
        "origin": field("origin"),
        "status": status,
        "binding_revision": field("binding_revision"),
        "capabilities": capabilities,
        "created_at": field("created_at"),
        "last_opened_at": field("last_opened_at"),
    })
}

fn string_list(value: Option<&Value>) -> Option<Vec<String>> {
    let Value::Array(items) = value? else {
        return None;
    };
    items
        .iter()
        .map(|item| item.as_str().map(str::to_string))
        .collect()
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see `rish_agent_workspace_grants_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    match text(envelope, "op")? {
        "operational_grants" => {
            let verified = string_list(envelope.get("verified_legacy"));
            Some(json!({
                "ok": true,
                "grants": operational_grants(
                    text(envelope, "locator_kind"),
                    text(envelope, "status"),
                    verified.as_deref(),
                ),
            }))
        }
        "descriptor" => {
            let grants = string_list(envelope.get("grants")).unwrap_or_default();
            Some(json!({
                "ok": true,
                "descriptor": descriptor(
                    envelope.get("record")?,
                    text(envelope, "status")?,
                    &grants,
                ),
            }))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn grants(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| (*n).to_string()).collect()
    }

    /// Nothing is granted unless the status is exactly `ok`. Every other status
    /// in the closed set, and anything outside it, grants nothing.
    #[test]
    fn only_an_ok_status_grants_anything() {
        assert_eq!(
            operational_grants(Some("documents_owned"), Some("ok"), None),
            grants(&["read", "write", "git", "project_context"])
        );
        for status in [
            "unavailable",
            "revoked",
            "stale",
            "not_downloaded",
            "",
            "OK",
        ] {
            assert!(
                operational_grants(Some("documents_owned"), Some(status), None).is_empty(),
                "{status}"
            );
        }
        assert!(operational_grants(Some("documents_owned"), None, None).is_empty());
    }

    /// A granted folder has no native Git, project-context or Files producer,
    /// so it must not advertise them even though it is a perfectly good root.
    #[test]
    fn a_granted_folder_advertises_only_what_exists() {
        assert_eq!(
            operational_grants(Some("security_scoped"), Some("ok"), None),
            grants(&["read", "write"])
        );
    }

    /// A legacy root grants what the host could verify, and nothing when it
    /// could not — "unverified" is not "verified as nothing", but both end in
    /// no grants rather than a guess.
    #[test]
    fn a_legacy_root_grants_only_what_the_host_verified() {
        assert_eq!(
            operational_grants(
                Some("legacy_app_owned"),
                Some("ok"),
                Some(&grants(&["read", "git"]))
            ),
            grants(&["read", "git"])
        );
        assert!(operational_grants(Some("legacy_app_owned"), Some("ok"), None).is_empty());
        // An unknown locator kind grants nothing whatever the host says.
        assert!(
            operational_grants(Some("something_else"), Some("ok"), Some(&grants(&["read"])))
                .is_empty()
        );
    }

    /// `files_visible` describes the folder, not a grant, so it is true for a
    /// documents-owned root even when the root is unavailable — and it can
    /// never be turned on by a capability list.
    #[test]
    fn files_visibility_is_a_fact_about_the_folder_not_a_grant() {
        let record = json!({ "root_locator_kind": "documents_owned" });
        let unavailable = descriptor(&record, "unavailable", &grants(&["read", "write"]));
        assert_eq!(unavailable["capabilities"]["files_visible"], json!(true));
        assert_eq!(unavailable["capabilities"]["read"], json!(false));
        let granted = json!({ "root_locator_kind": "security_scoped" });
        let ok = descriptor(&granted, "ok", &grants(&["read", "files_visible"]));
        assert_eq!(ok["capabilities"]["read"], json!(true));
        assert_eq!(
            ok["capabilities"]["files_visible"],
            json!(false),
            "a capability list cannot make a granted folder visible in Files"
        );
    }

    /// A grant the host invented cannot appear in the projection.
    #[test]
    fn the_projection_has_exactly_five_capability_keys() {
        let record = json!({ "root_locator_kind": "documents_owned" });
        let projected = descriptor(&record, "ok", &grants(&["read", "teleport"]));
        let keys: Vec<&str> = projected["capabilities"]
            .as_object()
            .expect("object")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            vec!["files_visible", "git", "project_context", "read", "write"]
        );
    }

    #[test]
    fn the_descriptor_carries_the_records_own_identity() {
        let record = json!({
            "root_locator_kind": "documents_owned",
            "workspace_id": "a1b2c3d4-1111-4111-8111-1111abcd1111",
            "display_name": "Notes", "origin": "rish_created",
            "binding_revision": 3,
            "created_at": "2026-09-16T00:00:00.000Z",
            "last_opened_at": "2026-09-16T01:00:00.000Z",
            "root_fingerprint_sha256": "c".repeat(64),
        });
        let projected = descriptor(&record, "ok", &grants(&["read"]));
        assert_eq!(projected["schema_version"], json!(2));
        assert_eq!(projected["display_name"], json!("Notes"));
        assert_eq!(projected["binding_revision"], json!(3));
        // The fingerprint is authority, not a display fact.
        assert!(projected.get("root_fingerprint_sha256").is_none());
        let keys: Vec<&str> = projected
            .as_object()
            .expect("object")
            .keys()
            .map(String::as_str)
            .collect();
        assert_eq!(
            keys,
            vec![
                "binding_revision",
                "capabilities",
                "created_at",
                "display_name",
                "last_opened_at",
                "origin",
                "schema_version",
                "status",
                "workspace_id",
            ]
        );
    }

    #[test]
    fn the_reducer_answers_its_ops() {
        let run = |value: Value| -> Value {
            serde_json::from_str(&reduce_json(&value.to_string())).expect("reply")
        };
        let reply = run(json!({
            "op": "operational_grants", "locator_kind": "security_scoped", "status": "ok"
        }));
        assert_eq!(reply["grants"], json!(["read", "write"]));
        let reply = run(json!({
            "op": "descriptor", "status": "ok",
            "record": { "root_locator_kind": "documents_owned" },
            "grants": ["read", "git"],
        }));
        assert_eq!(reply["descriptor"]["capabilities"]["git"], json!(true));
        assert_eq!(run(json!({ "op": "teleport" }))["ok"], json!(false));
    }
}
