package com.example.central_app

import android.os.Build
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.request.AggregateRequest
import androidx.health.connect.client.records.StepsRecord
import androidx.health.connect.client.time.TimeRangeFilter
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.time.Instant

class MainActivity : FlutterFragmentActivity() {
    private val channelName = "central_app_health/health_connect"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getAggregatedSteps" -> {
                        val startMillis = call.argument<Long>("startMillis")
                        val endMillis = call.argument<Long>("endMillis")

                        if (startMillis == null || endMillis == null) {
                            result.error("INVALID_RANGE", "startMillis and endMillis are required", null)
                            return@setMethodCallHandler
                        }

                        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                            result.error("UNSUPPORTED", "Android 14+ is required for native Health Connect aggregation", null)
                            return@setMethodCallHandler
                        }

                        Thread {
                            try {
                                val client = HealthConnectClient.getOrCreate(this)
                                val response = kotlinx.coroutines.runBlocking {
                                    client.aggregate(
                                        AggregateRequest(
                                            metrics = setOf(StepsRecord.COUNT_TOTAL),
                                            timeRangeFilter = TimeRangeFilter.between(
                                                Instant.ofEpochMilli(startMillis),
                                                Instant.ofEpochMilli(endMillis)
                                            )
                                        )
                                    )
                                }
                                val total = response[StepsRecord.COUNT_TOTAL] ?: 0L
                                runOnUiThread { result.success(total) }
                            } catch (e: Exception) {
                                runOnUiThread {
                                    result.error("HEALTH_CONNECT", e.message, e.stackTraceToString())
                                }
                            }
                        }.start()
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
