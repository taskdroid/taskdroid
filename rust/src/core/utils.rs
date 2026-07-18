use super::config::Taskrc;
use super::error::{Result, TaskError};
use super::models::{TaskAnnotation, TaskComputed, TaskCore, TaskSnapshot, TaskStatus, UdaPair};
use std::collections::{HashMap, HashSet};
use std::str::FromStr;
use taskchampion::{
    Status as TcStatus, Tag, Uuid,
    chrono::{DateTime, Utc},
};

pub fn task_snapshot_from_task(t: taskchampion::Task, config: &Taskrc) -> TaskSnapshot {
    let now = Utc::now();
    let urgency = calculate_urgency(&t, now, config);
    task_snapshot_from_task_with_urgency(t, urgency)
}

pub fn task_snapshot_from_task_with_urgency(t: taskchampion::Task, urgency: f32) -> TaskSnapshot {
    let status = t.get_status();
    let is_recurring_template = status == TcStatus::Recurring;
    let parent_uuid = t.get_value("parent").map(|s| s.to_string());
    let recurrence_index = t.get_value("imask").and_then(|v| v.parse::<usize>().ok());
    let is_recurring_instance = parent_uuid.is_some();

    let series_root_uuid = if is_recurring_template {
        Some(t.get_uuid().to_string())
    } else if is_recurring_instance {
        parent_uuid.clone()
    } else {
        None
    };

    let computed = TaskComputed {
        urgency,
        is_active: t.is_active(),
        is_blocked: t.is_blocked(),
        is_blocking: t.is_blocking(),
        is_waiting: t.is_waiting(),
        is_recurring_template,
        is_recurring_instance,
        series_root_uuid,
    };

    let udas = t
        .get_user_defined_attributes()
        .filter(|(k, _)| {
            ![
                "project",
                "recur",
                "sched",
                "scheduled",
                "until",
                "start",
                "end",
                "parent",
                "imask",
            ]
            .contains(k)
        })
        .map(|(k, v)| UdaPair {
            key: k.to_string(),
            value: v.to_string(),
        })
        .collect();

    let annotations = t
        .get_annotations()
        .map(|ann| TaskAnnotation {
            entry: format_iso8601(ann.entry),
            description: ann.description.to_string(),
        })
        .collect();

    let priority_str = t.get_priority();
    let priority = if priority_str.is_empty() {
        None
    } else {
        Some(priority_str.to_string())
    };

    let core = TaskCore {
        uuid: t.get_uuid().to_string(),
        description: t.get_description().to_string(),
        status: map_tc_to_status(status),
        project: t.get_value("project").map(|s| s.to_string()),
        priority,
        tags: t.get_tags().map(|t| t.to_string()).collect(),
        entry: t.get_entry().map(format_iso8601).unwrap_or_default(),
        modified: t.get_modified().map(format_iso8601).unwrap_or_default(),
        due: t.get_due().map(format_iso8601),
        wait: t.get_wait().map(format_iso8601),
        start: t.get_value("start").and_then(parse_date_opt_str),
        end: t.get_value("end").and_then(parse_date_opt_str),
        scheduled: t
            .get_value("scheduled")
            .or_else(|| t.get_value("sched"))
            .and_then(parse_date_opt_str),
        until: t.get_value("until").and_then(parse_date_opt_str),
        depends: t.get_dependencies().map(|u| u.to_string()).collect(),
        recurrence: t.get_value("recur").map(|s| s.to_string()),
        annotations,
        udas,
        parent_uuid,
        recurrence_index,
    };

    TaskSnapshot { core, computed }
}

pub fn map_tc_to_status(s: TcStatus) -> TaskStatus {
    match s {
        TcStatus::Pending => TaskStatus::Pending,
        TcStatus::Completed => TaskStatus::Completed,
        TcStatus::Deleted => TaskStatus::Deleted,
        TcStatus::Recurring => TaskStatus::Recurring,
        _ => TaskStatus::Pending,
    }
}

pub fn parse_iso8601(date_str: &str) -> Result<DateTime<Utc>> {
    if let Ok(raw_epoch) = date_str.parse::<i64>() {
        let (secs, nanos) = if raw_epoch.abs() >= 1_000_000_000_000 {
            let secs = raw_epoch.div_euclid(1000);
            let millis = raw_epoch.rem_euclid(1000) as u32;
            (secs, millis * 1_000_000)
        } else {
            (raw_epoch, 0)
        };

        if let Some(dt) = DateTime::from_timestamp(secs, nanos) {
            return Ok(dt);
        }
    }
    if let Ok(dt) = DateTime::parse_from_rfc3339(date_str) {
        return Ok(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = DateTime::parse_from_str(date_str, "%Y%m%dT%H%M%SZ") {
        return Ok(dt.with_timezone(&Utc));
    }
    if let Ok(dt) = taskchampion::chrono::NaiveDateTime::parse_from_str(date_str, "%Y%m%dT%H%M%S") {
        return Ok(DateTime::from_naive_utc_and_offset(dt, Utc));
    }
    if let Ok(dt) = taskchampion::chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d") {
        let midnight = dt.and_hms_opt(0, 0, 0).ok_or_else(|| {
            TaskError::invalid_input(format!("Invalid date-only value: {date_str}"))
        })?;
        return Ok(DateTime::from_naive_utc_and_offset(midnight, Utc));
    }
    Err(TaskError::invalid_input(format!(
        "Invalid date: {date_str}"
    )))
}

pub fn parse_date_opt(s: &str) -> Option<DateTime<Utc>> {
    parse_iso8601(s).ok()
}

pub fn parse_date_opt_str(s: &str) -> Option<String> {
    parse_iso8601(s).ok().map(|d| d.to_rfc3339())
}

pub fn parse_date_opt_strict(s: &str) -> Result<Option<DateTime<Utc>>> {
    if s.is_empty() {
        Ok(None)
    } else {
        Ok(Some(parse_iso8601(s)?))
    }
}

pub fn parse_date_opt_str_strict(s: &str) -> Result<Option<String>> {
    if s.is_empty() {
        Ok(None)
    } else {
        Ok(Some(parse_iso8601(s)?.to_rfc3339()))
    }
}

pub fn format_iso8601(dt: DateTime<Utc>) -> String {
    dt.to_rfc3339()
}

pub(crate) fn calculate_urgency(
    t: &taskchampion::Task,
    now: DateTime<Utc>,
    config: &Taskrc,
) -> f32 {
    let c_due = config.get_float("urgency.due.coefficient", 12.0);
    let c_blocking = config.get_float("urgency.blocking.coefficient", 8.0);
    let c_active = config.get_float("urgency.active.coefficient", 4.0);
    let c_sched = config.get_float("urgency.scheduled.coefficient", 5.0);
    let c_age = config.get_float("urgency.age.coefficient", 2.0);
    let age_max = config.get_int("urgency.age.max", 365);
    let c_tags = config.get_float("urgency.tags.coefficient", 1.0);
    let c_annotations = config.get_float("urgency.annotations.coefficient", 1.0);
    let c_project = config.get_float("urgency.project.coefficient", 1.0);
    let c_blocked = config.get_float("urgency.blocked.coefficient", -5.0);
    let c_waiting = config.get_float("urgency.waiting.coefficient", -3.0);

    let mut urgency = 0.0;

    if t.is_active() {
        urgency += c_active;
    }
    if t.is_blocking() {
        urgency += c_blocking;
    }
    if t.is_blocked() {
        urgency += c_blocked;
    }
    if t.is_waiting() {
        urgency += c_waiting;
    }
    if t.get_value("project").is_some() {
        urgency += c_project;
    }

    if let Some(due) = t.get_due() {
        let days_overdue = (now - due).num_seconds() as f32 / 86_400.0;
        if days_overdue >= 7.0 {
            urgency += c_due;
        } else if days_overdue >= -14.0 {
            urgency += c_due * (((days_overdue + 14.0) * 0.8 / 21.0) + 0.2);
        } else {
            urgency += c_due * 0.2;
        }
    }

    if let Some(sched) = t
        .get_value("scheduled")
        .or_else(|| t.get_value("sched"))
        .and_then(|s| parse_iso8601(s).ok())
    {
        if sched < now {
            urgency += c_sched;
        }
    }

    if let Some(entry) = t.get_entry() {
        let days = (now - entry).num_days().max(0) as f32;
        let factor = if age_max <= 0 {
            1.0
        } else {
            (days / age_max as f32).min(1.0)
        };
        urgency += c_age * factor;
    }

    match t.get_tags().count() {
        0 => {}
        1 => urgency += c_tags * 0.8,
        2 => urgency += c_tags * 0.9,
        _ => urgency += c_tags,
    }

    match t.get_annotations().count() {
        0 => {}
        1 => urgency += c_annotations * 0.8,
        2 => urgency += c_annotations * 0.9,
        _ => urgency += c_annotations,
    }

    urgency += user_tag_urgency(t, config);
    urgency += user_project_urgency(t, config);
    urgency += user_keyword_urgency(t, config);
    urgency += uda_urgency(t, config);

    urgency
}

pub(crate) fn calculate_urgency_with_inheritance(
    t: &taskchampion::Task,
    now: DateTime<Utc>,
    config: &Taskrc,
    all_tasks: &HashMap<Uuid, taskchampion::Task>,
) -> f32 {
    calculate_urgency_with_inheritance_inner(t, now, config, all_tasks, &mut HashSet::new())
}

fn calculate_urgency_with_inheritance_inner(
    t: &taskchampion::Task,
    now: DateTime<Utc>,
    config: &Taskrc,
    all_tasks: &HashMap<Uuid, taskchampion::Task>,
    visiting: &mut HashSet<Uuid>,
) -> f32 {
    let own_urgency = calculate_urgency(t, now, config);
    if !config.get_bool("urgency.inherit", false) || !t.is_blocking() {
        return own_urgency;
    }

    let uuid = t.get_uuid();
    if !visiting.insert(uuid) {
        return own_urgency;
    }

    let inherited = all_tasks
        .values()
        .filter(|candidate| {
            candidate.get_status() == TcStatus::Pending
                && candidate.get_dependencies().any(|dep| dep == uuid)
        })
        .map(|candidate| {
            calculate_urgency_with_inheritance_inner(candidate, now, config, all_tasks, visiting)
        })
        .fold(f32::NEG_INFINITY, f32::max);

    visiting.remove(&uuid);

    if inherited.is_finite() && own_urgency <= inherited {
        inherited + 0.01
    } else {
        own_urgency
    }
}

fn user_tag_urgency(t: &taskchampion::Task, config: &Taskrc) -> f32 {
    config
        .pairs_with_prefix("urgency.user.tag.")
        .into_iter()
        .filter_map(|(key, value)| {
            let tag_name = key
                .strip_prefix("urgency.user.tag.")?
                .strip_suffix(".coefficient")?;
            let tag = Tag::from_str(tag_name).ok()?;
            t.has_tag(&tag).then(|| value.parse::<f32>().ok()).flatten()
        })
        .sum()
}

fn user_project_urgency(t: &taskchampion::Task, config: &Taskrc) -> f32 {
    let Some(project) = t.get_value("project") else {
        return 0.0;
    };

    config
        .pairs_with_prefix("urgency.user.project.")
        .into_iter()
        .filter_map(|(key, value)| {
            let configured_project = key
                .strip_prefix("urgency.user.project.")?
                .strip_suffix(".coefficient")?;
            (project == configured_project
                || project.starts_with(&format!("{configured_project}.")))
            .then(|| value.parse::<f32>().ok())
            .flatten()
        })
        .sum()
}

fn user_keyword_urgency(t: &taskchampion::Task, config: &Taskrc) -> f32 {
    let description = t.get_description();

    config
        .pairs_with_prefix("urgency.user.keyword.")
        .into_iter()
        .filter_map(|(key, value)| {
            let keyword = key
                .strip_prefix("urgency.user.keyword.")?
                .strip_suffix(".coefficient")?;
            description
                .contains(keyword)
                .then(|| value.parse::<f32>().ok())
                .flatten()
        })
        .sum()
}

fn uda_urgency(t: &taskchampion::Task, config: &Taskrc) -> f32 {
    config
        .pairs_with_prefix("urgency.uda.")
        .into_iter()
        .filter_map(|(key, value)| {
            let uda = key
                .strip_prefix("urgency.uda.")?
                .strip_suffix(".coefficient")?;
            let coefficient = value.parse::<f32>().ok()?;

            if let Some((name, expected)) = uda.split_once('.') {
                return (read_task_value(t, name).as_deref() == Some(expected))
                    .then_some(coefficient);
            }

            task_has_value(t, uda).then_some(coefficient)
        })
        .sum()
}

fn read_task_value(t: &taskchampion::Task, key: &str) -> Option<String> {
    match key {
        "description" => Some(t.get_description().to_string()),
        "priority" => Some(t.get_priority().to_string()),
        "project" => t.get_value("project").map(|value| value.to_string()),
        "scheduled" => t
            .get_value("scheduled")
            .or_else(|| t.get_value("sched"))
            .map(|value| value.to_string()),
        "due" => t.get_due().map(format_iso8601),
        "entry" => t.get_entry().map(format_iso8601),
        "modified" => t.get_modified().map(format_iso8601),
        "wait" => t.get_wait().map(format_iso8601),
        value => t.get_value(value).map(|value| value.to_string()),
    }
}

fn task_has_value(t: &taskchampion::Task, key: &str) -> bool {
    match key {
        "description" => !t.get_description().is_empty(),
        "priority" => !t.get_priority().is_empty(),
        "project" => t.get_value("project").is_some(),
        "scheduled" => t
            .get_value("scheduled")
            .or_else(|| t.get_value("sched"))
            .is_some(),
        "due" => t.get_due().is_some(),
        "entry" => t.get_entry().is_some(),
        "modified" => t.get_modified().is_some(),
        "wait" => t.get_wait().is_some(),
        value => t.get_value(value).is_some(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use taskchampion::{
        Operations, Replica, Status as TcStatus, StorageConfig, Uuid,
        chrono::{Duration, TimeZone},
    };

    fn blank_urgency_config() -> Taskrc {
        let mut config = Taskrc::default();
        for key in [
            "urgency.user.tag.next.coefficient",
            "urgency.due.coefficient",
            "urgency.blocking.coefficient",
            "urgency.uda.priority.H.coefficient",
            "urgency.uda.priority.M.coefficient",
            "urgency.uda.priority.L.coefficient",
            "urgency.active.coefficient",
            "urgency.scheduled.coefficient",
            "urgency.age.coefficient",
            "urgency.annotations.coefficient",
            "urgency.tags.coefficient",
            "urgency.project.coefficient",
            "urgency.blocked.coefficient",
            "urgency.waiting.coefficient",
        ] {
            config.set(key, "0.0");
        }
        config
    }

    fn task_with(fields: &[(&str, &str)], now: DateTime<Utc>) -> taskchampion::Task {
        let mut replica = Replica::new(StorageConfig::InMemory.into_storage().unwrap());
        let mut ops = Operations::new();
        let uuid = Uuid::new_v4();
        let mut task = replica.create_task(uuid, &mut ops).unwrap();
        task.set_description("test task".into(), &mut ops).unwrap();
        task.set_status(TcStatus::Pending, &mut ops).unwrap();
        task.set_entry(Some(now), &mut ops).unwrap();

        for (key, value) in fields {
            match *key {
                "description" => task.set_description(value.to_string(), &mut ops).unwrap(),
                "entry" => task
                    .set_entry(Some(parse_iso8601(value).unwrap()), &mut ops)
                    .unwrap(),
                "due" => task
                    .set_due(Some(parse_iso8601(value).unwrap()), &mut ops)
                    .unwrap(),
                "priority" => task.set_priority(value.to_string(), &mut ops).unwrap(),
                "project" => task
                    .set_value("project", Some(value.to_string()), &mut ops)
                    .unwrap(),
                "tag" => {
                    let tag = Tag::from_str(value).unwrap();
                    task.add_tag(&tag, &mut ops).unwrap();
                }
                key => task
                    .set_user_defined_attribute(key.to_string(), value.to_string(), &mut ops)
                    .unwrap(),
            }
        }

        replica.commit_operations(ops).unwrap();
        replica.get_task(uuid).unwrap().unwrap()
    }

    fn assert_close(actual: f32, expected: f32) {
        assert!(
            (actual - expected).abs() < 0.001,
            "expected {expected}, got {actual}"
        );
    }

    #[test]
    fn urgency_applies_custom_tag_project_and_keyword_coefficients() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.user.tag.problem.coefficient", "4.5");
        config.set("urgency.user.project.Home.coefficient", "2.9");
        config.set("urgency.user.keyword.invoice.coefficient", "1.5");
        let task = task_with(
            &[
                ("description", "Pay the invoice"),
                ("project", "Home"),
                ("tag", "problem"),
            ],
            now,
        );

        assert_close(calculate_urgency(&task, now, &config), 8.9);
    }

    #[test]
    fn urgency_user_project_matches_child_projects() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.user.project.Home.coefficient", "2.9");
        let task = task_with(&[("project", "Home.Kitchen")], now);

        assert_close(calculate_urgency(&task, now, &config), 2.9);
    }

    #[test]
    fn urgency_applies_uda_presence_value_and_priority_coefficients() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.uda.size.coefficient", "2.8");
        config.set("urgency.uda.size.large.coefficient", "4.2");
        config.set("urgency.uda.priority.H.coefficient", "6.0");
        let task = task_with(&[("size", "large"), ("priority", "H")], now);

        assert_close(calculate_urgency(&task, now, &config), 13.0);
    }

    #[test]
    fn urgency_applies_empty_priority_value_coefficient() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.uda.priority..coefficient", "2.5");
        let task = task_with(&[], now);

        assert_close(calculate_urgency(&task, now, &config), 2.5);
    }

    #[test]
    fn urgency_age_uses_configured_age_max() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.age.coefficient", "2.0");
        config.set("urgency.age.max", "10");
        let task = task_with(&[("entry", &(now - Duration::days(5)).to_rfc3339())], now);

        assert_close(calculate_urgency(&task, now, &config), 1.0);
    }

    #[test]
    fn urgency_age_max_zero_means_full_age_urgency() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.age.coefficient", "2.0");
        config.set("urgency.age.max", "0");
        let task = task_with(&[("entry", &now.to_rfc3339())], now);

        assert_close(calculate_urgency(&task, now, &config), 2.0);
    }

    #[test]
    fn urgency_due_uses_taskwarrior_twenty_one_day_ramp() {
        let now = Utc.with_ymd_and_hms(2026, 7, 18, 12, 0, 0).unwrap();
        let mut config = blank_urgency_config();
        config.set("urgency.due.coefficient", "10.0");
        let task = task_with(&[("due", &(now + Duration::hours(25)).to_rfc3339())], now);

        assert_close(calculate_urgency(&task, now, &config), 6.936);
    }
}
