use crate::core::{
    self, Pagination, QueryResult as CoreQueryResult, TaskSnapshot, TaskStatus as CoreTaskStatus,
};
use anyhow::{Result, anyhow};
use flutter_rust_bridge::frb;
use serde::{Deserialize, Serialize};

/// FRB-facing task status enum
#[frb]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TaskStatus {
    Pending,
    Completed,
    Deleted,
    Recurring,
}

impl From<CoreTaskStatus> for TaskStatus {
    fn from(value: CoreTaskStatus) -> Self {
        match value {
            CoreTaskStatus::Pending => Self::Pending,
            CoreTaskStatus::Completed => Self::Completed,
            CoreTaskStatus::Deleted => Self::Deleted,
            CoreTaskStatus::Recurring => Self::Recurring,
        }
    }
}

impl From<TaskStatus> for CoreTaskStatus {
    fn from(value: TaskStatus) -> Self {
        match value {
            TaskStatus::Pending => Self::Pending,
            TaskStatus::Completed => Self::Completed,
            TaskStatus::Deleted => Self::Deleted,
            TaskStatus::Recurring => Self::Recurring,
        }
    }
}

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskAnnotation {
    pub entry: String,
    pub description: String,
}

impl From<core::TaskAnnotation> for TaskAnnotation {
    fn from(value: core::TaskAnnotation) -> Self {
        Self {
            entry: value.entry,
            description: value.description,
        }
    }
}

impl From<TaskAnnotation> for core::TaskAnnotation {
    fn from(value: TaskAnnotation) -> Self {
        Self {
            entry: value.entry,
            description: value.description,
        }
    }
}

#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UdaPair {
    pub key: String,
    pub value: String,
}

impl From<core::UdaPair> for UdaPair {
    fn from(value: core::UdaPair) -> Self {
        Self {
            key: value.key,
            value: value.value,
        }
    }
}

impl From<UdaPair> for core::UdaPair {
    fn from(value: UdaPair) -> Self {
        Self {
            key: value.key,
            value: value.value,
        }
    }
}

/// UI-friendly task DTO exposed to Flutter.
#[frb]
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskView {
    pub uuid: String,
    pub description: String,
    pub status: TaskStatus,
    pub project: Option<String>,
    pub priority: Option<String>,
    pub tags: Vec<String>,
    pub entry: String,
    pub modified: String,
    pub due: Option<String>,
    pub wait: Option<String>,
    pub start: Option<String>,
    pub end: Option<String>,
    pub scheduled: Option<String>,
    pub until: Option<String>,
    pub depends: Vec<String>,
    pub recurrence: Option<String>,
    pub annotations: Vec<TaskAnnotation>,
    pub udas: Vec<UdaPair>,
    pub urgency: f32,
    pub is_active: bool,
    pub is_blocked: bool,
    pub is_blocking: bool,
    pub is_waiting: bool,
    pub parent_uuid: Option<String>,
    pub recurrence_index: Option<usize>,
    pub is_recurring_template: bool,
    pub is_recurring_instance: bool,
    pub series_root_uuid: Option<String>,
}

impl From<TaskSnapshot> for TaskView {
    fn from(value: TaskSnapshot) -> Self {
        Self {
            uuid: value.core.uuid,
            description: value.core.description,
            status: value.core.status.into(),
            project: value.core.project,
            priority: value.core.priority,
            tags: value.core.tags,
            entry: value.core.entry,
            modified: value.core.modified,
            due: value.core.due,
            wait: value.core.wait,
            start: value.core.start,
            end: value.core.end,
            scheduled: value.core.scheduled,
            until: value.core.until,
            depends: value.core.depends,
            recurrence: value.core.recurrence,
            annotations: value.core.annotations.into_iter().map(Into::into).collect(),
            udas: value.core.udas.into_iter().map(Into::into).collect(),
            urgency: value.computed.urgency,
            is_active: value.computed.is_active,
            is_blocked: value.computed.is_blocked,
            is_blocking: value.computed.is_blocking,
            is_waiting: value.computed.is_waiting,
            parent_uuid: value.core.parent_uuid,
            recurrence_index: value.core.recurrence_index,
            is_recurring_template: value.computed.is_recurring_template,
            is_recurring_instance: value.computed.is_recurring_instance,
            series_root_uuid: value.computed.series_root_uuid,
        }
    }
}

impl From<TaskView> for TaskSnapshot {
    fn from(value: TaskView) -> Self {
        Self {
            core: core::TaskCore {
                uuid: value.uuid,
                description: value.description,
                status: value.status.into(),
                project: value.project,
                priority: value.priority,
                tags: value.tags,
                entry: value.entry,
                modified: value.modified,
                due: value.due,
                wait: value.wait,
                start: value.start,
                end: value.end,
                scheduled: value.scheduled,
                until: value.until,
                depends: value.depends,
                recurrence: value.recurrence,
                annotations: value.annotations.into_iter().map(Into::into).collect(),
                udas: value.udas.into_iter().map(Into::into).collect(),
                parent_uuid: value.parent_uuid,
                recurrence_index: value.recurrence_index,
            },
            computed: core::TaskComputed {
                urgency: value.urgency,
                is_active: value.is_active,
                is_blocked: value.is_blocked,
                is_blocking: value.is_blocking,
                is_waiting: value.is_waiting,
                is_recurring_template: value.is_recurring_template,
                is_recurring_instance: value.is_recurring_instance,
                series_root_uuid: value.series_root_uuid,
            },
        }
    }
}

#[frb]
#[derive(Debug, Clone)]
pub struct TaskFilter {
    pub status: Option<TaskStatus>,
    pub project: Option<String>,
    pub tags: Vec<String>,
    pub search_term: Option<String>,
    pub offset: usize,
    pub limit: usize,
}

impl From<TaskFilter> for core::TaskFilter {
    fn from(value: TaskFilter) -> Self {
        Self {
            status: value.status.map(Into::into),
            project: value.project,
            tags: value.tags,
            search_term: value.search_term,
        }
    }
}

#[frb]
#[derive(Debug, Clone)]
pub struct TaskListResult {
    pub tasks: Vec<TaskView>,
    pub total_count: usize,
    pub next_offset: Option<usize>,
}

impl From<CoreQueryResult> for TaskListResult {
    fn from(value: CoreQueryResult) -> Self {
        Self {
            tasks: value.tasks.into_iter().map(Into::into).collect(),
            total_count: value.total,
            next_offset: value.next_offset,
        }
    }
}

#[frb]
#[derive(Debug, Clone)]
pub struct CreateTaskParams {
    pub description: String,
    pub status: TaskStatus,
    pub project: Option<String>,
    pub priority: Option<String>,
    pub tags: Vec<String>,
    pub due: Option<String>,
    pub wait: Option<String>,
    pub scheduled: Option<String>,
    pub recurrence: Option<String>,
    pub until: Option<String>,
    pub udas: Vec<UdaPair>,
}

impl From<CreateTaskParams> for core::CreateTaskParams {
    fn from(value: CreateTaskParams) -> Self {
        let mut udas = value.udas;
        let recurrence = value
            .recurrence
            .or_else(|| extract_recurrence_from_udas(&mut udas, false));
        let until = value
            .until
            .or_else(|| extract_uda_value(&mut udas, "until"));
        Self {
            description: value.description,
            status: value.status.into(),
            project: value.project,
            priority: value.priority,
            tags: value.tags,
            due: value.due,
            wait: value.wait,
            scheduled: value.scheduled,
            recurrence,
            until,
            udas: udas.into_iter().map(Into::into).collect(),
        }
    }
}

#[frb]
#[derive(Debug, Clone)]
pub struct UpdateTaskParams {
    pub description: Option<String>,
    pub status: Option<TaskStatus>,
    pub project: Option<String>,
    pub priority: Option<String>,
    pub due: Option<String>,
    pub wait: Option<String>,
    pub scheduled: Option<String>,
    pub recurrence: Option<String>,
    pub until: Option<String>,
    pub add_tags: Vec<String>,
    pub remove_tags: Vec<String>,
    pub add_annotation: Option<String>,
    pub remove_annotations: Vec<String>,
    pub add_depends: Vec<String>,
    pub remove_depends: Vec<String>,
    pub start: Option<bool>,
    pub set_udas: Vec<UdaPair>,
}

impl From<UpdateTaskParams> for core::UpdateTaskParams {
    fn from(value: UpdateTaskParams) -> Self {
        let mut set_udas = value.set_udas;
        let recurrence = value
            .recurrence
            .or_else(|| extract_recurrence_from_udas(&mut set_udas, true));
        let until = value
            .until
            .or_else(|| extract_uda_value(&mut set_udas, "until"));
        Self {
            description: value.description,
            status: value.status.map(Into::into),
            project: value.project,
            priority: value.priority,
            due: value.due,
            wait: value.wait,
            scheduled: value.scheduled,
            recurrence,
            until,
            add_tags: value.add_tags,
            remove_tags: value.remove_tags,
            add_annotation: value.add_annotation,
            remove_annotations: value.remove_annotations,
            add_depends: value.add_depends,
            remove_depends: value.remove_depends,
            start: value.start,
            set_udas: set_udas.into_iter().map(Into::into).collect(),
        }
    }
}

fn map_error<T>(result: core::Result<T>) -> Result<T> {
    result.map_err(|error| anyhow!(error.to_string()))
}

fn extract_recurrence_from_udas(udas: &mut Vec<UdaPair>, allow_empty: bool) -> Option<String> {
    let index = udas.iter().position(|pair| pair.key == "recur")?;
    let pair = udas.remove(index);
    let trimmed = pair.value.trim().to_string();
    if trimmed.is_empty() && !allow_empty {
        None
    } else {
        Some(trimmed)
    }
}

fn extract_uda_value(udas: &mut Vec<UdaPair>, key: &str) -> Option<String> {
    let index = udas.iter().position(|pair| pair.key == key)?;
    let pair = udas.remove(index);
    Some(pair.value.trim().to_string())
}

#[frb(opaque)]
pub struct TaskManager {
    inner: core::TaskManager,
}

#[frb]
impl TaskManager {
    #[frb(sync)]
    pub fn new() -> TaskManager {
        TaskManager {
            inner: core::TaskManager::new(),
        }
    }

    pub async fn load_profile(&self, directory_path: String) -> Result<()> {
        map_error(self.inner.load_profile(directory_path).await)
    }

    pub async fn list_tasks(&self, filter: TaskFilter) -> Result<TaskListResult> {
        let pagination = Pagination {
            offset: filter.offset,
            limit: filter.limit,
        };
        let core_filter: core::TaskFilter = filter.into();
        map_error(self.inner.list_tasks(core_filter, pagination).await).map(Into::into)
    }

    pub async fn get_task(&self, uuid_str: String) -> Result<TaskView> {
        map_error(self.inner.get_task(uuid_str).await).map(Into::into)
    }

    pub async fn count_undo_points(&self) -> Result<usize> {
        map_error(self.inner.count_undo_points().await)
    }

    pub async fn undo(&self) -> Result<bool> {
        map_error(self.inner.undo().await)
    }

    pub async fn add_task(&self, params: CreateTaskParams) -> Result<String> {
        map_error(self.inner.add_task(params.into()).await)
    }

    pub async fn set_recurrence_limit(&self, limit: usize) -> Result<()> {
        map_error(self.inner.set_recurrence_limit(limit).await)
    }

    pub async fn update_task(&self, uuid_str: String, params: UpdateTaskParams) -> Result<()> {
        map_error(self.inner.update_task(uuid_str, params.into()).await)
    }

    pub async fn delete_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        map_error(self.inner.delete_tasks(uuid_strs).await)
    }

    pub async fn delete_task_single(&self, uuid_str: String) -> Result<()> {
        map_error(self.inner.delete_task_single(uuid_str).await)
    }

    pub async fn delete_task_series(&self, uuid_str: String) -> Result<()> {
        map_error(self.inner.delete_task_series(uuid_str).await)
    }

    pub async fn done_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        map_error(self.inner.done_tasks(uuid_strs).await)
    }

    pub async fn done_task_single(&self, uuid_str: String) -> Result<()> {
        map_error(self.inner.done_task_single(uuid_str).await)
    }

    pub async fn done_task_series(&self, uuid_str: String) -> Result<()> {
        map_error(self.inner.done_task_series(uuid_str).await)
    }

    pub async fn start_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        map_error(self.inner.start_tasks(uuid_strs).await)
    }

    pub async fn stop_tasks(&self, uuid_strs: Vec<String>) -> Result<()> {
        map_error(self.inner.stop_tasks(uuid_strs).await)
    }

    pub async fn sync(
        &self,
        url: String,
        client_id: String,
        encryption_secret: String,
    ) -> Result<()> {
        map_error(self.inner.sync(url, client_id, encryption_secret).await)
    }

    pub async fn export_tasks(&self, include_deleted: bool) -> Result<String> {
        map_error(self.inner.export_tasks(include_deleted).await)
    }

    pub async fn import_tasks(&self, json_data: String) -> Result<usize> {
        if let Ok(views) = serde_json::from_str::<Vec<TaskView>>(&json_data) {
            let snapshots: Vec<TaskSnapshot> = views.into_iter().map(Into::into).collect();
            let converted =
                serde_json::to_string(&snapshots).map_err(|e| anyhow!(e.to_string()))?;
            map_error(self.inner.import_tasks(converted).await)
        } else {
            map_error(self.inner.import_tasks(json_data).await)
        }
    }
}
