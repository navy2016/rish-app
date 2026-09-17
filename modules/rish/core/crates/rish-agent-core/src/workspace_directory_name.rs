//! What a workspace's own directory may be called, and what it is called when
//! the name it wants is taken.
//!
//! Ported from `DSHInternalComponent`,
//! `allocateOwnedDirectoryNameForDisplayName:` and
//! `DSHTruncateDisplayNameForSuffix` in `LocalWorkspaceAccess.mm`.
//!
//! **The loop stays with the host, the names do not.** Deciding whether a
//! candidate is taken needs the host's folding — Foundation folds case and
//! diacritics together under `en_US_POSIX`, and a JVM host folds differently —
//! so the host walks ordinals and asks what each one is called. What each
//! ordinal *is* called is the rule, and it lives here.
//!
//! **Truncation is a projection.** Foundation cuts on composed character
//! sequences, which are grapheme clusters, not scalars: cutting a name on a
//! scalar boundary would split a flag or an emoji with a skin tone into
//! halves. The host supplies the clusters; the core decides where the cut
//! falls.

use serde_json::{json, Map, Value};

use crate::workspace_record::MAX_DISPLAY_NAME_BYTES;
use crate::workspace_tool::path_control_or_format;

/// `NAME_MAX`. The same on Darwin and on Linux, so no host has to say.
pub const MAX_COMPONENT_BYTES: usize = 255;

/// `DSHInternalComponent`: what the registry will write as a single path
/// component of its own — a staging name, a directory name. Weaker than a
/// display name, because the registry's own names are not shown to anyone.
pub fn internal_component(value: Option<&Value>) -> bool {
    let Some(Value::String(name)) = value else {
        return false;
    };
    !name.is_empty()
        && name.len() <= MAX_COMPONENT_BYTES
        && !name.contains('/')
        && !name.contains('\\')
        && !name.contains('\0')
        && !name.chars().any(path_control_or_format)
        && name != "."
        && name != ".."
}

/// The suffix an occupied name gets. Ordinal 0 is the name itself.
pub fn suffix(ordinal: u64) -> String {
    format!(" ({ordinal})")
}

/// What the directory is called at this ordinal, given the display name's
/// grapheme clusters in order.
///
/// `None` when the suffix alone would not leave room for a name: at that point
/// there is nothing to truncate towards, and the host reports an invalid name
/// rather than inventing one.
pub fn candidate(graphemes: &[String], ordinal: u64) -> Option<String> {
    if ordinal == 0 {
        return Some(graphemes.concat());
    }
    let suffix = suffix(ordinal);
    if suffix.len() >= MAX_DISPLAY_NAME_BYTES {
        return None;
    }
    let budget = MAX_DISPLAY_NAME_BYTES - suffix.len();
    let mut prefix = String::new();
    for cluster in graphemes {
        // The whole cluster fits or none of it does. A half-written cluster is
        // a different character, not a shorter name.
        if prefix.len() + cluster.len() > budget {
            break;
        }
        prefix.push_str(cluster);
    }
    Some(prefix + &suffix)
}

fn clusters(value: Option<&Value>) -> Option<Vec<String>> {
    let items = value?.as_array()?;
    items
        .iter()
        .map(|item| item.as_str().map(str::to_owned))
        .collect()
}

fn text<'a>(envelope: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    envelope.get(key).and_then(Value::as_str)
}

/// One envelope in, one reply out; see
/// `rish_agent_workspace_directory_name_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let parsed: Value = serde_json::from_str(input).ok()?;
    let envelope = parsed.as_object()?;
    Some(match text(envelope, "op")? {
        "internal_component" => json!({
            "ok": true, "valid": internal_component(envelope.get("value"))
        }),
        "candidate" => {
            let graphemes = clusters(envelope.get("graphemes"))?;
            let ordinal = envelope.get("ordinal").and_then(Value::as_u64)?;
            json!({ "ok": true, "candidate": candidate(&graphemes, ordinal) })
        }
        _ => return None,
    })
}

#[cfg(test)]
#[path = "workspace_directory_name_tests.rs"]
mod tests;
