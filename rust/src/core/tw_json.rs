//! Taskwarrior-compatible JSON export.
//!
//! Taskwarrior exchanges tasks as a list of flat JSON objects. Field names
//! match the stored task properties, dates use the compact UTC form
//! `YYYYMMDDTHHMMSSZ`, and tags, dependencies, and annotations are arrays.
//! `id` and `urgency` are derived decoration fields, not stored task data.
//!
//! The representation is documented in Taskwarrior's JSON format RFC and is
//! what `task export` emits (`json.array=on`).

use super::config::Taskrc;
use super::error::{Result, TaskError};
use super::utils::parse_iso8601;
use serde_json::{Map, Number, Value, json};
use std::str::FromStr;
use taskchampion::{
    Status as TcStatus, Tag, Task,
    chrono::{DateTime, Utc},
};

/// Task properties that TaskChampion stores as epoch seconds.
const DATE_FIELDS: &[&str] = &[
    "entry",
    "modified",
    "due",
    "wait",
    "start",
    "end",
    "scheduled",
    "until",
];

/// Fields written explicitly and therefore skipped by the UDA pass-through.
const EXPLICIT_FIELDS: &[&str] = &[
    "uuid",
    "id",
    "urgency",
    "description",
    "status",
    "priority",
    "scheduled",
    "until",
    "tags",
    "depends",
    "annotations",
];

/// Render a timestamp the way Taskwarrior writes it: `YYYYMMDDTHHMMSSZ`.
pub fn format_tw_date(dt: DateTime<Utc>) -> String {
    dt.format("%Y%m%dT%H%M%SZ").to_string()
}

/// Convert one TaskChampion task into a flat Taskwarrior JSON object.
///
/// `id` is the export-order identifier; unlike a Taskwarrior database id it is
/// only meaningful for the file being written. `urgency` is the value already
/// calculated by the caller (including inheritance, when configured). `config`
/// supplies UDA types, so numeric and date UDAs are written like Taskwarrior's
/// own export.
pub fn task_to_json(task: &Task, id: i64, urgency: f32, config: &Taskrc) -> Value {
    let mut map = Map::new();

    map.insert("id".to_string(), Value::from(id));
    map.insert("uuid".to_string(), Value::from(task.get_uuid().to_string()));
    map.insert(
        "description".to_string(),
        Value::from(task.get_description()),
    );
    map.insert(
        "status".to_string(),
        Value::from(tw_status(task.get_status())),
    );

    for field in DATE_FIELDS {
        if let Some(raw) = task.get_value(*field)
            && let Ok(dt) = parse_iso8601(raw)
        {
            map.insert((*field).to_string(), Value::from(format_tw_date(dt)));
        }
    }

    let priority = task.get_priority();
    if !priority.is_empty() {
        map.insert("priority".to_string(), Value::from(priority));
    }

    // TaskChampion treats every property outside its small core model as a
    // user-defined attribute. That includes standard Taskwarrior properties
    // such as project, recur, mask, imask, and parent, so pass them all through.
    for (key, value) in task.get_user_defined_attributes() {
        if value.is_empty() || EXPLICIT_FIELDS.contains(&key) {
            continue;
        }

        if DATE_FIELDS.contains(&key) {
            if let Ok(dt) = parse_iso8601(value) {
                map.insert(key.to_string(), Value::from(format_tw_date(dt)));
            }
            continue;
        }

        match config.get(&format!("uda.{key}.type")) {
            Some("date") => {
                if let Ok(dt) = parse_iso8601(value) {
                    map.insert(key.to_string(), Value::from(format_tw_date(dt)));
                }
            }
            Some("numeric") => {
                map.insert(key.to_string(), numeric_or_string(value));
            }
            _ if key == "imask" => {
                map.insert(key.to_string(), numeric_or_string(value));
            }
            _ => {
                map.insert(key.to_string(), Value::from(value));
            }
        }
    }

    // TaskChampion synthesizes tags such as PENDING and BLOCKED on the fly;
    // Taskwarrior only exports the concrete tags the user set.
    let mut tags: Vec<String> = task
        .get_tags()
        .filter(Tag::is_user)
        .map(|tag| tag.to_string())
        .collect();
    tags.sort();
    if !tags.is_empty() {
        map.insert("tags".to_string(), json!(tags));
    }

    let mut depends: Vec<String> = task
        .get_dependencies()
        .map(|uuid| uuid.to_string())
        .collect();
    depends.sort();
    if !depends.is_empty() {
        map.insert("depends".to_string(), json!(depends));
    }

    let mut annotations: Vec<(DateTime<Utc>, String)> = task
        .get_annotations()
        .map(|annotation| (annotation.entry, annotation.description.to_string()))
        .collect();
    annotations.sort_by_key(|(entry, _)| *entry);
    if !annotations.is_empty() {
        let annotations: Vec<Value> = annotations
            .into_iter()
            .map(|(entry, description)| {
                json!({
                    "entry": format_tw_date(entry),
                    "description": description,
                })
            })
            .collect();
        map.insert("annotations".to_string(), Value::Array(annotations));
    }

    if let Some(number) = f32_number(urgency) {
        map.insert("urgency".to_string(), Value::Number(number));
    }

    Value::Object(map)
}

/// Serialize tasks as a pretty-printed Taskwarrior JSON array.
pub fn tasks_to_json<T>(tasks: T, config: &Taskrc) -> Result<String>
where
    T: IntoIterator<Item = (Task, f32)>,
{
    let values: Vec<Value> = tasks
        .into_iter()
        .enumerate()
        .map(|(index, (task, urgency))| task_to_json(&task, index as i64 + 1, urgency, config))
        .collect();

    serde_json::to_string_pretty(&values)
        .map_err(|error| TaskError::storage(format!("Failed to serialize tasks: {error}")))
}

fn tw_status(status: TcStatus) -> String {
    match status {
        TcStatus::Completed => "completed".to_string(),
        TcStatus::Deleted => "deleted".to_string(),
        TcStatus::Recurring => "recurring".to_string(),
        TcStatus::Pending => "pending".to_string(),
        // TaskChampion keeps statuses it does not know verbatim for forward
        // compatibility; Taskwarrior would export them unchanged too.
        TcStatus::Unknown(value) => value,
    }
}

/// Match Taskwarrior's numeric fields (currently `imask`) when possible.
fn numeric_or_string(value: &str) -> Value {
    value
        .parse::<i64>()
        .map(Number::from)
        .map(Value::Number)
        .unwrap_or_else(|_| Value::from(value))
}

/// Render an `f32` using its shortest representation, like Taskwarrior's
/// stream output, instead of widening it to an `f64` full of extra digits.
fn f32_number(value: f32) -> Option<Number> {
    if !value.is_finite() {
        return None;
    }
    Number::from_str(&value.to_string()).ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use taskchampion::{
        Annotation, Operations, Replica, StorageConfig, Uuid,
        chrono::{Duration, TimeZone},
    };

    fn replica_with(tasks: impl FnOnce(&mut Replica, &mut Operations)) -> Replica {
        let mut replica = Replica::new(StorageConfig::InMemory.into_storage().unwrap());
        let mut ops = Operations::new();
        tasks(&mut replica, &mut ops);
        replica.commit_operations(ops).unwrap();
        replica
    }

    fn get(replica: &mut Replica, uuid: Uuid) -> Task {
        replica.get_task(uuid).unwrap().unwrap()
    }

    fn entry_time() -> DateTime<Utc> {
        Utc.with_ymd_and_hms(2026, 7, 18, 12, 30, 45).unwrap()
    }

    fn export_object(task: &Task, urgency: f32) -> Value {
        task_to_json(task, 1, urgency, &Taskrc::default())
    }

    #[test]
    fn exports_flat_taskwarrior_fields() {
        let additions = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            let mut task = replica.create_task(additions, ops).unwrap();
            task.set_description("Buy milk".into(), ops).unwrap();
            task.set_status(TcStatus::Pending, ops).unwrap();
            task.set_entry(Some(entry_time()), ops).unwrap();
            task.set_due(Some(entry_time() + Duration::days(2)), ops)
                .unwrap();
            task.set_priority("H".into(), ops).unwrap();
            task.set_value("project", Some("Home".to_string()), ops)
                .unwrap();
            task.set_user_defined_attribute("size".to_string(), "large".to_string(), ops)
                .unwrap();
            task.add_tag(&Tag::from_str("next").unwrap(), ops).unwrap();
            task.add_annotation(
                Annotation {
                    entry: entry_time(),
                    description: "from the shop".into(),
                },
                ops,
            )
            .unwrap();
        });

        let task = get(&mut replica, additions);
        let value = export_object(&task, 1.25);

        assert!(value.get("core").is_none(), "not a TaskSnapshot wrapper");
        assert!(
            value.get("computed").is_none(),
            "not a TaskSnapshot wrapper"
        );
        assert_eq!(value["uuid"], additions.to_string());
        assert_eq!(value["description"], "Buy milk");
        assert_eq!(value["status"], "pending");
        assert_eq!(value["entry"], "20260718T123045Z");
        assert_eq!(value["due"], "20260720T123045Z");
        assert_eq!(value["priority"], "H");
        assert_eq!(value["project"], "Home");
        assert_eq!(value["size"], "large");
        assert_eq!(value["tags"], json!(["next"]));
        assert_eq!(value["annotations"][0]["entry"], "20260718T123045Z");
        assert_eq!(value["annotations"][0]["description"], "from the shop");
        assert_eq!(value["urgency"], json!(1.25));
        assert_eq!(value["id"], json!(1));
    }

    #[test]
    fn exports_dependencies_as_an_array() {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            let mut task = replica.create_task(first, ops).unwrap();
            task.set_description("first".into(), ops).unwrap();
            task.set_status(TcStatus::Pending, ops).unwrap();
            let mut dependent = replica.create_task(second, ops).unwrap();
            dependent.set_description("second".into(), ops).unwrap();
            dependent.set_status(TcStatus::Pending, ops).unwrap();
            dependent.add_dependency(first, ops).unwrap();
        });

        let task = get(&mut replica, second);
        let value = export_object(&task, 0.0);

        assert_eq!(value["depends"], json!([first.to_string()]));
    }

    #[test]
    fn exports_recurrence_linkage_and_only_user_tags() {
        let template = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            let mut task = replica.create_task(template, ops).unwrap();
            task.set_description("Water plants".into(), ops).unwrap();
            task.set_status(TcStatus::Recurring, ops).unwrap();
            task.set_due(Some(entry_time()), ops).unwrap();
            task.set_value("recur", Some("weekly".to_string()), ops)
                .unwrap();
            task.set_value("mask", Some("1".to_string()), ops).unwrap();
            task.set_value("imask", Some("1".to_string()), ops).unwrap();
            task.set_value("rtype", Some("periodic".to_string()), ops)
                .unwrap();
            task.add_tag(&Tag::from_str("home").unwrap(), ops).unwrap();
        });

        let task = get(&mut replica, template);
        let value = export_object(&task, 0.0);

        assert_eq!(value["status"], "recurring");
        assert_eq!(value["recur"], "weekly");
        assert_eq!(value["mask"], "1");
        assert_eq!(value["imask"], json!(1));
        assert_eq!(value["rtype"], "periodic");
        assert_eq!(
            value["tags"],
            json!(["home"]),
            "synthetic tags are not exported"
        );
    }

    #[test]
    fn exports_parent_linkage_on_instances() {
        let parent = Uuid::new_v4();
        let child = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            let mut task = replica.create_task(child, ops).unwrap();
            task.set_description("Water plants".into(), ops).unwrap();
            task.set_status(TcStatus::Pending, ops).unwrap();
            task.set_value("parent", Some(parent.to_string()), ops)
                .unwrap();
            task.set_value("imask", Some("2".to_string()), ops).unwrap();
        });

        let task = get(&mut replica, child);
        let value = export_object(&task, 0.0);

        assert_eq!(value["parent"], parent.to_string());
        assert_eq!(value["imask"], json!(2));
    }

    #[test]
    fn serializes_a_taskwarrior_json_array() {
        let first = Uuid::new_v4();
        let second = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            for (uuid, description) in [(first, "first"), (second, "second")] {
                let mut task = replica.create_task(uuid, ops).unwrap();
                task.set_description(description.into(), ops).unwrap();
                task.set_status(TcStatus::Pending, ops).unwrap();
            }
        });

        let tasks = vec![
            (get(&mut replica, first), 0.5),
            (get(&mut replica, second), 1.5),
        ];
        let json = tasks_to_json(tasks, &Taskrc::default()).expect("export");
        let values: Vec<Value> = serde_json::from_str(&json).expect("valid JSON");

        assert_eq!(values.len(), 2);
        assert_eq!(values[0]["id"], json!(1));
        assert_eq!(values[1]["id"], json!(2));
        assert_eq!(values[0]["uuid"], first.to_string());
        assert_eq!(values[1]["uuid"], second.to_string());
    }

    #[test]
    fn exports_uda_types_from_taskrc() {
        let uuid = Uuid::new_v4();
        let mut replica = replica_with(|replica, ops| {
            let mut task = replica.create_task(uuid, ops).unwrap();
            task.set_description("typed attributes".into(), ops)
                .unwrap();
            task.set_status(TcStatus::Pending, ops).unwrap();
            task.set_user_defined_attribute("estimate".to_string(), "3".to_string(), ops)
                .unwrap();
            task.set_user_defined_attribute("ship".to_string(), entry_time().to_rfc3339(), ops)
                .unwrap();
        });

        let mut config = Taskrc::default();
        config.set("uda.estimate.type", "numeric");
        config.set("uda.ship.type", "date");

        let task = get(&mut replica, uuid);
        let value = task_to_json(&task, 1, 0.0, &config);

        assert_eq!(value["estimate"], json!(3), "numeric UDA is a number");
        assert_eq!(value["ship"], "20260718T123045Z", "date UDA is compact UTC");
    }

    #[test]
    fn formats_dates_in_taskwarrior_compact_utc() {
        let dt = Utc.with_ymd_and_hms(2026, 1, 2, 3, 4, 5).unwrap();
        assert_eq!(format_tw_date(dt), "20260102T030405Z");
    }
}
