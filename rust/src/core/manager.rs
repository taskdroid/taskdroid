use super::error::{Result, TaskError};
use super::models::{CreateTaskParams, TaskSnapshot, UpdateTaskParams};
use super::query::{Pagination, Query, QueryResult, SortField, TaskFilter};
use super::query_language::matches_query;
use super::utils::{
    parse_date_opt_str_strict, parse_date_opt_strict, parse_iso8601, task_snapshot_from_task,
};
use std::collections::HashSet;
use std::path::PathBuf;
use std::str::FromStr;
use std::sync::Mutex;
use std::thread::{self, JoinHandle};
use taskchampion::{
    Annotation, Operation, Operations, Replica, ServerConfig, Status as TcStatus, StorageConfig,
    Tag, Uuid,
    chrono::{DateTime, Datelike, Duration, NaiveDate, Utc, Weekday},
};
use tokio::sync::{mpsc, oneshot};
use tracing::{debug, info, warn};

const WORKER_QUEUE_CAPACITY: usize = 256;
const DEFAULT_RECURRENCE_LIMIT: usize = 1;
const RECUR_LIMIT_UDA_KEY: &str = "taskdroid.recurrence.limit";

type WorkerReply<T> = oneshot::Sender<Result<T>>;

enum WorkerCommand {
    LoadProfile {
        directory_path: String,
        reply: WorkerReply<()>,
    },
    QueryTasks {
        query: Query,
        reply: WorkerReply<QueryResult>,
    },
    GetTask {
        uuid_str: String,
        reply: WorkerReply<TaskSnapshot>,
    },
    CountUndoPoints {
        reply: WorkerReply<usize>,
    },
    Undo {
        reply: WorkerReply<bool>,
    },
    AddTask {
        params: CreateTaskParams,
        reply: WorkerReply<String>,
    },
    UpdateTask {
        uuid_str: String,
        params: UpdateTaskParams,
        reply: WorkerReply<()>,
    },
    DeleteTasks {
        uuid_strs: Vec<String>,
        reply: WorkerReply<()>,
    },
    DeleteTaskSingle {
        uuid_str: String,
        reply: WorkerReply<()>,
    },
    DeleteTaskSeries {
        uuid_str: String,
        reply: WorkerReply<()>,
    },
    CompleteTasks {
        uuid_strs: Vec<String>,
        reply: WorkerReply<()>,
    },
    DoneTaskSingle {
        uuid_str: String,
        reply: WorkerReply<()>,
    },
    DoneTaskSeries {
        uuid_str: String,
        reply: WorkerReply<()>,
    },
    StartTasks {
        uuid_strs: Vec<String>,
        reply: WorkerReply<()>,
    },
    StopTasks {
        uuid_strs: Vec<String>,
        reply: WorkerReply<()>,
    },
    Sync {
        url: String,
        client_id: String,
        encryption_secret: String,
        reply: WorkerReply<()>,
    },
    ExportTasks {
        include_deleted: bool,
        reply: WorkerReply<String>,
    },
    ImportTasks {
        json_data: String,
        reply: WorkerReply<usize>,
    },
    Shutdown,
}

impl WorkerCommand {
    fn kind(&self) -> &'static str {
        match self {
            Self::LoadProfile { .. } => "load_profile",
            Self::QueryTasks { .. } => "query_tasks",
            Self::GetTask { .. } => "get_task",
            Self::CountUndoPoints { .. } => "count_undo_points",
            Self::Undo { .. } => "undo",
            Self::AddTask { .. } => "add_task",
            Self::UpdateTask { .. } => "update_task",
            Self::DeleteTasks { .. } => "delete_tasks",
            Self::DeleteTaskSingle { .. } => "delete_task_single",
            Self::DeleteTaskSeries { .. } => "delete_task_series",
            Self::CompleteTasks { .. } => "complete_tasks",
            Self::DoneTaskSingle { .. } => "done_task_single",
            Self::DoneTaskSeries { .. } => "done_task_series",
            Self::StartTasks { .. } => "start_tasks",
            Self::StopTasks { .. } => "stop_tasks",
            Self::Sync { .. } => "sync",
            Self::ExportTasks { .. } => "export_tasks",
            Self::ImportTasks { .. } => "import_tasks",
            Self::Shutdown => "shutdown",
        }
    }

    fn is_slow(&self) -> bool {
        matches!(
            self,
            Self::Sync { .. } | Self::ImportTasks { .. } | Self::ExportTasks { .. }
        )
    }
}

struct WorkerState {
    replica: Option<Replica>,
}

impl WorkerState {
    fn new() -> Self {
        Self { replica: None }
    }

    fn replica_mut(&mut self) -> Result<&mut Replica> {
        self.replica
            .as_mut()
            .ok_or_else(|| TaskError::conflict("Profile not loaded"))
    }

    fn load_profile(&mut self, directory_path: String) -> Result<()> {
        let mut path = PathBuf::from(directory_path);
        path.push("taskdb");

        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| TaskError::storage(format!("Failed to create directory: {e}")))?;
        }

        let storage = StorageConfig::OnDisk {
            taskdb_dir: path,
            create_if_missing: true,
            access_mode: taskchampion::storage::AccessMode::ReadWrite,
        }
        .into_storage()
        .map_err(|e| TaskError::storage(format!("Storage error: {e}")))?;

        self.replica = Some(Replica::new(storage));
        Ok(())
    }

    fn query_tasks(&mut self, query: Query) -> Result<QueryResult> {
        let started_at = std::time::Instant::now();
        let replica = self.replica_mut()?;
        Self::apply_maintenance(replica)?;
        let all_tasks: Vec<_> = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?
            .into_iter()
            .collect();

        let mut filtered: Vec<TaskSnapshot> = all_tasks
            .into_iter()
            .filter(|(_, task)| matches_filter(task, &query.filter))
            .map(|(_, task)| task_snapshot_from_task(task))
            .collect();

        sort_snapshots(&mut filtered, query.sort.field, query.sort.descending);

        let total = filtered.len();
        let tasks = filtered
            .into_iter()
            .skip(query.pagination.offset)
            .take(query.pagination.limit)
            .collect::<Vec<_>>();
        let next_offset = if query.pagination.offset + tasks.len() < total {
            Some(query.pagination.offset + tasks.len())
        } else {
            None
        };

        debug!(
            command = "query_tasks",
            total,
            elapsed_ms = started_at.elapsed().as_millis(),
            "completed task query"
        );

        Ok(QueryResult {
            tasks,
            total,
            next_offset,
        })
    }

    fn get_task(&mut self, uuid_str: String) -> Result<TaskSnapshot> {
        let uuid = parse_uuid(&uuid_str)?;
        let replica = self.replica_mut()?;
        Self::apply_maintenance(replica)?;
        let task = replica
            .get_task(uuid)
            .map_err(|e| TaskError::storage(format!("Failed to fetch task: {e}")))?
            .ok_or_else(|| TaskError::not_found(format!("Task `{uuid_str}` not found")))?;
        Ok(task_snapshot_from_task(task))
    }

    fn count_undo_points(&mut self) -> Result<usize> {
        let replica = self.replica_mut()?;
        replica
            .num_undo_points()
            .map_err(|e| TaskError::storage(format!("Failed to count undo points: {e}")))
    }

    fn undo(&mut self) -> Result<bool> {
        let replica = self.replica_mut()?;
        let undo_ops = replica
            .get_undo_operations()
            .map_err(|e| TaskError::storage(format!("Failed to get undo operations: {e}")))?;
        if undo_ops.is_empty() {
            return Ok(false);
        }
        replica
            .commit_reversed_operations(undo_ops)
            .map_err(|e| TaskError::storage(format!("Failed to apply undo operations: {e}")))?;
        Ok(true)
    }

    fn add_task(&mut self, params: CreateTaskParams) -> Result<String> {
        let replica = self.replica_mut()?;
        let mut ops = Operations::new();
        ops.push(Operation::UndoPoint);
        let recurrence = normalize_recurrence(params.recurrence);

        if recurrence.is_some() && params.due.is_none() {
            return Err(TaskError::invalid_input(
                "Recurring tasks require a due date",
            ));
        }

        if let Some(rule) = recurrence.as_deref() {
            if parse_recurrence_rule(rule).is_none() {
                return Err(TaskError::invalid_input(format!(
                    "Unsupported recurrence rule: {rule}"
                )));
            }
        }

        let status = if recurrence.is_some() {
            super::models::TaskStatus::Recurring
        } else if matches!(params.status, super::models::TaskStatus::Recurring) {
            return Err(TaskError::invalid_input(
                "Recurring tasks require a recurrence rule",
            ));
        } else {
            params.status
        };

        let uuid = Uuid::new_v4();
        let mut task = replica
            .create_task(uuid, &mut ops)
            .map_err(|e| TaskError::storage(format!("Failed to create task: {e}")))?;

        task.set_description(params.description, &mut ops)
            .map_err(|e| TaskError::invalid_input(format!("Invalid description: {e}")))?;
        task.set_status(status.into(), &mut ops)
            .map_err(|e| TaskError::invalid_input(format!("Invalid status: {e}")))?;
        task.set_entry(Some(Utc::now()), &mut ops)
            .map_err(|e| TaskError::storage(format!("Failed to set entry: {e}")))?;

        if let Some(project) = params.project {
            task.set_value("project", Some(project), &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid project: {e}")))?;
        }
        if let Some(priority) = params.priority {
            task.set_priority(priority, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid priority: {e}")))?;
        }
        for tag in params.tags {
            let parsed = Tag::from_str(&tag)
                .map_err(|e| TaskError::invalid_input(format!("Invalid tag `{tag}`: {e}")))?;
            task.add_tag(&parsed, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Failed to add tag `{tag}`: {e}")))?;
        }
        if let Some(due) = params.due {
            task.set_due(parse_date_opt_strict(&due)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid due date: {e}")))?;
        }
        if let Some(wait) = params.wait {
            task.set_wait(parse_date_opt_strict(&wait)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid wait date: {e}")))?;
        }
        if let Some(scheduled) = params.scheduled {
            task.set_value("sched", parse_date_opt_str_strict(&scheduled)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid scheduled date: {e}")))?;
        }
        task.set_value("recur", recurrence, &mut ops)
            .map_err(|e| TaskError::invalid_input(format!("Invalid recurrence: {e}")))?;
        if let Some(until) = params.until {
            task.set_value("until", parse_date_opt_str_strict(&until)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid until date: {e}")))?;
        }
        for uda in params.udas {
            task.set_user_defined_attribute(uda.key, uda.value, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid UDA: {e}")))?;
        }

        replica
            .commit_operations(ops)
            .map_err(|e| TaskError::storage(format!("Failed to save task: {e}")))?;
        Self::apply_maintenance(replica)?;
        Ok(uuid.to_string())
    }

    fn update_task(&mut self, uuid_str: String, params: UpdateTaskParams) -> Result<()> {
        let uuid = parse_uuid(&uuid_str)?;
        let replica = self.replica_mut()?;
        let original_task = replica
            .get_task(uuid)
            .map_err(|e| TaskError::storage(format!("Failed to fetch task: {e}")))?
            .ok_or_else(|| TaskError::not_found(format!("Task `{uuid_str}` not found")))?;
        let original_status = original_task.get_status();
        let mut ops = Operations::new();
        ops.push(Operation::UndoPoint);
        let mut task = original_task;

        if let Some(description) = params.description {
            task.set_description(description, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid description: {e}")))?;
        }
        if let Some(status) = params.status {
            task.set_status(status.into(), &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid status: {e}")))?;
        }
        if let Some(project) = params.project {
            let value = if project.is_empty() {
                None
            } else {
                Some(project)
            };
            task.set_value("project", value, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid project: {e}")))?;
        }
        if let Some(priority) = params.priority {
            task.set_priority(priority, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid priority: {e}")))?;
        }
        for tag in params.add_tags {
            let parsed = Tag::from_str(&tag)
                .map_err(|e| TaskError::invalid_input(format!("Invalid tag `{tag}`: {e}")))?;
            task.add_tag(&parsed, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Failed to add tag `{tag}`: {e}")))?;
        }
        for tag in params.remove_tags {
            let parsed = Tag::from_str(&tag)
                .map_err(|e| TaskError::invalid_input(format!("Invalid tag `{tag}`: {e}")))?;
            task.remove_tag(&parsed, &mut ops).map_err(|e| {
                TaskError::invalid_input(format!("Failed to remove tag `{tag}`: {e}"))
            })?;
        }
        if let Some(note) = params.add_annotation {
            task.add_annotation(
                Annotation {
                    entry: Utc::now(),
                    description: note,
                },
                &mut ops,
            )
            .map_err(|e| TaskError::invalid_input(format!("Failed to add annotation: {e}")))?;
        }
        for entry_str in params.remove_annotations {
            if let Ok(entry) = parse_iso8601(&entry_str) {
                task.remove_annotation(entry, &mut ops).map_err(|e| {
                    TaskError::invalid_input(format!("Failed to remove annotation: {e}"))
                })?;
            } else {
                warn!(command = "update_task", entry = %entry_str, "ignored invalid annotation entry");
            }
        }
        let has_due_after_update = params
            .due
            .as_ref()
            .map(|due| !due.is_empty())
            .unwrap_or_else(|| task.get_due().is_some());

        if let Some(due) = params.due {
            task.set_due(parse_date_opt_strict(&due)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid due date: {e}")))?;
        }
        if let Some(wait) = params.wait {
            task.set_wait(parse_date_opt_strict(&wait)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid wait date: {e}")))?;
        }
        if let Some(scheduled) = params.scheduled {
            task.set_value("sched", parse_date_opt_str_strict(&scheduled)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid scheduled date: {e}")))?;
        }
        if let Some(recurrence) = params.recurrence {
            let normalized = normalize_recurrence(Some(recurrence));

            if normalized.is_none()
                && matches!(params.status, Some(super::models::TaskStatus::Recurring))
            {
                return Err(TaskError::invalid_input(
                    "Recurring status requires a recurrence rule",
                ));
            }

            if let Some(rule) = normalized.as_deref() {
                if parse_recurrence_rule(rule).is_none() {
                    return Err(TaskError::invalid_input(format!(
                        "Unsupported recurrence rule: {rule}"
                    )));
                }
            }

            if normalized.is_some() {
                if !has_due_after_update {
                    return Err(TaskError::invalid_input(
                        "Recurring tasks require a due date",
                    ));
                }
            }

            task.set_value("recur", normalized.clone(), &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid recurrence: {e}")))?;
            if params.status.is_none() {
                let next_status = if normalized.is_some() {
                    super::models::TaskStatus::Recurring
                } else if matches!(task.get_status(), TcStatus::Recurring) {
                    super::models::TaskStatus::Pending
                } else {
                    super::models::TaskStatus::from(task.get_status())
                };
                task.set_status(next_status.into(), &mut ops).map_err(|e| {
                    TaskError::conflict(format!("Failed to update recurrence status: {e}"))
                })?;
            }
        } else if matches!(params.status, Some(super::models::TaskStatus::Recurring))
            && task.get_value("recur").is_none()
        {
            return Err(TaskError::invalid_input(
                "Recurring status requires a recurrence rule",
            ));
        }

        if original_status == TcStatus::Recurring && task.get_status() != TcStatus::Recurring {
            if task.get_value("recur").is_some() {
                task.set_value("recur", None::<String>, &mut ops)
                    .map_err(|e| {
                        TaskError::invalid_input(format!("Failed to clear recurrence rule: {e}"))
                    })?;
            }
            if task.get_value("mask").is_some() {
                task.set_value("mask", None::<String>, &mut ops)
                    .map_err(|e| {
                        TaskError::invalid_input(format!("Failed to clear recurrence mask: {e}"))
                    })?;
            }
        }

        if let Some(until) = params.until {
            task.set_value("until", parse_date_opt_str_strict(&until)?, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid until date: {e}")))?;
        }
        for dependency in params.add_depends {
            let parsed = parse_uuid(&dependency)?;
            task.add_dependency(parsed, &mut ops).map_err(|e| {
                TaskError::invalid_input(format!("Failed to add dependency `{dependency}`: {e}"))
            })?;
        }
        for dependency in params.remove_depends {
            let parsed = parse_uuid(&dependency)?;
            task.remove_dependency(parsed, &mut ops).map_err(|e| {
                TaskError::invalid_input(format!("Failed to remove dependency `{dependency}`: {e}"))
            })?;
        }
        if let Some(start) = params.start {
            if start && !task.is_active() {
                task.start(&mut ops)
                    .map_err(|e| TaskError::conflict(format!("Failed to start task: {e}")))?;
            } else if !start && task.is_active() {
                task.stop(&mut ops)
                    .map_err(|e| TaskError::conflict(format!("Failed to stop task: {e}")))?;
            }
        }
        for uda in params.set_udas {
            if uda.value.is_empty() {
                task.remove_user_defined_attribute(uda.key, &mut ops)
                    .map_err(|e| TaskError::invalid_input(format!("Invalid UDA removal: {e}")))?;
            } else {
                task.set_user_defined_attribute(uda.key, uda.value, &mut ops)
                    .map_err(|e| TaskError::invalid_input(format!("Invalid UDA: {e}")))?;
            }
        }
        task.set_modified(Utc::now(), &mut ops)
            .map_err(|e| TaskError::storage(format!("Failed to set modified time: {e}")))?;
        replica
            .commit_operations(ops)
            .map_err(|e| TaskError::storage(format!("Failed to update task: {e}")))?;

        let updated_status = task.get_status();

        if original_status == TcStatus::Recurring && updated_status != TcStatus::Recurring {
            cleanup_recurring_children(replica, uuid, true)?;
        } else if original_status == TcStatus::Recurring || updated_status == TcStatus::Recurring {
            let changed = propagate_template_fields_to_children(replica, uuid)?;
            if changed {
                debug!(
                    command = "update_task",
                    template = %uuid,
                    "propagated template changes to recurring children"
                );
            }
        }

        Self::apply_maintenance(replica)?;
        Ok(())
    }

    fn delete_tasks(&mut self, uuid_strs: Vec<String>) -> Result<()> {
        self.set_status_for_tasks(uuid_strs, Some(TcStatus::Deleted), false)
    }

    fn delete_task_single(&mut self, uuid_str: String) -> Result<()> {
        self.set_status_for_tasks(vec![uuid_str], Some(TcStatus::Deleted), false)
    }

    fn delete_task_series(&mut self, uuid_str: String) -> Result<()> {
        let template_uuid = parse_uuid(&uuid_str)?;
        let replica = self.replica_mut()?;

        let template = match replica.get_task(template_uuid) {
            Ok(Some(t)) => t,
            Ok(None) => return Err(TaskError::not_found(format!("Task `{}` not found", uuid_str))),
            Err(e) => return Err(TaskError::storage(format!("Failed to fetch task: {}", e))),
        };

        let is_template = template.get_status() == TcStatus::Recurring;
        let series_uuid = if is_template {
            template_uuid.to_string()
        } else {
            template
                .get_value("parent")
                .map(|s| s.to_string())
                .ok_or_else(|| TaskError::invalid_input(format!("Task `{}` is not part of a recurring series", uuid_str)))?
        };

        let all_tasks = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {}", e)))?;

        let mut uuids_to_delete = vec![series_uuid.clone()];

        let child_uuids: Vec<String> = all_tasks
            .iter()
            .filter_map(|(_, task)| {
                let parent = task.get_value("parent").map(|s| s.to_string());
                if parent.as_deref() == Some(series_uuid.as_str()) {
                    Some(task.get_uuid().to_string())
                } else {
                    None
                }
            })
            .collect();

        uuids_to_delete.extend(child_uuids);

        if !uuids_to_delete.is_empty() {
            self.set_status_for_tasks(uuids_to_delete, Some(TcStatus::Deleted), false)?;
        }

        Ok(())
    }

    fn complete_tasks(&mut self, uuid_strs: Vec<String>) -> Result<()> {
        self.set_status_for_tasks(uuid_strs, None, true)
    }

    fn done_task_single(&mut self, uuid_str: String) -> Result<()> {
        self.set_status_for_tasks(vec![uuid_str], None, true)
    }

    fn done_task_series(&mut self, uuid_str: String) -> Result<()> {
        let template_uuid = parse_uuid(&uuid_str)?;
        let replica = self.replica_mut()?;

        let template = match replica.get_task(template_uuid) {
            Ok(Some(t)) => t,
            Ok(None) => return Err(TaskError::not_found(format!("Task `{}` not found", uuid_str))),
            Err(e) => return Err(TaskError::storage(format!("Failed to fetch task: {}", e))),
        };

        let is_template = template.get_status() == TcStatus::Recurring;
        let series_uuid = if is_template {
            template_uuid.to_string()
        } else {
            template
                .get_value("parent")
                .map(|s| s.to_string())
                .ok_or_else(|| TaskError::invalid_input(format!("Task `{}` is not part of a recurring series", uuid_str)))?
        };

        let all_tasks = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {}", e)))?;

        let mut uuids_to_complete = vec![series_uuid.clone()];

        let child_uuids: Vec<String> = all_tasks
            .iter()
            .filter_map(|(_, task)| {
                let parent = task.get_value("parent").map(|s| s.to_string());
                if parent.as_deref() == Some(series_uuid.as_str()) {
                    Some(task.get_uuid().to_string())
                } else {
                    None
                }
            })
            .collect();

        uuids_to_complete.extend(child_uuids);

        if !uuids_to_complete.is_empty() {
            self.set_status_for_tasks(uuids_to_complete, None, true)?;
        }

        Ok(())
    }

    fn start_tasks(&mut self, uuid_strs: Vec<String>) -> Result<()> {
        self.set_active_for_tasks(uuid_strs, true)
    }

    fn stop_tasks(&mut self, uuid_strs: Vec<String>) -> Result<()> {
        self.set_active_for_tasks(uuid_strs, false)
    }

    fn sync(&mut self, url: String, client_id: String, encryption_secret: String) -> Result<()> {
        let started_at = std::time::Instant::now();
        let config = ServerConfig::Remote {
            url,
            client_id: parse_uuid(&client_id)?,
            encryption_secret: encryption_secret.into_bytes(),
        };
        let mut server = config
            .into_server()
            .map_err(|e| TaskError::sync(format!("Failed to create server config: {e}")))?;
        let replica = self.replica_mut()?;
        replica
            .sync(&mut server, false)
            .map_err(|e| TaskError::sync(format!("Sync failed: {e}")))?;
        replica
            .rebuild_working_set(true)
            .map_err(|e| TaskError::storage(format!("Failed to rebuild working set: {e}")))?;
        Self::apply_maintenance(replica)?;
        info!(
            command = "sync",
            elapsed_ms = started_at.elapsed().as_millis(),
            "completed sync"
        );
        Ok(())
    }

    fn export_tasks(&mut self, include_deleted: bool) -> Result<String> {
        let replica = self.replica_mut()?;
        Self::apply_maintenance(replica)?;
        let snapshots = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?
            .into_iter()
            .filter(|(_, task)| include_deleted || task.get_status() != TcStatus::Deleted)
            .map(|(_, task)| task_snapshot_from_task(task))
            .collect::<Vec<_>>();
        serde_json::to_string_pretty(&snapshots)
            .map_err(|e| TaskError::storage(format!("Failed to serialize tasks: {e}")))
    }

    fn import_tasks(&mut self, json_data: String) -> Result<usize> {
        let snapshots: Vec<TaskSnapshot> = serde_json::from_str(&json_data)
            .map_err(|e| TaskError::invalid_input(format!("Invalid import payload: {e}")))?;
        let count = snapshots.len();
        let replica = self.replica_mut()?;
        let mut ops = Operations::new();
        ops.push(Operation::UndoPoint);

        for snapshot in snapshots {
            let core = snapshot.core;
            let uuid = match Uuid::from_str(&core.uuid) {
                Ok(parsed) => parsed,
                Err(_) => Uuid::new_v4(),
            };
            let mut task = match replica
                .get_task(uuid)
                .map_err(|e| TaskError::storage(format!("Failed to fetch task for import: {e}")))?
            {
                Some(task) => task,
                None => replica.create_task(uuid, &mut ops).map_err(|e| {
                    TaskError::storage(format!("Failed to create imported task: {e}"))
                })?,
            };

            task.set_description(core.description, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid description: {e}")))?;
            task.set_status(core.status.into(), &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid status: {e}")))?;
            if !core.entry.trim().is_empty() {
                let entry = parse_iso8601(&core.entry).map_err(|e| {
                    TaskError::invalid_input(format!(
                        "Invalid entry date for task `{}`: {e}",
                        core.uuid
                    ))
                })?;
                task.set_entry(Some(entry), &mut ops)
                    .map_err(|e| TaskError::storage(format!("Failed to set entry: {e}")))?;
            }

            let due = parse_optional_datetime(core.due.as_deref(), "due", &core.uuid)?;
            let wait = parse_optional_datetime(core.wait.as_deref(), "wait", &core.uuid)?;
            let scheduled =
                parse_optional_datetime_string(core.scheduled.as_deref(), "scheduled", &core.uuid)?;
            let end = parse_optional_datetime_string(core.end.as_deref(), "end", &core.uuid)?;
            let until = parse_optional_datetime_string(core.until.as_deref(), "until", &core.uuid)?;

            task.set_due(due, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid due date: {e}")))?;
            task.set_wait(wait, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid wait date: {e}")))?;
            task.set_value("sched", scheduled, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid scheduled date: {e}")))?;
            task.set_value("end", end, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid end date: {e}")))?;
            task.set_value("until", until, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid until date: {e}")))?;
            task.set_value("recur", core.recurrence, &mut ops)
                .map_err(|e| TaskError::invalid_input(format!("Invalid recurrence: {e}")))?;

            if let Some(project) = core.project {
                task.set_value("project", Some(project), &mut ops)
                    .map_err(|e| TaskError::invalid_input(format!("Invalid project: {e}")))?;
            }
            if let Some(priority) = core.priority {
                task.set_priority(priority, &mut ops)
                    .map_err(|e| TaskError::invalid_input(format!("Invalid priority: {e}")))?;
            }
            if let Some(start_val) = &core.start {
                task.set_value("start", Some(start_val.clone()), &mut ops).map_err(|e| {
                    TaskError::conflict(format!("Failed to activate imported task: {e}"))
                })?;
            }
            for tag in core.tags {
                match Tag::from_str(&tag) {
                    Ok(parsed) => {
                        if let Err(error) = task.add_tag(&parsed, &mut ops) {
                            warn!(command = "import_tasks", tag = %tag, error = %error, "failed to add tag");
                        }
                    }
                    Err(error) => {
                        warn!(command = "import_tasks", tag = %tag, error = %error, "ignored invalid tag");
                    }
                }
            }
            for dependency in core.depends {
                match Uuid::from_str(&dependency) {
                    Ok(parsed) => {
                        if let Err(error) = task.add_dependency(parsed, &mut ops) {
                            warn!(command = "import_tasks", dependency = %dependency, error = %error, "failed to add dependency");
                        }
                    }
                    Err(error) => {
                        warn!(command = "import_tasks", dependency = %dependency, error = %error, "ignored invalid dependency");
                    }
                }
            }
            for uda in core.udas {
                task.set_user_defined_attribute(uda.key, uda.value, &mut ops)
                    .map_err(|e| TaskError::invalid_input(format!("Invalid UDA: {e}")))?;
            }
            for annotation in core.annotations {
                if let Ok(entry) = parse_iso8601(&annotation.entry) {
                    task.add_annotation(
                        Annotation {
                            entry,
                            description: annotation.description,
                        },
                        &mut ops,
                    )
                    .map_err(|e| {
                        TaskError::invalid_input(format!("Failed to add annotation: {e}"))
                    })?;
                } else {
                    warn!(command = "import_tasks", entry = %annotation.entry, "ignored invalid annotation entry");
                }
            }
        }

        replica
            .commit_operations(ops)
            .map_err(|e| TaskError::storage(format!("Failed to import tasks: {e}")))?;
        Self::apply_maintenance(replica)?;
        Ok(count)
    }

    fn apply_maintenance(replica: &mut Replica) -> Result<()> {
        Self::expire_until_tasks(replica)?;
        Self::ensure_recurrence_instances(replica)
    }

    fn expire_until_tasks(replica: &mut Replica) -> Result<()> {
        let now = Utc::now();
        let all_tasks = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?;

        let mut ops = Operations::new();
        let mut changed = false;
        for (_, mut task) in all_tasks {
            if task.get_status() == TcStatus::Deleted {
                continue;
            }
            let Some(until_raw) = task.get_value("until") else {
                continue;
            };
            let Ok(until) = parse_iso8601(until_raw) else {
                continue;
            };
            if until <= now {
                task.set_status(TcStatus::Deleted, &mut ops).map_err(|e| {
                    TaskError::conflict(format!("Failed to expire task `{}`: {e}", task.get_uuid()))
                })?;
                task.set_modified(now, &mut ops).map_err(|e| {
                    TaskError::storage(format!("Failed to set modified for expired task: {e}"))
                })?;
                changed = true;
            }
        }

        if changed {
            replica
                .commit_operations(ops)
                .map_err(|e| TaskError::storage(format!("Failed to expire tasks: {e}")))?;
        }
        Ok(())
    }

    fn ensure_recurrence_instances(replica: &mut Replica) -> Result<()> {
        let all_tasks = replica
            .all_tasks()
            .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?;

        let templates: Vec<_> = all_tasks
            .iter()
            .filter_map(|(_, task)| {
                if task.get_status() == TcStatus::Recurring {
                    Some(task.clone())
                } else {
                    None
                }
            })
            .collect();

        if templates.is_empty() {
            return Ok(());
        }

        let now = Utc::now();
        let mut ops = Operations::new();
        let mut changed = false;

        for mut template in templates {
            let Some(recur) = template.get_value("recur") else {
                continue;
            };
            let Some(template_due) = template.get_due() else {
                continue;
            };
            let recurrence = match parse_recurrence_rule(recur) {
                Some(rule) => rule,
                None => continue,
            };
            let template_uuid = template.get_uuid().to_string();
            let until = template
                .get_value("until")
                .and_then(|value| parse_iso8601(value).ok());
            let recurrence_limit_uda = get_uda_value(&template, RECUR_LIMIT_UDA_KEY);

            let mut indexed_children: Vec<(usize, taskchampion::Task)> = all_tasks
                .iter()
                .filter_map(|(_, task)| {
                    if task.get_value("parent") != Some(template_uuid.as_str()) {
                        return None;
                    }
                    let index = task
                        .get_value("imask")
                        .and_then(|v| v.parse::<usize>().ok())
                        .unwrap_or(0);
                    Some((index, task.clone()))
                })
                .collect();

            indexed_children.sort_by_key(|(index, _)| *index);

            let recurrence_limit = template_recurrence_limit(&template);

            while indexed_children
                .iter()
                .filter(|(_, child)| child.get_status() == TcStatus::Pending)
                .count()
                < recurrence_limit
            {
                let next_index = indexed_children
                    .iter()
                    .map(|(index, _)| *index)
                    .max()
                    .map(|max| max + 1)
                    .unwrap_or(0);

                if let Some(due) = due_for_index(template_due, recurrence, next_index) {
                    if until.map(|limit| due > limit).unwrap_or(false) {
                        break;
                    } else {
                        let child_uuid = Uuid::new_v4();
                        let mut child = replica.create_task(child_uuid, &mut ops).map_err(|e| {
                            TaskError::storage(format!(
                                "Failed to create recurring instance for `{template_uuid}`: {e}"
                            ))
                        })?;

                        child
                            .set_description(template.get_description().to_string(), &mut ops)
                            .map_err(|e| {
                                TaskError::invalid_input(format!(
                                    "Invalid recurring instance description: {e}"
                                ))
                            })?;
                        child.set_status(TcStatus::Pending, &mut ops).map_err(|e| {
                            TaskError::invalid_input(format!(
                                "Invalid recurring instance status: {e}"
                            ))
                        })?;
                        child.set_entry(Some(now), &mut ops).map_err(|e| {
                            TaskError::storage(format!(
                                "Failed to set recurring instance entry: {e}"
                            ))
                        })?;
                        child.set_due(Some(due), &mut ops).map_err(|e| {
                            TaskError::invalid_input(format!("Invalid recurring due date: {e}"))
                        })?;
                        if let Some(wait) = template.get_wait() {
                            child.set_wait(Some(wait), &mut ops).map_err(|e| {
                                TaskError::invalid_input(format!(
                                    "Failed to propagate wait to recurring child: {e}"
                                ))
                            })?;
                        }
                        if let Some(sched) = template.get_value("sched") {
                            child
                                .set_value("sched", Some(sched.to_string()), &mut ops)
                                .map_err(|e| {
                                    TaskError::invalid_input(format!(
                                        "Failed to propagate scheduled date to recurring child: {e}"
                                    ))
                                })?;
                        }
                        child
                            .set_value("recur", Some(recur.to_string()), &mut ops)
                            .map_err(|e| {
                                TaskError::invalid_input(format!("Invalid recurrence: {e}"))
                            })?;
                        child
                            .set_value("parent", Some(template_uuid.clone()), &mut ops)
                            .map_err(|e| {
                                TaskError::invalid_input(format!(
                                    "Invalid recurring parent link: {e}"
                                ))
                            })?;
                        child
                            .set_value("imask", Some(next_index.to_string()), &mut ops)
                            .map_err(|e| {
                                TaskError::invalid_input(format!(
                                    "Invalid recurring mask index: {e}"
                                ))
                            })?;
                        if let Some(until_value) = template.get_value("until") {
                            child
                                .set_value("until", Some(until_value.to_string()), &mut ops)
                                .map_err(|e| {
                                    TaskError::invalid_input(format!(
                                        "Invalid recurring until date: {e}"
                                    ))
                                })?;
                        }
                        if let Some(project) = template.get_value("project") {
                            child
                                .set_value("project", Some(project.to_string()), &mut ops)
                                .map_err(|e| {
                                    TaskError::invalid_input(format!(
                                        "Invalid recurring project: {e}"
                                    ))
                                })?;
                        }

                        let priority = template.get_priority();
                        if !priority.is_empty() {
                            child
                                .set_priority(priority.to_string(), &mut ops)
                                .map_err(|e| {
                                    TaskError::invalid_input(format!(
                                        "Invalid recurring priority: {e}"
                                    ))
                                })?;
                        }

                        for tag in template.get_tags() {
                            if let Err(error) = child.add_tag(&tag, &mut ops) {
                                warn!(
                                    command = "ensure_recurrence_instances",
                                    tag = %tag,
                                    error = %error,
                                    "failed to copy recurring tag"
                                );
                            }
                        }
                        if let Some(limit) = recurrence_limit_uda.as_deref() {
                            child
                                .set_user_defined_attribute(
                                    RECUR_LIMIT_UDA_KEY.to_string(),
                                    limit.to_string(),
                                    &mut ops,
                                )
                                .map_err(|e| {
                                    TaskError::invalid_input(format!(
                                        "Invalid recurrence limit attribute: {e}"
                                    ))
                                })?;
                        }
                        indexed_children.push((next_index, child));
                        indexed_children.sort_by_key(|(index, _)| *index);
                        changed = true;
                    }
                } else {
                    break;
                }
            }

            let mask = indexed_children
                .iter()
                .map(|(_, child)| recurrence_mask_char(child))
                .collect::<String>();
            let existing_mask = template.get_value("mask").map(str::to_string);
            let next_mask = if mask.is_empty() { None } else { Some(mask) };
            if existing_mask != next_mask {
                template
                    .set_value("mask", next_mask, &mut ops)
                    .map_err(|e| {
                        TaskError::invalid_input(format!("Invalid recurrence mask: {e}"))
                    })?;
                changed = true;
            }
        }

        if changed {
            replica
                .commit_operations(ops)
                .map_err(|e| TaskError::storage(format!("Failed to maintain recurrence: {e}")))?;
        }

        Ok(())
    }

    fn set_status_for_tasks(
        &mut self,
        uuid_strs: Vec<String>,
        status: Option<TcStatus>,
        complete: bool,
    ) -> Result<()> {
        let replica = self.replica_mut()?;
        let mut ops = Operations::new();
        ops.push(Operation::UndoPoint);
        for uuid_str in &uuid_strs {
            match Uuid::from_str(uuid_str) {
                Ok(uuid) => {
                    if let Some(mut task) = replica
                        .get_task(uuid)
                        .map_err(|e| TaskError::storage(format!("Failed to fetch task: {e}")))?
                    {
                        if complete {
                            task.done(&mut ops).map_err(|e| {
                                TaskError::conflict(format!(
                                    "Failed to complete task `{uuid_str}`: {e}"
                                ))
                            })?;
                        } else if let Some(status) = status.as_ref() {
                            task.set_status(status.clone(), &mut ops).map_err(|e| {
                                TaskError::conflict(format!(
                                    "Failed to update task `{uuid_str}`: {e}"
                                ))
                            })?;
                        }
                        task.set_modified(Utc::now(), &mut ops).map_err(|e| {
                            TaskError::storage(format!("Failed to set modified time: {e}"))
                        })?;
                    }
                }
                Err(_) => {
                    warn!(command = "set_status_for_tasks", uuid = %uuid_str, "ignored invalid UUID")
                }
            }
        }
        replica
            .commit_operations(ops)
            .map_err(|e| TaskError::storage(format!("Failed to commit task updates: {e}")))?;
        Self::apply_maintenance(replica)?;
        Ok(())
    }

    fn set_active_for_tasks(&mut self, uuid_strs: Vec<String>, active: bool) -> Result<()> {
        let replica = self.replica_mut()?;
        let mut ops = Operations::new();
        ops.push(Operation::UndoPoint);
        for uuid_str in &uuid_strs {
            match Uuid::from_str(uuid_str) {
                Ok(uuid) => {
                    if let Some(mut task) = replica
                        .get_task(uuid)
                        .map_err(|e| TaskError::storage(format!("Failed to fetch task: {e}")))?
                    {
                        if active && !task.is_active() {
                            task.start(&mut ops).map_err(|e| {
                                TaskError::conflict(format!(
                                    "Failed to start task `{uuid_str}`: {e}"
                                ))
                            })?;
                        } else if !active && task.is_active() {
                            task.stop(&mut ops).map_err(|e| {
                                TaskError::conflict(format!(
                                    "Failed to stop task `{uuid_str}`: {e}"
                                ))
                            })?;
                        }
                        task.set_modified(Utc::now(), &mut ops).map_err(|e| {
                            TaskError::storage(format!("Failed to set modified time: {e}"))
                        })?;
                    }
                }
                Err(_) => {
                    warn!(command = "set_active_for_tasks", uuid = %uuid_str, "ignored invalid UUID")
                }
            }
        }
        replica
            .commit_operations(ops)
            .map_err(|e| TaskError::storage(format!("Failed to commit task updates: {e}")))?;
        Self::apply_maintenance(replica)?;
        Ok(())
    }
}

fn get_uda_value(task: &taskchampion::Task, key: &str) -> Option<String> {
    task.get_user_defined_attributes()
        .find_map(|(uda_key, uda_value)| {
            if uda_key == key {
                Some(uda_value.to_string())
            } else {
                None
            }
        })
}

fn is_virtual_tag_name(tag: &str) -> bool {
    matches!(
        tag,
        "BLOCKED"
            | "UNBLOCKED"
            | "BLOCKING"
            | "DUE"
            | "DUETODAY"
            | "TODAY"
            | "OVERDUE"
            | "WEEK"
            | "MONTH"
            | "QUARTER"
            | "YEAR"
            | "ACTIVE"
            | "SCHEDULED"
            | "PARENT"
            | "CHILD"
            | "UNTIL"
            | "WAITING"
            | "ANNOTATED"
            | "READY"
            | "YESTERDAY"
            | "TOMORROW"
            | "TAGGED"
            | "PENDING"
            | "COMPLETED"
            | "DELETED"
            | "UDA"
            | "ORPHAN"
            | "PRIORITY"
            | "PROJECT"
            | "LATEST"
    )
}

fn explicit_tag_names(task: &taskchampion::Task) -> HashSet<String> {
    task.get_tags()
        .map(|tag| tag.to_string())
        .filter(|tag| !is_virtual_tag_name(tag))
        .collect()
}

fn template_recurrence_limit(template: &taskchampion::Task) -> usize {
    get_uda_value(template, RECUR_LIMIT_UDA_KEY)
        .and_then(|value| value.trim().parse::<usize>().ok())
        .filter(|value| *value > 0)
        .unwrap_or(DEFAULT_RECURRENCE_LIMIT)
}

fn propagate_template_fields_to_children(
    replica: &mut Replica,
    template_uuid: Uuid,
) -> Result<bool> {
    let template = replica
        .get_task(template_uuid)
        .map_err(|e| TaskError::storage(format!("Failed to fetch recurring template: {e}")))?
        .ok_or_else(|| {
            TaskError::not_found(format!(
                "Recurring template `{template_uuid}` no longer exists"
            ))
        })?;

    if template.get_status() != TcStatus::Recurring {
        return Ok(false);
    }

    let template_uuid_str = template_uuid.to_string();
    let template_description = template.get_description().to_string();
    let template_project = template.get_value("project").map(str::to_string);
    let template_priority = template.get_priority().to_string();
    let template_recur = template.get_value("recur").map(str::to_string);
    let template_until = template.get_value("until").map(str::to_string);
    let template_sched = template.get_value("sched").map(str::to_string);
    let template_wait = template.get_wait();
    let template_limit = get_uda_value(&template, RECUR_LIMIT_UDA_KEY);
    let template_tags = explicit_tag_names(&template);

    let all_tasks = replica
        .all_tasks()
        .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?;

    let mut ops = Operations::new();
    let mut changed = false;

    for (_, mut child) in all_tasks {
        if child.get_value("parent") != Some(template_uuid_str.as_str()) {
            continue;
        }
        if child.get_status() != TcStatus::Pending {
            continue;
        }

        if child.get_description() != template_description {
            child
                .set_description(template_description.clone(), &mut ops)
                .map_err(|e| {
                    TaskError::conflict(format!(
                        "Failed to propagate description to child `{}`: {e}",
                        child.get_uuid()
                    ))
                })?;
            changed = true;
        }

        if child.get_value("project") != template_project.as_deref() {
            child
                .set_value("project", template_project.clone(), &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate project: {e}")))?;
            changed = true;
        }

        if child.get_priority() != template_priority {
            child
                .set_priority(template_priority.clone(), &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate priority: {e}")))?;
            changed = true;
        }

        if child.get_value("recur") != template_recur.as_deref() {
            child
                .set_value("recur", template_recur.clone(), &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate recurrence: {e}")))?;
            changed = true;
        }

        if child.get_value("until") != template_until.as_deref() {
            child
                .set_value("until", template_until.clone(), &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate until: {e}")))?;
            changed = true;
        }

        if child.get_value("sched") != template_sched.as_deref() {
            child
                .set_value("sched", template_sched.clone(), &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate scheduled: {e}")))?;
            changed = true;
        }

        if child.get_wait() != template_wait {
            child
                .set_wait(template_wait, &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to propagate wait: {e}")))?;
            changed = true;
        }

        let child_limit = get_uda_value(&child, RECUR_LIMIT_UDA_KEY);
        if child_limit != template_limit {
            if let Some(limit) = template_limit.as_deref() {
                child
                    .set_user_defined_attribute(
                        RECUR_LIMIT_UDA_KEY.to_string(),
                        limit.to_string(),
                        &mut ops,
                    )
                    .map_err(|e| {
                        TaskError::conflict(format!("Failed to propagate recurrence limit: {e}"))
                    })?;
            } else {
                child
                    .remove_user_defined_attribute(RECUR_LIMIT_UDA_KEY.to_string(), &mut ops)
                    .map_err(|e| {
                        TaskError::conflict(format!("Failed to clear recurrence limit: {e}"))
                    })?;
            }
            changed = true;
        }

        let child_tags = explicit_tag_names(&child);
        for stale in child_tags.difference(&template_tags) {
            if let Ok(tag) = Tag::from_str(stale) {
                child.remove_tag(&tag, &mut ops).map_err(|e| {
                    TaskError::conflict(format!("Failed to remove stale child tag `{stale}`: {e}"))
                })?;
                changed = true;
            }
        }
        for missing in template_tags.difference(&child_tags) {
            if let Ok(tag) = Tag::from_str(missing) {
                child.add_tag(&tag, &mut ops).map_err(|e| {
                    TaskError::conflict(format!("Failed to add missing child tag `{missing}`: {e}"))
                })?;
                changed = true;
            }
        }
    }

    if changed {
        replica.commit_operations(ops).map_err(|e| {
            TaskError::storage(format!("Failed to propagate recurring updates: {e}"))
        })?;
    }

    Ok(changed)
}

fn cleanup_recurring_children(
    replica: &mut Replica,
    template_uuid: Uuid,
    pending_only: bool,
) -> Result<bool> {
    let template_uuid_str = template_uuid.to_string();
    let all_tasks = replica
        .all_tasks()
        .map_err(|e| TaskError::storage(format!("Failed to fetch tasks: {e}")))?;

    let mut ops = Operations::new();
    let mut changed = false;

    for (_, mut task) in all_tasks {
        if task.get_value("parent") != Some(template_uuid_str.as_str()) {
            continue;
        }
        if pending_only && task.get_status() != TcStatus::Pending {
            continue;
        }

        if task.get_value("parent").is_some() {
            task.set_value("parent", None::<String>, &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to clear parent link: {e}")))?;
            changed = true;
        }
        if task.get_value("imask").is_some() {
            task.set_value("imask", None::<String>, &mut ops)
                .map_err(|e| TaskError::conflict(format!("Failed to clear mask index: {e}")))?;
            changed = true;
        }
        if task.get_value("recur").is_some() {
            task.set_value("recur", None::<String>, &mut ops)
                .map_err(|e| {
                    TaskError::conflict(format!("Failed to clear recurrence metadata: {e}"))
                })?;
            changed = true;
        }
    }

    if changed {
        replica.commit_operations(ops).map_err(|e| {
            TaskError::storage(format!("Failed to cleanup recurring children: {e}"))
        })?;
    }

    Ok(changed)
}

fn parse_optional_datetime(
    value: Option<&str>,
    field: &str,
    uuid: &str,
) -> Result<Option<DateTime<Utc>>> {
    match value {
        Some(raw) => parse_iso8601(raw).map(Some).map_err(|e| {
            TaskError::invalid_input(format!("Invalid {field} date for task `{uuid}`: {e}"))
        }),
        None => Ok(None),
    }
}

fn parse_optional_datetime_string(
    value: Option<&str>,
    field: &str,
    uuid: &str,
) -> Result<Option<String>> {
    parse_optional_datetime(value, field, uuid).map(|opt| opt.map(|dt| dt.to_rfc3339()))
}

fn matches_filter(task: &taskchampion::Task, filter: &TaskFilter) -> bool {
    let task_status = super::utils::map_tc_to_status(task.get_status());
    if let Some(status) = filter.status {
        if task_status != status {
            return false;
        }
    }

    if let Some(project) = &filter.project {
        if task.get_value("project").as_deref() != Some(project.as_str()) {
            return false;
        }
    }
    if let Some(term) = &filter.search_term {
        if !matches_query(task, term) {
            return false;
        }
    }
    for tag in &filter.tags {
        if let Ok(parsed) = Tag::from_str(tag) {
            if !task.has_tag(&parsed) {
                return false;
            }
        }
    }
    true
}

fn sort_snapshots(tasks: &mut [TaskSnapshot], field: SortField, descending: bool) {
    tasks.sort_by(|a, b| {
        let ordering = match field {
            SortField::Urgency => a
                .computed
                .urgency
                .partial_cmp(&b.computed.urgency)
                .unwrap_or(std::cmp::Ordering::Equal),
            SortField::Due => match (&a.core.due, &b.core.due) {
                (Some(a_due), Some(b_due)) => a_due.cmp(b_due),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            },
            SortField::Created => {
                let a_entry = if a.core.entry.is_empty() {
                    None
                } else {
                    Some(&a.core.entry)
                };
                let b_entry = if b.core.entry.is_empty() {
                    None
                } else {
                    Some(&b.core.entry)
                };
                match (a_entry, b_entry) {
                    (Some(a_e), Some(b_e)) => a_e.cmp(b_e),
                    (Some(_), None) => std::cmp::Ordering::Less,
                    (None, Some(_)) => std::cmp::Ordering::Greater,
                    (None, None) => std::cmp::Ordering::Equal,
                }
            }
        };

        if descending {
            ordering.reverse()
        } else {
            ordering
        }
        .then_with(|| a.core.uuid.cmp(&b.core.uuid))
    });
}

fn parse_uuid(value: &str) -> Result<Uuid> {
    Uuid::from_str(value)
        .map_err(|e| TaskError::invalid_input(format!("Invalid UUID `{value}`: {e}")))
}

fn normalize_recurrence(value: Option<String>) -> Option<String> {
    value.and_then(|entry| {
        let trimmed = entry.trim().to_string();
        if trimmed.is_empty() {
            None
        } else {
            Some(trimmed)
        }
    })
}

#[derive(Clone, Copy)]
enum RecurrenceRule {
    Daily,
    Weekly,
    Biweekly,
    Monthly,
    Yearly,
    Weekdays,
}

fn parse_recurrence_rule(value: &str) -> Option<RecurrenceRule> {
    let normalized = value.trim().to_lowercase();
    match normalized.as_str() {
        "daily" => Some(RecurrenceRule::Daily),
        "weekly" => Some(RecurrenceRule::Weekly),
        "biweekly" | "bi-weekly" => Some(RecurrenceRule::Biweekly),
        "monthly" => Some(RecurrenceRule::Monthly),
        "yearly" | "annual" => Some(RecurrenceRule::Yearly),
        "weekdays" | "weekday" => Some(RecurrenceRule::Weekdays),
        _ => None,
    }
}

fn due_for_index(
    base_due: DateTime<Utc>,
    recurrence: RecurrenceRule,
    index: usize,
) -> Option<DateTime<Utc>> {
    match recurrence {
        RecurrenceRule::Daily => Some(base_due + Duration::days(index as i64)),
        RecurrenceRule::Weekly => Some(base_due + Duration::weeks(index as i64)),
        RecurrenceRule::Biweekly => Some(base_due + Duration::weeks((index * 2) as i64)),
        RecurrenceRule::Monthly => add_months(base_due, index as i32),
        RecurrenceRule::Yearly => add_months(base_due, (index as i32) * 12),
        RecurrenceRule::Weekdays => {
            if index == 0 {
                return Some(base_due);
            }
            let mut current = base_due;
            let mut remaining = index;
            while remaining > 0 {
                current += Duration::days(1);
                match current.weekday() {
                    Weekday::Sat | Weekday::Sun => {}
                    _ => remaining -= 1,
                }
            }
            Some(current)
        }
    }
}

fn add_months(date: DateTime<Utc>, months: i32) -> Option<DateTime<Utc>> {
    if months == 0 {
        return Some(date);
    }

    let naive = date.naive_utc();
    let base_month = naive.month0() as i32;
    let total_months = base_month + months;
    let year = naive.year() + total_months.div_euclid(12);
    let month0 = total_months.rem_euclid(12) as u32;
    let month = month0 + 1;
    let day = naive.day();
    let max_day = days_in_month(year, month);
    let clamped_day = day.min(max_day);
    let date_part = NaiveDate::from_ymd_opt(year, month, clamped_day)?;
    let time_part = naive.time();
    let shifted = date_part.and_time(time_part);
    Some(DateTime::from_naive_utc_and_offset(shifted, Utc))
}

fn days_in_month(year: i32, month: u32) -> u32 {
    let next_month = if month == 12 {
        NaiveDate::from_ymd_opt(year + 1, 1, 1)
    } else {
        NaiveDate::from_ymd_opt(year, month + 1, 1)
    };
    let this_month = NaiveDate::from_ymd_opt(year, month, 1);
    match (this_month, next_month) {
        (Some(this), Some(next)) => (next - this).num_days() as u32,
        _ => 28,
    }
}

fn recurrence_mask_char(task: &taskchampion::Task) -> char {
    match task.get_status() {
        TcStatus::Completed => '+',
        TcStatus::Deleted => 'X',
        _ => {
            if task.is_waiting() {
                'W'
            } else {
                '-'
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use taskchampion::StorageConfig;

    #[test]
    fn recurring_child_inherits_wait() {
        let storage = StorageConfig::InMemory.into_storage().unwrap();
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();

        let mut template = replica.create_task(template_uuid, &mut ops).unwrap();
        template.set_status(TcStatus::Recurring, &mut ops).unwrap();
        template
            .set_value("recur", Some("daily".to_string()), &mut ops)
            .unwrap();
        template
            .set_due(
                Some(parse_iso8601("2026-04-01T00:00:00Z").unwrap()),
                &mut ops,
            )
            .unwrap();

        let wait = parse_iso8601("2026-04-05T00:00:00Z").unwrap();
        template.set_wait(Some(wait), &mut ops).unwrap();

        replica.commit_operations(ops).unwrap();

        WorkerState::ensure_recurrence_instances(&mut replica).unwrap();

        let children: Vec<_> = replica
            .all_tasks()
            .unwrap()
            .into_iter()
            .filter(|(_, t)| t.get_value("parent") == Some(template_uuid.to_string().as_str()))
            .collect();

        assert!(!children.is_empty());
        let child = &children[0].1;

        assert_eq!(child.get_wait(), Some(wait));
    }

    #[test]
    fn recurring_child_inherits_scheduled() {
        let storage = StorageConfig::InMemory.into_storage().unwrap();
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();

        let mut template = replica.create_task(template_uuid, &mut ops).unwrap();
        template.set_status(TcStatus::Recurring, &mut ops).unwrap();
        template
            .set_value("recur", Some("daily".to_string()), &mut ops)
            .unwrap();
        template
            .set_due(
                Some(parse_iso8601("2026-04-01T00:00:00Z").unwrap()),
                &mut ops,
            )
            .unwrap();
        template
            .set_value("sched", Some("2026-04-10T00:00:00Z".to_string()), &mut ops)
            .unwrap();

        replica.commit_operations(ops).unwrap();

        WorkerState::ensure_recurrence_instances(&mut replica).unwrap();

        let children: Vec<_> = replica
            .all_tasks()
            .unwrap()
            .into_iter()
            .filter(|(_, t)| t.get_value("parent") == Some(template_uuid.to_string().as_str()))
            .collect();

        assert!(!children.is_empty());
        let child = &children[0].1;

        assert_eq!(child.get_value("sched"), Some("2026-04-10T00:00:00Z"));
    }

    #[test]
    fn recurring_demotion_cleans_pending_children_only() {
        let storage = StorageConfig::InMemory.into_storage().unwrap();
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();

        let mut template = replica.create_task(template_uuid, &mut ops).unwrap();
        template.set_status(TcStatus::Recurring, &mut ops).unwrap();
        template
            .set_value("recur", Some("daily".to_string()), &mut ops)
            .unwrap();
        template
            .set_due(
                Some(parse_iso8601("2026-04-01T00:00:00Z").unwrap()),
                &mut ops,
            )
            .unwrap();

        let mut child = replica.create_task(Uuid::new_v4(), &mut ops).unwrap();
        child.set_status(TcStatus::Pending, &mut ops).unwrap();
        child
            .set_value("parent", Some(template_uuid.to_string()), &mut ops)
            .unwrap();

        replica.commit_operations(ops).unwrap();

        cleanup_recurring_children(&mut replica, template_uuid, true).unwrap();

        let child = replica.get_task(child.get_uuid()).unwrap().unwrap();

        assert!(child.get_value("parent").is_none());
    }

    #[test]
    fn parses_supported_recurrence_rules() {
        assert!(matches!(
            parse_recurrence_rule("daily"),
            Some(RecurrenceRule::Daily)
        ));
        assert!(matches!(
            parse_recurrence_rule("bi-weekly"),
            Some(RecurrenceRule::Biweekly)
        ));
        assert!(matches!(
            parse_recurrence_rule("weekdays"),
            Some(RecurrenceRule::Weekdays)
        ));
        assert!(parse_recurrence_rule("fortnightly").is_none());
    }

    #[test]
    fn monthly_recurrence_clamps_day_for_short_months() {
        let base = parse_iso8601("2026-01-31T00:00:00Z").expect("base date must parse");
        let next = due_for_index(base, RecurrenceRule::Monthly, 1).expect("next date");
        assert_eq!(next.to_rfc3339(), "2026-02-28T00:00:00+00:00");
    }

    #[test]
    fn weekday_recurrence_skips_weekends() {
        let friday = parse_iso8601("2026-04-03T00:00:00Z").expect("base date must parse");
        let monday = due_for_index(friday, RecurrenceRule::Weekdays, 1).expect("next date");
        assert_eq!(monday.weekday(), Weekday::Mon);
    }

    #[test]
    fn template_recurrence_limit_uses_uda() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();
        let uuid = Uuid::new_v4();
        let mut task = replica
            .create_task(uuid, &mut ops)
            .expect("create template task");
        task.set_status(TcStatus::Recurring, &mut ops)
            .expect("set recurring status");
        task.set_user_defined_attribute(RECUR_LIMIT_UDA_KEY.to_string(), "3".to_string(), &mut ops)
            .expect("set recurrence limit UDA");
        replica.commit_operations(ops).expect("commit setup");

        let loaded = replica
            .get_task(uuid)
            .expect("load template")
            .expect("template exists");
        assert_eq!(template_recurrence_limit(&loaded), 3);
    }

    #[test]
    fn template_update_propagates_description_to_pending_children() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();
        let child_uuid = Uuid::new_v4();

        let mut template = replica
            .create_task(template_uuid, &mut ops)
            .expect("create template");
        template
            .set_description("Parent A".to_string(), &mut ops)
            .expect("set template description");
        template
            .set_status(TcStatus::Recurring, &mut ops)
            .expect("set template status");
        template
            .set_value("recur", Some("weekly".to_string()), &mut ops)
            .expect("set recur");
        template
            .set_due(
                Some(parse_iso8601("2026-04-01T00:00:00Z").expect("parse due")),
                &mut ops,
            )
            .expect("set due");

        let mut child = replica
            .create_task(child_uuid, &mut ops)
            .expect("create child");
        child
            .set_description("Parent A".to_string(), &mut ops)
            .expect("set child description");
        child
            .set_status(TcStatus::Pending, &mut ops)
            .expect("set child status");
        child
            .set_value("parent", Some(template_uuid.to_string()), &mut ops)
            .expect("set parent");
        child
            .set_value("imask", Some("0".to_string()), &mut ops)
            .expect("set imask");

        replica.commit_operations(ops).expect("commit setup");

        let mut ops = Operations::new();
        let mut template = replica
            .get_task(template_uuid)
            .expect("load template")
            .expect("template exists");
        template
            .set_description("Parent B".to_string(), &mut ops)
            .expect("update template description");
        replica
            .commit_operations(ops)
            .expect("commit template update");

        let changed = propagate_template_fields_to_children(&mut replica, template_uuid)
            .expect("propagation succeeds");
        assert!(changed);

        let child = replica
            .get_task(child_uuid)
            .expect("load child")
            .expect("child exists");
        assert_eq!(child.get_description(), "Parent B");
    }

    #[test]
    fn demoted_recurring_template_clears_recur_and_mask() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();
        let mut template = replica
            .create_task(template_uuid, &mut ops)
            .expect("create template");
        template
            .set_description("Template".to_string(), &mut ops)
            .expect("set description");
        template
            .set_status(TcStatus::Recurring, &mut ops)
            .expect("set status");
        template
            .set_value("recur", Some("weekly".to_string()), &mut ops)
            .expect("set recur");
        template
            .set_value("mask", Some("-".to_string()), &mut ops)
            .expect("set mask");

        replica.commit_operations(ops).expect("commit setup");

        let mut state = WorkerState {
            replica: Some(replica),
        };
        state
            .update_task(
                template_uuid.to_string(),
                UpdateTaskParams {
                    description: None,
                    status: Some(super::super::models::TaskStatus::Pending),
                    project: None,
                    priority: None,
                    due: None,
                    wait: None,
                    scheduled: None,
                    recurrence: None,
                    until: None,
                    add_tags: vec![],
                    remove_tags: vec![],
                    add_annotation: None,
                    remove_annotations: vec![],
                    add_depends: vec![],
                    remove_depends: vec![],
                    start: None,
                    set_udas: vec![],
                },
            )
            .expect("update task");

        let mut replica = state.replica.take().expect("replica available");
        let updated = replica
            .get_task(template_uuid)
            .expect("load template")
            .expect("template exists");
        assert_eq!(updated.get_status(), TcStatus::Pending);
        assert_eq!(updated.get_value("recur"), None);
        assert_eq!(updated.get_value("mask"), None);
    }

    #[test]
    fn create_task_rejects_invalid_due_date() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let replica = Replica::new(storage);
        let mut state = WorkerState {
            replica: Some(replica),
        };

        let result = state.add_task(CreateTaskParams {
            description: "Bad due".to_string(),
            status: super::super::models::TaskStatus::Pending,
            project: None,
            priority: None,
            tags: vec![],
            due: Some("not-a-date".to_string()),
            wait: None,
            scheduled: None,
            recurrence: None,
            until: None,
            udas: vec![],
        });

        assert!(result.is_err());
    }

    #[test]
    fn import_rejects_invalid_critical_dates() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let replica = Replica::new(storage);
        let mut state = WorkerState {
            replica: Some(replica),
        };

        let payload = serde_json::to_string(&vec![TaskSnapshot {
            core: super::super::models::TaskCore {
                uuid: Uuid::new_v4().to_string(),
                description: "Imported".to_string(),
                status: super::super::models::TaskStatus::Pending,
                project: None,
                priority: None,
                tags: vec![],
                entry: Utc::now().to_rfc3339(),
                modified: Utc::now().to_rfc3339(),
                due: Some("bad-due".to_string()),
                wait: None,
                start: None,
                end: None,
                scheduled: None,
                until: None,
                depends: vec![],
                recurrence: None,
                annotations: vec![],
                udas: vec![],
                parent_uuid: None,
                recurrence_index: None,
            },
            computed: super::super::models::TaskComputed {
                urgency: 0.0,
                is_active: false,
                is_blocked: false,
                is_blocking: false,
                is_waiting: false,
                is_recurring_template: false,
                is_recurring_instance: false,
                series_root_uuid: None,
            },
        }])
        .expect("serialize payload");

        let result = state.import_tasks(payload);
        assert!(result.is_err());
    }

    #[test]
    fn cleanup_detaches_pending_children_only() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let mut replica = Replica::new(storage);
        let mut ops = Operations::new();

        let template_uuid = Uuid::new_v4();
        let pending_child_uuid = Uuid::new_v4();
        let completed_child_uuid = Uuid::new_v4();

        let mut template = replica
            .create_task(template_uuid, &mut ops)
            .expect("create template");
        template
            .set_status(TcStatus::Recurring, &mut ops)
            .expect("set template status");
        template
            .set_value("recur", Some("weekly".to_string()), &mut ops)
            .expect("set template recur");

        let mut pending = replica
            .create_task(pending_child_uuid, &mut ops)
            .expect("create pending child");
        pending
            .set_status(TcStatus::Pending, &mut ops)
            .expect("set pending status");
        pending
            .set_value("parent", Some(template_uuid.to_string()), &mut ops)
            .expect("set pending parent");
        pending
            .set_value("imask", Some("0".to_string()), &mut ops)
            .expect("set pending imask");
        pending
            .set_value("recur", Some("weekly".to_string()), &mut ops)
            .expect("set pending recur");

        let mut completed = replica
            .create_task(completed_child_uuid, &mut ops)
            .expect("create completed child");
        completed
            .set_status(TcStatus::Completed, &mut ops)
            .expect("set completed status");
        completed
            .set_value("parent", Some(template_uuid.to_string()), &mut ops)
            .expect("set completed parent");
        completed
            .set_value("imask", Some("1".to_string()), &mut ops)
            .expect("set completed imask");
        completed
            .set_value("recur", Some("weekly".to_string()), &mut ops)
            .expect("set completed recur");

        replica.commit_operations(ops).expect("commit setup");

        let changed = cleanup_recurring_children(&mut replica, template_uuid, true)
            .expect("cleanup should succeed");
        assert!(changed);

        let pending = replica
            .get_task(pending_child_uuid)
            .expect("load pending")
            .expect("pending exists");
        assert_eq!(pending.get_value("parent"), None);
        assert_eq!(pending.get_value("imask"), None);
        assert_eq!(pending.get_value("recur"), None);

        let completed = replica
            .get_task(completed_child_uuid)
            .expect("load completed")
            .expect("completed exists");
        let template_uuid_text = template_uuid.to_string();
        assert_eq!(
            completed.get_value("parent"),
            Some(template_uuid_text.as_str())
        );
        assert_eq!(completed.get_value("imask"), Some("1"));
        assert_eq!(completed.get_value("recur"), Some("weekly"));
    }

    #[test]
    fn export_returns_all_tasks_full_scan() {
        let storage = StorageConfig::InMemory
            .into_storage()
            .expect("in-memory storage");
        let mut state = WorkerState {
            replica: Some(Replica::new(storage)),
        };

        for index in 0..3 {
            state
                .add_task(CreateTaskParams {
                    description: format!("Task {index}"),
                    status: super::super::models::TaskStatus::Pending,
                    project: None,
                    priority: None,
                    tags: vec![],
                    due: None,
                    wait: None,
                    scheduled: None,
                    recurrence: None,
                    until: None,
                    udas: vec![],
                })
                .expect("add task");
        }

        let exported = state.export_tasks(false).expect("export should succeed");
        let snapshots: Vec<TaskSnapshot> =
            serde_json::from_str(&exported).expect("parse exported payload");
        assert_eq!(snapshots.len(), 3);
    }
}

fn worker_loop(mut receiver: mpsc::Receiver<WorkerCommand>) {
    let mut state = WorkerState::new();
    while let Some(command) = receiver.blocking_recv() {
        let kind = command.kind();
        let is_slow = command.is_slow();
        let started_at = std::time::Instant::now();
        debug!(command = kind, slow = is_slow, "worker started command");

        let should_break = match command {
            WorkerCommand::LoadProfile {
                directory_path,
                reply,
            } => {
                let _ = reply.send(state.load_profile(directory_path));
                false
            }
            WorkerCommand::QueryTasks { query, reply } => {
                let _ = reply.send(state.query_tasks(query));
                false
            }
            WorkerCommand::GetTask { uuid_str, reply } => {
                let _ = reply.send(state.get_task(uuid_str));
                false
            }
            WorkerCommand::CountUndoPoints { reply } => {
                let _ = reply.send(state.count_undo_points());
                false
            }
            WorkerCommand::Undo { reply } => {
                let _ = reply.send(state.undo());
                false
            }
            WorkerCommand::AddTask { params, reply } => {
                let _ = reply.send(state.add_task(params));
                false
            }
            WorkerCommand::UpdateTask {
                uuid_str,
                params,
                reply,
            } => {
                let _ = reply.send(state.update_task(uuid_str, params));
                false
            }
            WorkerCommand::DeleteTasks { uuid_strs, reply } => {
                let _ = reply.send(state.delete_tasks(uuid_strs));
                false
            }
            WorkerCommand::DeleteTaskSingle { uuid_str, reply } => {
                let _ = reply.send(state.delete_task_single(uuid_str));
                false
            }
            WorkerCommand::DeleteTaskSeries { uuid_str, reply } => {
                let _ = reply.send(state.delete_task_series(uuid_str));
                false
            }
            WorkerCommand::CompleteTasks { uuid_strs, reply } => {
                let _ = reply.send(state.complete_tasks(uuid_strs));
                false
            }
            WorkerCommand::DoneTaskSingle { uuid_str, reply } => {
                let _ = reply.send(state.done_task_single(uuid_str));
                false
            }
            WorkerCommand::DoneTaskSeries { uuid_str, reply } => {
                let _ = reply.send(state.done_task_series(uuid_str));
                false
            }
            WorkerCommand::StartTasks { uuid_strs, reply } => {
                let _ = reply.send(state.start_tasks(uuid_strs));
                false
            }
            WorkerCommand::StopTasks { uuid_strs, reply } => {
                let _ = reply.send(state.stop_tasks(uuid_strs));
                false
            }
            WorkerCommand::Sync {
                url,
                client_id,
                encryption_secret,
                reply,
            } => {
                let _ = reply.send(state.sync(url, client_id, encryption_secret));
                false
            }
            WorkerCommand::ExportTasks {
                include_deleted,
                reply,
            } => {
                let _ = reply.send(state.export_tasks(include_deleted));
                false
            }
            WorkerCommand::ImportTasks { json_data, reply } => {
                let _ = reply.send(state.import_tasks(json_data));
                false
            }
            WorkerCommand::Shutdown => {
                info!("worker received shutdown");
                true
            }
        };

        if should_break {
            break;
        }

        let elapsed_ms = started_at.elapsed().as_millis();
        if is_slow {
            info!(command = kind, elapsed_ms, "worker completed slow command");
        } else {
            debug!(command = kind, elapsed_ms, "worker completed command");
        }
    }
}

/// async task engine that owns TaskChampion access on a single worker thread
pub struct TaskManager {
    sender: mpsc::Sender<WorkerCommand>,
    worker: Mutex<Option<JoinHandle<()>>>,
}

impl TaskManager {
    /// creates a new engine handle
    pub fn new() -> Self {
        let (sender, receiver) = mpsc::channel(WORKER_QUEUE_CAPACITY);
        let worker = thread::Builder::new()
            .name("taskdroid-task-worker".to_string())
            .spawn(move || worker_loop(receiver))
            .expect("failed to spawn taskdroid task worker");
        Self {
            sender,
            worker: Mutex::new(Some(worker)),
        }
    }

    async fn request<T>(
        &self,
        make_command: impl FnOnce(WorkerReply<T>) -> WorkerCommand,
    ) -> Result<T> {
        let (reply_tx, reply_rx) = oneshot::channel();
        let command = make_command(reply_tx);
        let kind = command.kind();
        let remaining_capacity = self.sender.capacity();
        debug!(
            command = kind,
            remaining_capacity, "enqueueing worker command"
        );
        self.sender
            .send(command)
            .await
            .map_err(|_| TaskError::busy("Task worker is unavailable"))?;
        reply_rx
            .await
            .map_err(|_| TaskError::internal("Task worker dropped the response".to_string()))?
    }

    /// loads or creates the profile-backed TaskChampion db
    pub async fn load_profile(&self, directory_path: String) -> Result<()> {
        self.request(|reply| WorkerCommand::LoadProfile {
            directory_path,
            reply,
        })
        .await
    }

    /// executes the query contract
    pub async fn query_tasks(&self, query: Query) -> Result<QueryResult> {
        self.request(|reply| WorkerCommand::QueryTasks { query, reply })
            .await
    }

    /// compatibility wrapper for the app's current list api
    pub async fn list_tasks(
        &self,
        filter: TaskFilter,
        pagination: Pagination,
    ) -> Result<QueryResult> {
        self.query_tasks(Query::from_filter(
            filter,
            pagination.offset,
            pagination.limit,
        ))
        .await
    }

    pub async fn get_task(&self, uuid_str: String) -> Result<TaskSnapshot> {
        self.request(|reply| WorkerCommand::GetTask { uuid_str, reply })
            .await
    }

    pub async fn count_undo_points(&self) -> Result<usize> {
        self.request(|reply| WorkerCommand::CountUndoPoints { reply })
            .await
    }

    pub async fn undo(&self) -> Result<bool> {
        self.request(|reply| WorkerCommand::Undo { reply }).await
    }

    pub async fn add_task(&self, params: CreateTaskParams) -> Result<String> {
        self.request(|reply| WorkerCommand::AddTask { params, reply })
            .await
    }

    pub async fn update_task(&self, uuid_str: String, params: UpdateTaskParams) -> Result<()> {
        self.request(|reply| WorkerCommand::UpdateTask {
            uuid_str,
            params,
            reply,
        })
        .await
    }

    pub async fn complete_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        self.request(|reply| WorkerCommand::CompleteTasks { uuid_strs, reply })
            .await
    }

    pub async fn done_task_single(&self, uuid_str: String) -> Result<()> {
        self.request(|reply| WorkerCommand::DoneTaskSingle { uuid_str, reply })
            .await
    }

    pub async fn done_task_series(&self, uuid_str: String) -> Result<()> {
        self.request(|reply| WorkerCommand::DoneTaskSeries { uuid_str, reply })
            .await
    }

    pub async fn delete_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        self.request(|reply| WorkerCommand::DeleteTasks { uuid_strs, reply })
            .await
    }

    pub async fn delete_task_single(&self, uuid_str: String) -> Result<()> {
        self.request(|reply| WorkerCommand::DeleteTaskSingle { uuid_str, reply })
            .await
    }

    pub async fn delete_task_series(&self, uuid_str: String) -> Result<()> {
        self.request(|reply| WorkerCommand::DeleteTaskSeries { uuid_str, reply })
            .await
    }

    pub async fn start_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        self.request(|reply| WorkerCommand::StartTasks { uuid_strs, reply })
            .await
    }

    pub async fn stop_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        self.request(|reply| WorkerCommand::StopTasks { uuid_strs, reply })
            .await
    }

    /// compatibility wrapper retaining the app's current naming
    pub async fn done_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        self.complete_tasks(uuid_strs).await
    }

    pub async fn sync(
        &self,
        url: String,
        client_id: String,
        encryption_secret: String,
    ) -> Result<()> {
        self.request(|reply| WorkerCommand::Sync {
            url,
            client_id,
            encryption_secret,
            reply,
        })
        .await
    }

    pub async fn export_tasks(&self, include_deleted: bool) -> Result<String> {
        self.request(|reply| WorkerCommand::ExportTasks {
            include_deleted,
            reply,
        })
        .await
    }

    pub async fn import_tasks(&self, json_data: String) -> Result<usize> {
        self.request(|reply| WorkerCommand::ImportTasks { json_data, reply })
            .await
    }
}

impl Drop for TaskManager {
    fn drop(&mut self) {
        match self.sender.try_send(WorkerCommand::Shutdown) {
            Ok(()) => debug!("queued worker shutdown"),
            Err(mpsc::error::TrySendError::Full(_)) => {
                warn!("task worker queue is full during drop; detaching worker thread")
            }
            Err(mpsc::error::TrySendError::Closed(_)) => {
                debug!("task worker already closed during drop")
            }
        }
        if let Ok(mut worker) = self.worker.lock() {
            if let Some(handle) = worker.take() {
                drop(handle);
            }
        }
    }
}
