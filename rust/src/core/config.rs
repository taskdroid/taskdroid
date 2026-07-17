use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use super::error::{Result, TaskError};

/// TW-styled flat key-value config store
/// Mirrors TW's `Configuration` class (an `std::map<std::string,std::string>`)
#[derive(Debug, Clone)]
pub struct Taskrc {
    values: HashMap<String, String>,
    user_keys: HashSet<String>,
    file_path: Option<PathBuf>,
}

impl Taskrc {
    pub fn new() -> Self {
        Self {
            values: HashMap::new(),
            user_keys: HashSet::new(),
            file_path: None,
        }
    }

    /// load defaults matching taskwarrior's `configurationDefaults`
    /// these are the same values hardcoded in `Context.cpp` in TW
    pub fn load_defaults(&mut self) {
        self.parse_str(DEFAULT_CONFIG, false);
    }

    /// parse `taskrc` file & merge its values on top of existing ones
    pub fn parse_file<P: AsRef<Path>>(&mut self, path: P) -> Result<()> {
        let path = path.as_ref();
        let content = fs::read_to_string(path).map_err(|e| {
            TaskError::invalid_input(format!("Failed to read taskrc `{}`: {e}", path.display()))
        })?;
        self.file_path = Some(path.to_path_buf());
        self.parse_str(&content, true);
        Ok(())
    }

    /// Parse raw `taskrc` content and merge values
    fn parse_str(&mut self, content: &str, track_user: bool) {
        for line in content.lines() {
            let raw = Self::strip_comment(line);
            let trimmed = raw.trim();
            if trimmed.is_empty() {
                continue;
            }

            if let Some(eq_pos) = trimmed.find('=') {
                let key = trimmed[..eq_pos].trim().to_string();
                let value = trimmed[eq_pos + 1..].trim().to_string();
                self.values.insert(key.clone(), value);
                if track_user {
                    self.user_keys.insert(key);
                }
            }
        }
    }

    fn strip_comment(line: &str) -> &str {
        find_comment_start(line).map_or(line, |pos| line[..pos].trim_end())
    }

    /// validate raw `taskrc` content and return any issues found
    /// Checks for:
    /// - `include` directives (not supported, silently ignored)
    /// - `$VAR` / `${VAR}` references (not supported, used literally)
    /// - keys absent from `DEFAULT_CONFIG` (not supported by this app)
    /// - values that do not match the type implied by their default
    /// - lines that are neither comments nor `key=value` (silently ignored)
    pub fn validate(content: &str) -> Vec<ConfigIssue> {
        let mut issues = Vec::new();
        for (i, line) in content.lines().enumerate() {
            let trimmed = Self::strip_comment(line).trim();
            if trimmed.is_empty() || trimmed.starts_with('#') {
                continue;
            }

            if let Some(eq_pos) = trimmed.find('=') {
                let key = trimmed[..eq_pos].trim();
                let value = trimmed[eq_pos + 1..].trim();

                if let Some(default_value) = default_value_for_key(key) {
                    validate_value_kind(
                        key,
                        value,
                        value_kind_from_default(default_value),
                        i + 1,
                        &mut issues,
                    );
                } else {
                    issues.push(ConfigIssue {
                        line: i + 1,
                        kind: IssueKind::Warning,
                        message: format!(
                            "unrecognized config key `{key}`; this app will ignore it"
                        ),
                    });
                }

                if value.contains('$') {
                    issues.push(ConfigIssue {
                        line: i + 1,
                        kind: IssueKind::Warning,
                        message: "environment variable references ($VAR, ${VAR}) are not supported; using literal value".to_string(),
                    });
                }
            } else {
                let word_end = trimmed
                    .find(|c: char| c.is_whitespace())
                    .unwrap_or(trimmed.len());
                let first_word = &trimmed[..word_end];
                if first_word == "include" {
                    issues.push(ConfigIssue {
                        line: i + 1,
                        kind: IssueKind::Warning,
                        message: "include directives are not supported; this line will be ignored"
                            .to_string(),
                    });
                } else {
                    issues.push(ConfigIssue {
                        line: i + 1,
                        kind: IssueKind::Warning,
                        message: "unrecognized line format; expected key=value".to_string(),
                    });
                }
            }
        }
        issues
    }

    /// get config value by key
    pub fn get(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(|s| s.as_str())
    }

    /// get floating-point config value with a fallback default
    pub fn get_float(&self, key: &str, default: f32) -> f32 {
        self.get(key)
            .and_then(|v| v.parse::<f32>().ok())
            .unwrap_or(default)
    }

    /// get a boolean config value with a fallback default
    /// Accepts `1`, `yes`, `true`, `on` as true;
    /// `0`, `no`, `false`, `off`, or missing as false
    pub fn get_bool(&self, key: &str, default: bool) -> bool {
        self.get(key).and_then(parse_bool).unwrap_or(default)
    }

    /// get an integer config value with a fallback default
    pub fn get_int(&self, key: &str, default: i64) -> i64 {
        self.get(key)
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(default)
    }

    /// Set a config value and mark as a user override.
    pub fn set(&mut self, key: &str, value: &str) {
        self.user_keys.insert(key.to_string());
        self.values.insert(key.to_string(), value.to_string());
    }

    /// check if a key exists
    pub fn has(&self, key: &str) -> bool {
        self.values.contains_key(key)
    }

    /// return all key-value pairs (sorted by key)
    pub fn all(&self) -> Vec<(&str, &str)> {
        let mut pairs: Vec<_> = self
            .values
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        pairs.sort_by(|a, b| a.0.cmp(b.0));
        pairs
    }

    /// number of entries
    pub fn len(&self) -> usize {
        self.values.len()
    }

    pub fn is_empty(&self) -> bool {
        self.values.is_empty()
    }

    /// path of the file last parsed
    pub fn file_path(&self) -> Option<&Path> {
        self.file_path.as_deref()
    }

    /// check if the config has a file path set
    pub fn has_file(&self) -> bool {
        self.file_path.is_some()
    }

    /// Set the file path for this config
    pub fn set_file_path(&mut self, path: PathBuf) {
        self.file_path = Some(path);
    }

    /// reload user keys from the file on disk
    pub fn reload(&mut self) -> Result<()> {
        let path = self.file_path.clone();
        self.values.clear();
        self.user_keys.clear();
        self.load_defaults();
        if let Some(ref path) = path {
            if path.exists() {
                self.parse_file(path)?;
            }
        }
        Ok(())
    }

    /// persist the current key-value pairs back to the file
    pub fn save(&self) -> Result<()> {
        let path = self
            .file_path
            .as_ref()
            .ok_or_else(|| TaskError::invalid_input("No taskrc file path set; cannot save"))?;
        self.write_to(path)
    }

    /// write config to a specific path
    pub fn save_to<P: AsRef<Path>>(&self, path: P) -> Result<()> {
        let path = path.as_ref();
        let mut config = self.clone();
        config.file_path = Some(path.to_path_buf());
        config.write_to(path)
    }

    fn write_to(&self, path: &Path) -> Result<()> {
        if self.user_keys.is_empty() {
            if path.exists() {
                fs::remove_file(path)
                    .map_err(|e| TaskError::storage(format!("Failed to remove taskrc: {e}")))?;
            }
            return Ok(());
        }

        let content = if path.exists() {
            fs::read_to_string(path)
                .map_err(|e| TaskError::storage(format!("Failed to read taskrc: {e}")))?
        } else {
            String::new()
        };

        let mut remaining: HashSet<String> = self.user_keys.clone();
        let mut result_lines: Vec<String> = Vec::new();

        for line in content.lines() {
            let stripped = Self::strip_comment(line).trim().to_string();
            if let Some(eq_pos) = stripped.find('=') {
                let key = stripped[..eq_pos].trim().to_string();
                if key.is_empty() {
                    result_lines.push(line.to_string());
                    continue;
                }
                if self.user_keys.contains(&key) {
                    if let Some(new_value) = self.values.get(&key) {
                        let indent = get_indent(line);
                        let line_eq_pos = line.find('=').unwrap();
                        let comment = get_trailing_comment(line, line_eq_pos);
                        result_lines.push(format!("{indent}{key}={new_value}{comment}"));
                    } else {
                        result_lines.push(line.to_string());
                    }
                    remaining.remove(&key);
                } else {
                    result_lines.push(line.to_string());
                }
            } else {
                result_lines.push(line.to_string());
            }
        }

        for key in &remaining {
            if let Some(value) = self.values.get(key) {
                result_lines.push(format!("{key}={value}"));
            }
        }

        let output = result_lines.join("\n");
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)
                .map_err(|e| TaskError::storage(format!("Failed to create directory: {e}")))?;
        }
        fs::write(path, &output)
            .map_err(|e| TaskError::storage(format!("Failed to write taskrc: {e}")))?;

        Ok(())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ValueKind {
    Int,
    Float,
    Bool,
    Text,
}

fn default_value_for_key(key: &str) -> Option<&'static str> {
    DEFAULT_CONFIG.lines().find_map(|line| {
        let stripped = Taskrc::strip_comment(line).trim();
        let (default_key, default_value) = stripped.split_once('=')?;
        (default_key.trim() == key).then_some(default_value.trim())
    })
}

fn value_kind_from_default(value: &str) -> ValueKind {
    if value.parse::<i64>().is_ok() {
        ValueKind::Int
    } else if value.parse::<f32>().is_ok() {
        ValueKind::Float
    } else if parse_bool(value).is_some() {
        ValueKind::Bool
    } else {
        ValueKind::Text
    }
}

fn validate_value_kind(
    key: &str,
    value: &str,
    kind: ValueKind,
    line: usize,
    issues: &mut Vec<ConfigIssue>,
) {
    match kind {
        ValueKind::Int if value.parse::<i64>().is_err() => {
            issues.push(ConfigIssue {
                line,
                kind: IssueKind::Warning,
                message: format!("`{key}` expects an integer value; this value will be ignored"),
            });
        }
        ValueKind::Float if value.parse::<f32>().is_err() => {
            issues.push(ConfigIssue {
                line,
                kind: IssueKind::Warning,
                message: format!("`{key}` expects a numeric value; this value will be ignored"),
            });
        }
        ValueKind::Bool if parse_bool(value).is_none() => {
            issues.push(ConfigIssue {
                line,
                kind: IssueKind::Warning,
                message: format!("`{key}` expects a boolean value; this value will be ignored"),
            });
        }
        ValueKind::Text | ValueKind::Int | ValueKind::Float | ValueKind::Bool => {}
    }
}

fn parse_bool(value: &str) -> Option<bool> {
    if value == "1"
        || value.eq_ignore_ascii_case("yes")
        || value.eq_ignore_ascii_case("true")
        || value.eq_ignore_ascii_case("on")
    {
        Some(true)
    } else if value == "0"
        || value.eq_ignore_ascii_case("no")
        || value.eq_ignore_ascii_case("false")
        || value.eq_ignore_ascii_case("off")
    {
        Some(false)
    } else {
        None
    }
}

fn get_indent(line: &str) -> &str {
    let trimmed = line.trim_start();
    let indent_len = line.len() - trimmed.len();
    &line[..indent_len]
}

fn get_trailing_comment(line: &str, eq_pos: usize) -> &str {
    let after_value = &line[eq_pos + 1..];
    if let Some(hash_pos) = find_comment_start(after_value) {
        &after_value[hash_pos..]
    } else {
        ""
    }
}

fn find_comment_start(line: &str) -> Option<usize> {
    let mut prev_is_whitespace = true;
    for (idx, ch) in line.char_indices() {
        if ch == '#' && prev_is_whitespace {
            return Some(idx);
        }
        prev_is_whitespace = ch.is_whitespace();
    }
    None
}

impl Default for Taskrc {
    fn default() -> Self {
        let mut config = Self::new();
        config.load_defaults();
        config
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_CONFIG, Taskrc, ValueKind, value_kind_from_default};

    #[test]
    fn parse_preserves_hash_in_value_without_whitespace_comment() {
        let mut config = Taskrc::new();
        config.parse_str("foo=bar#baz\nbar=qux # comment\n", true);

        assert_eq!(config.get("foo"), Some("bar#baz"));
        assert_eq!(config.get("bar"), Some("qux"));
    }

    #[test]
    fn validate_warns_on_unknown_config_key() {
        let issues = Taskrc::validate("uda.priority.urgency.H=10\n");
        assert_eq!(issues.len(), 1);
        assert!(
            issues[0]
                .message
                .contains("unrecognized config key `uda.priority.urgency.H`")
        );
    }

    #[test]
    fn validate_warns_on_invalid_supported_value_type() {
        let issues = Taskrc::validate("recurrence.limit=abc\n");
        assert_eq!(issues.len(), 1);
        assert!(issues[0].message.contains("expects an integer value"));
    }

    #[test]
    fn validate_accepts_all_default_config_keys() {
        let issues = Taskrc::validate(DEFAULT_CONFIG);
        assert!(issues.is_empty());
    }

    #[test]
    fn value_kind_is_inferred_from_default_value() {
        assert_eq!(value_kind_from_default("1"), ValueKind::Int);
        assert_eq!(value_kind_from_default("1.5"), ValueKind::Float);
        assert_eq!(value_kind_from_default("yes"), ValueKind::Bool);
        assert_eq!(value_kind_from_default("default"), ValueKind::Text);
    }
}

/// an issue found while validating a `taskrc` file
#[derive(Debug, Clone)]
pub struct ConfigIssue {
    pub line: usize,
    pub kind: IssueKind,
    pub message: String,
}

/// severity of a config validation issue
#[derive(Debug, Clone, PartialEq)]
pub enum IssueKind {
    Warning,
    Error,
}

/// Default urgency coefficients used by the urgency calculation.
const DEFAULT_CONFIG: &str = r##"urgency.due.coefficient=12.0
urgency.blocking.coefficient=8.0
urgency.active.coefficient=4.0
urgency.scheduled.coefficient=5.0
urgency.age.coefficient=2.0
urgency.annotations.coefficient=1.0
urgency.tags.coefficient=1.0
urgency.project.coefficient=1.0
urgency.blocked.coefficient=-5.0
urgency.waiting.coefficient=-3.0
urgency.user.tag.next.coefficient=15.0
urgency.uda.priority.H.coefficient=6.0
urgency.uda.priority.M.coefficient=3.9
urgency.uda.priority.L.coefficient=1.8
due=7
recurrence.limit=1
"##;
