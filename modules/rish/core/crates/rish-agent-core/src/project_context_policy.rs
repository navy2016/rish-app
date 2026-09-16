//! chat-read-v1: which of a person's repository may be sent to a model.
//!
//! Ported from `decisionForRelativePath:` in `ProjectContextPolicy.mm`. This is
//! the highest-stakes table in the engine — a path that stops being recognised
//! as sensitive is a secret sent to a provider, not a formatting difference —
//! so the tables and the order they are consulted in live in one place.
//!
//! **Case folding stays with the host.** Foundation folds with
//! `CFStringFold(kCFCompareCaseInsensitive)`, which is Unicode case *folding*,
//! not lowercasing; Rust's `to_lowercase` is a different operation and the core
//! carries no folding table. So the host folds, exactly as it always did, and
//! passes the folded spellings in — the same shape as the `foundation-json-v1`
//! projection. Nothing about *which* folded names are sensitive moves with it.

use serde_json::{json, Value};
use unicode_normalization::UnicodeNormalization;

use crate::workspace_tool::path_control_or_format;

/// Foundation counts this bound in UTF-16 units.
pub const MAX_RELATIVE_PATH_UNITS: usize = 4096;
pub const MAX_DEPTH: usize = 24;

pub const REASON_SECRET_PATH: &str = "secret_path";
pub const REASON_GENERATED: &str = "generated";
pub const REASON_LOCKFILE: &str = "lockfile";
pub const REASON_BINARY: &str = "binary";
pub const REASON_POLICY: &str = "policy";

const SENSITIVE_DIRECTORIES: &[&str] = &[
    ".git", ".hg", ".svn", ".ssh", ".aws", ".gnupg", ".kube", ".docker", ".env", ".m2", "secret",
    "secrets",
];

const GENERATED_DIRECTORIES: &[&str] = &[
    "node_modules",
    "vendor",
    "pods",
    ".build",
    "build",
    "dist",
    "generated",
    "out",
    "target",
    "deriveddata",
    ".gradle",
    ".next",
    "coverage",
    "cache",
    "tmp",
];

const SENSITIVE_EXTENSIONS: &[&str] = &[
    "pem",
    "key",
    "p12",
    "pfx",
    "jks",
    "keystore",
    "mobileprovision",
];

const SENSITIVE_NAMES: &[&str] = &[
    "credential",
    "credentials",
    "id_ed25519",
    "id_rsa",
    "secret",
    "secrets",
];

/// A component whose name begins with one of these and a dot is sensitive
/// whatever follows: `credentials.json`, `secret.backup.txt`.
const SENSITIVE_DOTTED_PREFIXES: &[&str] = &["credential", "credentials", "secret", "secrets"];

const BINARY_EXTENSIONS: &[&str] = &[
    "7z", "a", "apk", "app", "avi", "bin", "bmp", "class", "db", "dmg", "doc", "docx", "dylib",
    "eot", "exe", "gif", "gz", "heic", "ico", "jar", "jpeg", "jpg", "mov", "mp3", "mp4", "o",
    "otf", "pdf", "png", "ppt", "pptx", "rar", "sqlite", "tar", "tgz", "ttf", "wav", "webm",
    "webp", "woff", "woff2", "pyc", "pyo", "wasm", "xls", "xlsx", "xz", "zip",
];

const ALLOWED_TEXT_EXTENSIONS: &[&str] = &[
    "adoc",
    "bash",
    "c",
    "cc",
    "cfg",
    "conf",
    "cpp",
    "cs",
    "css",
    "csv",
    "cxx",
    "dart",
    "entitlements",
    "fish",
    "gql",
    "go",
    "gradle",
    "graphql",
    "h",
    "hh",
    "hpp",
    "htm",
    "html",
    "hxx",
    "ini",
    "java",
    "js",
    "json",
    "jsonc",
    "jsx",
    "kt",
    "kts",
    "less",
    "lua",
    "m",
    "markdown",
    "md",
    "mm",
    "pbxproj",
    "php",
    "plist",
    "properties",
    "proto",
    "ps1",
    "py",
    "r",
    "rb",
    "rs",
    "rst",
    "sass",
    "scala",
    "scss",
    "sh",
    "sql",
    "storyboard",
    "strings",
    "swift",
    "tex",
    "toml",
    "ts",
    "tsv",
    "tsx",
    "txt",
    "xib",
    "xcconfig",
    "xml",
    "vue",
    "xsd",
    "yaml",
    "yml",
    "zsh",
];

const LOCKFILES: &[&str] = &[
    "bun.lockb",
    "composer.lock",
    "package-lock.json",
    "packages.lock.json",
    "npm-shrinkwrap.json",
    "pnpm-lock.yaml",
    "shrinkwrap.yaml",
    "uv.lock",
    "yarn.lock",
];

/// One path component as Foundation spelled it after folding: the component
/// itself, its path extension and its stem. The host supplies all three
/// because `pathExtension` and `stringByDeletingPathExtension` are Foundation
/// operations with their own edge cases (`a.` , `.hidden`, `a.b.c`).
pub struct Folded<'a> {
    pub folded: &'a str,
    pub extension: &'a str,
    pub stem: &'a str,
}

fn has_sensitive_dotted_prefix(folded: &str) -> bool {
    SENSITIVE_DOTTED_PREFIXES
        .iter()
        .any(|prefix| folded.starts_with(&format!("{prefix}.")))
}

/// `DSHIsSensitivePathComponent`.
fn sensitive_component(component: &Folded) -> bool {
    SENSITIVE_DIRECTORIES.contains(&component.folded)
        || component.folded.starts_with(".env")
        || SENSITIVE_EXTENSIONS.contains(&component.extension)
        || SENSITIVE_NAMES.contains(&component.folded)
        || SENSITIVE_NAMES.contains(&component.stem)
        || has_sensitive_dotted_prefix(component.folded)
}

/// `DSHIsSensitiveFilename`. Note it consults the *filename's* own stem, not
/// the component stem, and has no extension clause of its own — the caller
/// checks the extension separately.
fn sensitive_filename(filename: &Folded) -> bool {
    filename.folded.starts_with(".env")
        || SENSITIVE_NAMES.contains(&filename.folded)
        || SENSITIVE_NAMES.contains(&filename.stem)
        || has_sensitive_dotted_prefix(filename.folded)
}

fn lockfile(folded: &str) -> bool {
    folded.ends_with(".lock") || LOCKFILES.contains(&folded)
}

/// The few names worth sending even without a recognised text extension.
fn safe_basename(folded: &str) -> bool {
    folded.starts_with("readme")
        || folded.starts_with("license")
        || matches!(
            folded,
            "dockerfile" | "makefile" | "cargo.toml" | "package.json" | ".gitignore"
        )
}

/// `DSHRelativePathHasSafeStructure`, over the NFC-normalized path.
fn safe_structure(normalized: &str) -> bool {
    let units: Vec<u16> = normalized.encode_utf16().collect();
    let first = units.first().copied().unwrap_or(0);
    let ascii_letter = (b'A' as u16..=b'Z' as u16).contains(&first)
        || (b'a' as u16..=b'z' as u16).contains(&first);
    // `C:/…` and `C:\…` name a volume, not something inside this project.
    let absolute_windows = units.len() >= 3
        && ascii_letter
        && units[1] == u16::from(b':')
        && (units[2] == u16::from(b'/') || units[2] == u16::from(b'\\'));
    if normalized.is_empty()
        || normalized.starts_with('/')
        || normalized.starts_with("~/")
        || absolute_windows
        || normalized.contains('\\')
        || normalized.chars().any(path_control_or_format)
    {
        return false;
    }
    let components: Vec<&str> = normalized.split('/').collect();
    if components.len() > MAX_DEPTH {
        return false;
    }
    !components
        .iter()
        .any(|component| component.is_empty() || *component == "." || *component == "..")
}

/// What a path may contribute, and why not when it may not.
pub struct Decision {
    pub normalized: String,
    pub eligible: bool,
    pub omission_reason: Option<&'static str>,
}

/// `decisionForRelativePath:`. `components` and `filename` carry the host's
/// folded spellings of the same normalized path, in order.
pub fn path_decision(
    relative_path: &str,
    normalized: &str,
    components: &[Folded],
    filename: &Folded,
    filename_extension: &str,
) -> Decision {
    let refuse = |normalized: &str, reason: &'static str| Decision {
        normalized: normalized.to_string(),
        eligible: false,
        omission_reason: Some(reason),
    };
    if relative_path.is_empty() || relative_path.encode_utf16().count() > MAX_RELATIVE_PATH_UNITS {
        return refuse("", REASON_POLICY);
    }
    if !safe_structure(normalized) {
        return refuse(normalized, REASON_POLICY);
    }
    // A sensitive or generated *directory* anywhere on the way excludes the
    // file, whatever the file itself is called.
    for component in components {
        if sensitive_component(component) {
            return refuse(normalized, REASON_SECRET_PATH);
        }
        if GENERATED_DIRECTORIES.contains(&component.folded) {
            return refuse(normalized, REASON_GENERATED);
        }
    }
    if sensitive_filename(filename) || SENSITIVE_EXTENSIONS.contains(&filename_extension) {
        return refuse(normalized, REASON_SECRET_PATH);
    }
    if lockfile(filename.folded) {
        return refuse(normalized, REASON_LOCKFILE);
    }
    if filename_extension == "map"
        || filename.folded.contains(".min.")
        || filename.folded.ends_with(".bundle.js")
        || filename.folded.ends_with(".bundle.css")
        || BINARY_EXTENSIONS.contains(&filename_extension)
    {
        return refuse(normalized, REASON_BINARY);
    }
    // Anything left over is sent only if it is a known text kind or one of the
    // few names worth sending without one.
    if !safe_basename(filename.folded) && !ALLOWED_TEXT_EXTENSIONS.contains(&filename_extension) {
        return refuse(normalized, REASON_POLICY);
    }
    Decision {
        normalized: normalized.to_string(),
        eligible: true,
        omission_reason: None,
    }
}

/// NFC, so the host and the core agree on the normalized spelling this policy
/// is expressed over.
pub fn normalize(path: &str) -> String {
    path.nfc().collect()
}

/// One envelope in, one reply out; see `rish_agent_project_context_reduce`.
pub fn reduce_json(input: &str) -> String {
    match reduce_json_inner(input) {
        Some(value) => value.to_string(),
        None => json!({ "ok": false }).to_string(),
    }
}

fn folded_from<'a>(value: &'a Value) -> Option<Folded<'a>> {
    Some(Folded {
        folded: value.get("folded")?.as_str()?,
        extension: value.get("extension")?.as_str()?,
        stem: value.get("stem")?.as_str()?,
    })
}

fn reduce_json_inner(input: &str) -> Option<Value> {
    let envelope: Value = serde_json::from_str(input).ok()?;
    match envelope.get("op")?.as_str()? {
        "normalize" => {
            let path = envelope.get("path")?.as_str()?;
            Some(json!({ "ok": true, "normalized": normalize(path) }))
        }
        "path_decision" => {
            let path = envelope.get("path")?.as_str()?;
            let normalized = envelope.get("normalized")?.as_str()?;
            let raw = envelope.get("components")?.as_array()?;
            let components: Vec<Folded> =
                raw.iter().map(folded_from).collect::<Option<Vec<_>>>()?;
            let filename = folded_from(envelope.get("filename")?)?;
            let extension = envelope.get("filename_extension")?.as_str()?;
            let decision = path_decision(path, normalized, &components, &filename, extension);
            Some(json!({
                "ok": true,
                "normalized_path": decision.normalized,
                "eligible": decision.eligible,
                "omission_reason": decision.omission_reason,
            }))
        }
        _ => None,
    }
}

#[cfg(test)]
#[path = "project_context_policy_tests.rs"]
mod tests;
