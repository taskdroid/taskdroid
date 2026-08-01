package org.taskdroid

import android.content.ContentProviderOperation
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.provider.CalendarContract
import android.util.Log
import java.util.TimeZone

class CalendarRepository(
    private val context: Context,
) {
    private val TAG = "CalendarRepo"
    private val UUID_TAG_PREFIX = "[TaskDroid ID: "
    private val UUID_TAG_SUFFIX = "]"

    fun listWritableCalendars(): List<Map<String, Any?>> {
        val projection =
            arrayOf(
                CalendarContract.Calendars._ID,
                CalendarContract.Calendars.CALENDAR_DISPLAY_NAME,
                CalendarContract.Calendars.ACCOUNT_NAME,
                CalendarContract.Calendars.ACCOUNT_TYPE,
                CalendarContract.Calendars.IS_PRIMARY,
                CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
                CalendarContract.Calendars.CALENDAR_COLOR,
            )

        val selection =
            "${CalendarContract.Calendars.VISIBLE} = 1 AND " +
                "${CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL} >= ${CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR}"

        val calendars = mutableListOf<Map<String, Any?>>()
        var cursor: Cursor? = null
        try {
            cursor =
                context.contentResolver.query(
                    CalendarContract.Calendars.CONTENT_URI,
                    projection,
                    selection,
                    null,
                    null,
                )

            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    calendars.add(
                        mapOf(
                            "id" to id,
                            "name" to (cursor.getString(1) ?: "Calendar"),
                            "accountName" to (cursor.getString(2) ?: ""),
                            "accountType" to (cursor.getString(3) ?: ""),
                            "isPrimary" to (cursor.getInt(4) == 1),
                            "accessLevel" to cursor.getInt(5),
                            "color" to if (cursor.isNull(6)) null else cursor.getInt(6),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error listing calendars: ${e.message}")
        } finally {
            cursor?.close()
        }
        return calendars.sortedWith(compareByDescending<Map<String, Any?>> { it["isPrimary"] as Boolean }.thenBy { it["name"] as String })
    }

    private fun resolveCalendarId(calendarId: Long?): Long? {
        val writableIds = listWritableCalendars().mapNotNull { it["id"] as? Long }.toSet()
        if (calendarId != null && writableIds.contains(calendarId)) return calendarId
        return writableIds.firstOrNull()
    }

    private fun buildDescriptionWithTag(
        description: String,
        uuid: String,
    ): String = "$description\n\n$UUID_TAG_PREFIX$uuid$UUID_TAG_SUFFIX"

    fun saveEvent(
        uuid: String,
        title: String,
        description: String,
        startMs: Long,
        endMs: Long,
        calendarId: Long?,
        reminderMinutes: Int?,
    ): Boolean {
        val calId = resolveCalendarId(calendarId) ?: return false
        val existingEventId = getEventIdByUuid(uuid)
        val finalDescription = buildDescriptionWithTag(description, uuid)

        val values =
            ContentValues().apply {
                put(CalendarContract.Events.DTSTART, startMs)
                put(CalendarContract.Events.DTEND, endMs)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.DESCRIPTION, finalDescription)
                put(CalendarContract.Events.CALENDAR_ID, calId)
                put(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
            }

        return try {
            val eventId =
                if (existingEventId != null) {
                    val updateUri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, existingEventId)
                    val updated = context.contentResolver.update(updateUri, values, null, null) > 0
                    if (updated) existingEventId else null
                } else {
                    val uri = context.contentResolver.insert(CalendarContract.Events.CONTENT_URI, values)
                    if (uri != null) ContentUris.parseId(uri) else null
                }

            if (eventId != null) {
                replaceReminder(eventId, reminderMinutes)
                true
            } else {
                false
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error saving event: ${e.message}")
            false
        }
    }

    private fun replaceReminder(
        eventId: Long,
        reminderMinutes: Int?,
    ) {
        context.contentResolver.delete(
            CalendarContract.Reminders.CONTENT_URI,
            "${CalendarContract.Reminders.EVENT_ID} = ?",
            arrayOf(eventId.toString()),
        )

        if (reminderMinutes == null || reminderMinutes < 0) return

        val values =
            ContentValues().apply {
                put(CalendarContract.Reminders.EVENT_ID, eventId)
                put(CalendarContract.Reminders.MINUTES, reminderMinutes)
                put(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
            }
        context.contentResolver.insert(CalendarContract.Reminders.CONTENT_URI, values)
    }

    fun hasEvent(uuid: String): Boolean = getEventIdByUuid(uuid) != null

    fun deleteEvent(uuid: String): Boolean {
        val eventId = getEventIdByUuid(uuid) ?: return false
        val deleteUri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
        return try {
            context.contentResolver.delete(
                CalendarContract.Reminders.CONTENT_URI,
                "${CalendarContract.Reminders.EVENT_ID} = ?",
                arrayOf(eventId.toString()),
            )
            context.contentResolver.delete(deleteUri, null, null) > 0
        } catch (e: Exception) {
            Log.e(TAG, "Error deleting event: ${e.message}")
            false
        }
    }

    fun deleteAllAppEvents(): Int {
        val eventIds = getAppEventIds()
        val selection = "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        val selectionArgs = arrayOf("%$UUID_TAG_PREFIX%")
        return try {
            for (eventId in eventIds) {
                context.contentResolver.delete(
                    CalendarContract.Reminders.CONTENT_URI,
                    "${CalendarContract.Reminders.EVENT_ID} = ?",
                    arrayOf(eventId.toString()),
                )
            }
            context.contentResolver.delete(CalendarContract.Events.CONTENT_URI, selection, selectionArgs)
        } catch (e: Exception) {
            Log.e(TAG, "Error deleting all app events: ${e.message}")
            0
        }
    }

    fun batchSync(
        tasks: List<Map<String, Any>>,
        requestedCalendarId: Long?,
        requestedReminderMinutes: Int?,
    ): String {
        val calId = resolveCalendarId(requestedCalendarId) ?: return "No Calendar Found"
        val ops = ArrayList<ContentProviderOperation>()

        val existingEvents = HashMap<String, Long>()
        val projection = arrayOf(CalendarContract.Events._ID, CalendarContract.Events.DESCRIPTION)
        val selection = "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        val selectionArgs = arrayOf("%$UUID_TAG_PREFIX%")

        var cursor: Cursor? = null
        try {
            cursor =
                context.contentResolver.query(
                    CalendarContract.Events.CONTENT_URI,
                    projection,
                    selection,
                    selectionArgs,
                    null,
                )
            if (cursor != null) {
                while (cursor.moveToNext()) {
                    val id = cursor.getLong(0)
                    val desc = cursor.getString(1) ?: ""
                    val uuid = extractUuidFromDescription(desc)
                    if (uuid != null) {
                        existingEvents[uuid] = id
                    }
                }
            }
        } catch (e: Exception) {
            return "Error querying calendar: ${e.message}"
        } finally {
            cursor?.close()
        }

        val incomingUuids = HashSet<String>()

        for (task in tasks) {
            val uuid = task["uuid"] as? String ?: continue
            val title = task["title"] as? String ?: "Task"
            val rawDesc = task["description"] as? String ?: ""
            val startMs = (task["start"] as? Number)?.toLong() ?: continue
            val endMs = (task["end"] as? Number)?.toLong() ?: (startMs + 3_600_000L)
            val taskCalendarId = (task["calendarId"] as? Number)?.toLong()
            val taskReminderMinutes = (task["reminderMinutes"] as? Number)?.toInt()
            val targetCalendarId = resolveCalendarId(taskCalendarId ?: requestedCalendarId) ?: calId
            val reminderMinutes = taskReminderMinutes ?: requestedReminderMinutes

            incomingUuids.add(uuid)
            val finalDesc = buildDescriptionWithTag(rawDesc, uuid)

            if (existingEvents.containsKey(uuid)) {
                val eventId = existingEvents[uuid]!!
                val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)

                ops.add(
                    ContentProviderOperation
                        .newUpdate(uri)
                        .withValue(CalendarContract.Events.CALENDAR_ID, targetCalendarId)
                        .withValue(CalendarContract.Events.DTSTART, startMs)
                        .withValue(CalendarContract.Events.DTEND, endMs)
                        .withValue(CalendarContract.Events.TITLE, title)
                        .withValue(CalendarContract.Events.DESCRIPTION, finalDesc)
                        .build(),
                )
                ops.add(
                    ContentProviderOperation
                        .newDelete(CalendarContract.Reminders.CONTENT_URI)
                        .withSelection(
                            "${CalendarContract.Reminders.EVENT_ID} = ?",
                            arrayOf(eventId.toString()),
                        )
                        .build(),
                )
                if (reminderMinutes != null && reminderMinutes >= 0) {
                    ops.add(
                        ContentProviderOperation
                            .newInsert(CalendarContract.Reminders.CONTENT_URI)
                            .withValue(CalendarContract.Reminders.EVENT_ID, eventId)
                            .withValue(CalendarContract.Reminders.MINUTES, reminderMinutes)
                            .withValue(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                            .build(),
                    )
                }
            } else {
                val eventInsertIndex = ops.size
                ops.add(
                    ContentProviderOperation
                        .newInsert(CalendarContract.Events.CONTENT_URI)
                        .withValue(CalendarContract.Events.CALENDAR_ID, targetCalendarId)
                        .withValue(CalendarContract.Events.DTSTART, startMs)
                        .withValue(CalendarContract.Events.DTEND, endMs)
                        .withValue(CalendarContract.Events.TITLE, title)
                        .withValue(CalendarContract.Events.DESCRIPTION, finalDesc)
                        .withValue(CalendarContract.Events.EVENT_TIMEZONE, TimeZone.getDefault().id)
                        .build(),
                )
                if (reminderMinutes != null && reminderMinutes >= 0) {
                    ops.add(
                        ContentProviderOperation
                            .newInsert(CalendarContract.Reminders.CONTENT_URI)
                            .withValueBackReference(CalendarContract.Reminders.EVENT_ID, eventInsertIndex)
                            .withValue(CalendarContract.Reminders.MINUTES, reminderMinutes)
                            .withValue(CalendarContract.Reminders.METHOD, CalendarContract.Reminders.METHOD_ALERT)
                            .build(),
                    )
                }
            }
        }

        // orphans
        for ((uuid, eventId) in existingEvents) {
            if (!incomingUuids.contains(uuid)) {
                val uri = ContentUris.withAppendedId(CalendarContract.Events.CONTENT_URI, eventId)
                ops.add(
                    ContentProviderOperation
                        .newDelete(CalendarContract.Reminders.CONTENT_URI)
                        .withSelection(
                            "${CalendarContract.Reminders.EVENT_ID} = ?",
                            arrayOf(eventId.toString()),
                        )
                        .build(),
                )
                ops.add(ContentProviderOperation.newDelete(uri).build())
            }
        }

        return try {
            if (ops.isNotEmpty()) {
                context.contentResolver.applyBatch(CalendarContract.AUTHORITY, ops)
                "Synced ${ops.size} operations"
            } else {
                "No changes needed"
            }
        } catch (e: Exception) {
            Log.e(TAG, "Batch failed", e)
            "Batch failed: ${e.message}"
        }
    }

    private fun getEventIdByUuid(uuid: String): Long? {
        val projection = arrayOf(CalendarContract.Events._ID)
        val selection = "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        val selectionArgs = arrayOf("%$UUID_TAG_PREFIX$uuid$UUID_TAG_SUFFIX%")

        var cursor: Cursor? = null
        try {
            cursor =
                context.contentResolver.query(
                    CalendarContract.Events.CONTENT_URI,
                    projection,
                    selection,
                    selectionArgs,
                    null,
                )
            if (cursor != null && cursor.moveToFirst()) {
                return cursor.getLong(0)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Query failed for UUID $uuid: ${e.message}")
        } finally {
            cursor?.close()
        }
        return null
    }

    private fun getAppEventIds(): List<Long> {
        val projection = arrayOf(CalendarContract.Events._ID)
        val selection = "${CalendarContract.Events.DESCRIPTION} LIKE ?"
        val selectionArgs = arrayOf("%$UUID_TAG_PREFIX%")
        val ids = mutableListOf<Long>()

        var cursor: Cursor? = null
        try {
            cursor =
                context.contentResolver.query(
                    CalendarContract.Events.CONTENT_URI,
                    projection,
                    selection,
                    selectionArgs,
                    null,
                )
            if (cursor != null) {
                while (cursor.moveToNext()) {
                    ids.add(cursor.getLong(0))
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to query app event ids: ${e.message}")
        } finally {
            cursor?.close()
        }
        return ids
    }

    private fun extractUuidFromDescription(description: String): String? {
        try {
            val startIndex = description.lastIndexOf(UUID_TAG_PREFIX)
            if (startIndex == -1) return null
            val afterPrefix = description.substring(startIndex + UUID_TAG_PREFIX.length)
            val endIndex = afterPrefix.indexOf(UUID_TAG_SUFFIX)
            if (endIndex == -1) return null
            return afterPrefix.substring(0, endIndex)
        } catch (e: Exception) {
            return null
        }
    }
}
