package org.taskdroid

import android.Manifest
import android.content.pm.PackageManager
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : FlutterActivity() {
    private val CHANNEL = "org.taskdroid/calendar"
    private val PERMISSION_REQUEST_CODE = 9001
    private var pendingResult: MethodChannel.Result? = null
    private var repo: CalendarRepository? = null
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    override fun configureFlutterEngine(
        @NonNull flutterEngine: FlutterEngine,
    ) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (repo == null) {
                repo = CalendarRepository(context)
            }

            when (call.method) {
                "checkPermissions" -> {
                    val read = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALENDAR)
                    val write = ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_CALENDAR)
                    result.success(read == PackageManager.PERMISSION_GRANTED && write == PackageManager.PERMISSION_GRANTED)
                }

                "requestPermissions" -> {
                    val read = ContextCompat.checkSelfPermission(this, Manifest.permission.READ_CALENDAR)
                    val write = ContextCompat.checkSelfPermission(this, Manifest.permission.WRITE_CALENDAR)
                    if (read != PackageManager.PERMISSION_GRANTED || write != PackageManager.PERMISSION_GRANTED) {
                        pendingResult = result
                        ActivityCompat.requestPermissions(
                            this,
                            arrayOf(Manifest.permission.READ_CALENDAR, Manifest.permission.WRITE_CALENDAR),
                            PERMISSION_REQUEST_CODE,
                        )
                    } else {
                        result.success(true)
                    }
                }

                "listCalendars" -> {
                    scope.launch {
                        val calendars = repo!!.listWritableCalendars()
                        withContext(Dispatchers.Main) {
                            result.success(calendars)
                        }
                    }
                }

                "saveTask" -> {
                    val uuid = call.argument<String>("uuid")
                    val title = call.argument<String>("title")
                    val desc = call.argument<String>("description")
                    val start = call.argument<Number>("start")?.toLong()
                    val end = call.argument<Number>("end")?.toLong()
                    val calendarId = call.argument<Number>("calendarId")?.toLong()
                    val reminderMinutes = call.argument<Number>("reminderMinutes")?.toInt()

                    if (uuid != null && title != null && start != null && end != null) {
                        scope.launch {
                            val success = repo!!.saveEvent(
                                uuid,
                                title,
                                desc ?: "",
                                start,
                                end,
                                calendarId,
                                reminderMinutes,
                            )
                            withContext(Dispatchers.Main) {
                                result.success(success)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "Missing required fields", null)
                    }
                }

                "deleteTask" -> {
                    val uuid = call.argument<String>("uuid")
                    if (uuid != null) {
                        scope.launch {
                            val success = repo!!.deleteEvent(uuid)
                            withContext(Dispatchers.Main) {
                                result.success(success)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "UUID is null", null)
                    }
                }

                "deleteAllEvents" -> {
                    scope.launch {
                        val count = repo!!.deleteAllAppEvents()
                        withContext(Dispatchers.Main) {
                            result.success(count)
                        }
                    }
                }

                "batchSync" -> {
                    val tasks = call.argument<List<Map<String, Any>>>("tasks")
                    val calendarId = call.argument<Number>("calendarId")?.toLong()
                    val reminderMinutes = call.argument<Number>("reminderMinutes")?.toInt()
                    if (tasks != null) {
                        scope.launch {
                            val msg = repo!!.batchSync(tasks, calendarId, reminderMinutes)
                            withContext(Dispatchers.Main) {
                                result.success(msg)
                            }
                        }
                    } else {
                        result.error("INVALID_ARGS", "Tasks list is null", null)
                    }
                }

                else -> {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == PERMISSION_REQUEST_CODE) {
            if (grantResults.size >= 2 &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED &&
                grantResults[1] == PackageManager.PERMISSION_GRANTED
            ) {
                pendingResult?.success(true)
            } else {
                pendingResult?.success(false)
            }
            pendingResult = null
        }
    }
}
