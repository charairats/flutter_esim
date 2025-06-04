package com.hiennv.flutter_esim

import android.annotation.SuppressLint
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.telephony.euicc.DownloadableSubscription
import android.telephony.euicc.EuiccManager
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

// EventCallbackHandler is a top-level class or a static nested class.
// It handles the event sink for the EventChannel.
class EventCallbackHandler : EventChannel.StreamHandler {
    private var eventSink: EventChannel.EventSink? = null
    private val handler = Handler(Looper.getMainLooper()) // For posting to main thread

    companion object {
        private const val TAG = "EventCallbackHandler"
    }

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink) {
        eventSink = sink
    }

    fun send(correlationId: String?, eventName: String, body: Map<String, Any>) {
        val dataPayload = mutableMapOf<String, Any?>()
        dataPayload["event"] = eventName
        dataPayload["body"] = body // This is the original specific body for the event type
        if (correlationId != null) {
            dataPayload["correlationId"] = correlationId
        } else {
            // This case might occur if an event is sent that isn't tied to a correlation flow.
            Log.w(TAG, "Sending event '$eventName' without a correlationId.")
        }
        Log.d(TAG, "EventCallbackHandler preparing to send data: $dataPayload")
        handler.post { // Ensure sink methods are called on the main thread
            eventSink?.success(dataPayload)
        }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }
}

class FlutterEsimPlugin : FlutterPlugin, MethodCallHandler, ActivityAware {

    companion object {
        private const val TAG = "FlutterEsimPlugin"
        private const val METHOD_CHANNEL_NAME = "flutter_esim"
        private const val EVENT_CHANNEL_NAME = "flutter_esim_events"
        // Constants for intents and pending intents
        const val EXTRA_CORRELATION_ID = "correlationId"
        const val ACTION_DOWNLOAD_SUBSCRIPTION = "com.hiennv.flutter_esim.DOWNLOAD_SUBSCRIPTION_ACTION" // Made package-specific
        private const val REQUEST_CODE_INSTALL_ESIM = 999 // Used for PendingIntent and startResolutionActivity
    }

    // Instance members
    private var currentActivity: Activity? = null
    private var applicationContext: Context? = null
    private var euiccManager: EuiccManager? = null

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var eventCallbackHandler: EventCallbackHandler? = null // Instance of the handler
    private var receiverRegistered = false


    // MethodCallHandler implementation
    @SuppressLint("UnspecifiedRegisterReceiverFlag") // For older SDKs before TIRAMISU flag for registerReceiver
    override fun onMethodCall(call: MethodCall, result: Result) {
        val correlationId = call.argument<String>("correlationId")
        Log.d(TAG, "onMethodCall: ${call.method}, CorrelationId: $correlationId")

        try {
            when (call.method) {
                "isSupportESim" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                        result.success(this.euiccManager?.isEnabled ?: false)
                    } else {
                        result.success(false)
                    }
                }
                "installEsimProfile" -> {
                    val eSimProfile = call.argument<String>("profile")
                    if (eSimProfile == null) {
                        result.error("INVALID_ARGS", "Profile data (activation code) is missing.", null)
                        return
                    }

                    if (Build.VERSION.SDK_INT < Build.VERSION_CODES.P) {
                        sendPluginEvent(correlationId, "unsupport", mapOf("reason" to "eSIM functionality requires Android 9 (Pie) or newer."))
                        result.success(null) // Acknowledge the call if not erroring out
                        return
                    }

                    val currentEuiccManager = this.euiccManager
                    if (currentEuiccManager == null || !currentEuiccManager.isEnabled) {
                        val reason = if (currentEuiccManager == null) "EuiccManager not available on this device." else "eSIM is disabled in settings."
                        sendPluginEvent(correlationId, "unsupport", mapOf("reason" to reason))
                        result.success(null)
                        return
                    }

                    val appContext = this.applicationContext
                    if (appContext == null) {
                        result.error("INTERNAL_ERROR", "Application context not available. Plugin may not be properly attached.", null)
                        return
                    }

                    // Register receiver for eSIM download results
                    val intentFilter = IntentFilter(ACTION_DOWNLOAD_SUBSCRIPTION)
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        appContext.registerReceiver(esimDownloadReceiver, intentFilter, Context.RECEIVER_NOT_EXPORTED)
                    } else {
                        appContext.registerReceiver(esimDownloadReceiver, intentFilter)
                    }
                    receiverRegistered = true
                    Log.d(TAG, "BroadcastReceiver registered for $ACTION_DOWNLOAD_SUBSCRIPTION.")

                    val downloadableSubscription = DownloadableSubscription.forActivationCode(eSimProfile)
                    val explicitIntent = Intent(ACTION_DOWNLOAD_SUBSCRIPTION).apply {
                        `package` = appContext.packageName // Important for targeted broadcast
                        putExtra(EXTRA_CORRELATION_ID, correlationId)
                    }

                    val callbackIntent = PendingIntent.getBroadcast(
                        appContext,
                        REQUEST_CODE_INSTALL_ESIM,
                        explicitIntent,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                    )
                    currentEuiccManager.downloadSubscription(downloadableSubscription, true, callbackIntent)
                    result.success(null) // Indicate that the call was processed; actual result via events
                }
                "instructions" -> {
                    // Provide generic instructions as a string
                    result.success(
                        "1. Save QR Code (if applicable)\n" +
                        "2. Go to Settings on your device\n" +
                        "3. Tap 'Network & internet' or 'Connections'\n" +
                        "4. Tap 'SIMs' or 'SIM Manager'\n" +
                        "5. Tap 'Add eSIM' or 'Download a SIM instead?'\n" +
                        "6. Follow on-screen instructions to scan a QR code or enter an activation code manually.\n" +
                        "   (Activation Code: Often starts with 'LPA:1\$...')\n" +
                        "7. Confirm download and activation."
                    )
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Unhandled error in onMethodCall for ${call.method}: ${e.message}", e)
            result.error("NATIVE_UNHANDLED_ERROR", e.message ?: "An unknown native error occurred.", e.stackTraceToString())
        }
    }

    // FlutterPlugin implementation
    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.applicationContext = binding.applicationContext
        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL_NAME)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL_NAME)
        this.eventCallbackHandler = EventCallbackHandler() // Create an instance for this plugin instance
        eventChannel.setStreamHandler(this.eventCallbackHandler)

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            this.euiccManager = this.applicationContext?.getSystemService(Context.EUICC_SERVICE) as? EuiccManager
            if (this.euiccManager == null) {
                Log.e(TAG, "EuiccManager is not available on this device (API level ${Build.VERSION.SDK_INT}).")
            } else {
                Log.d(TAG, "EuiccManager initialized. eSIM enabled: ${this.euiccManager?.isEnabled}")
            }
        } else {
            Log.i(TAG, "eSIM functionality not supported on API level ${Build.VERSION.SDK_INT}.")
        }
        Log.i(TAG, "FlutterEsimPlugin attached to engine.")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        this.eventCallbackHandler = null

        if (receiverRegistered && this.applicationContext != null) {
            try {
                this.applicationContext?.unregisterReceiver(esimDownloadReceiver)
                receiverRegistered = false
                Log.d(TAG, "BroadcastReceiver unregistered in onDetachedFromEngine.")
            } catch (e: IllegalArgumentException) {
                // This can happen if the receiver was already unregistered or not registered.
                Log.w(TAG, "Attempted to unregister receiver in onDetachedFromEngine, but it was not registered or already unregistered: ${e.message}")
            }
        }
        this.applicationContext = null
        Log.i(TAG, "FlutterEsimPlugin detached from engine.")
    }

    // ActivityAware implementation
    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        this.currentActivity = binding.activity
        Log.d(TAG, "FlutterEsimPlugin attached to activity: ${binding.activity.localClassName}")
        // Re-check EuiccManager if it might have become available or state changed with activity context
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P && this.euiccManager == null) {
             this.euiccManager = this.applicationContext?.getSystemService(Context.EUICC_SERVICE) as? EuiccManager
             Log.d(TAG, "EuiccManager re-checked in onAttachedToActivity. Enabled: ${this.euiccManager?.isEnabled}")
        }
    }

    override fun onDetachedFromActivityForConfigChanges() {
        this.currentActivity = null
        Log.d(TAG, "FlutterEsimPlugin detached from activity for config changes.")
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        this.currentActivity = binding.activity
        Log.d(TAG, "FlutterEsimPlugin reattached to activity for config changes: ${binding.activity.localClassName}")
    }

    override fun onDetachedFromActivity() {
        this.currentActivity = null
        Log.d(TAG, "FlutterEsimPlugin detached from activity.")
    }

    // Instance method to send events
    private fun sendPluginEvent(correlationId: String?, eventName: String, body: Map<String, Any>) {
        Log.d(TAG, "Queueing plugin event: $eventName, CorrelationId: $correlationId, Body: $body")
        this.eventCallbackHandler?.send(correlationId, eventName, body)
    }

    // BroadcastReceiver as an instance property
    private val esimDownloadReceiver: BroadcastReceiver = object : BroadcastReceiver() {
        override fun onReceive(broadcastContext: Context, intent: Intent) { // Renamed context to broadcastContext to avoid confusion
            val correlationId = intent.getStringExtra(EXTRA_CORRELATION_ID)
            val action = intent.action
            val resultCodeFromBroadcast = resultCode // In a BroadcastReceiver, resultCode is a property

            Log.d(TAG, "esimDownloadReceiver onReceive - Action: $action, ResultCode: $resultCodeFromBroadcast, CorrelationId: $correlationId")

            if (ACTION_DOWNLOAD_SUBSCRIPTION != action) {
                Log.w(TAG, "Received broadcast with unexpected action: $action")
                return
            }

            val eventBody = mutableMapOf<String, Any>() // Use mutable map for potential additions

            if (resultCodeFromBroadcast == EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_RESOLVABLE_ERROR) {
                Log.i(TAG, "Resolvable error received for eSIM download. CorrelationId: $correlationId")
                val currentMgr = euiccManager
                val activityForResolution = currentActivity
                if (currentMgr != null && activityForResolution != null) {
                    // It's important that originalIntent (intent received here) is passed to handleResolvableError
                    // as it contains the resolution information.
                    handleResolvableError(intent, correlationId, activityForResolution, currentMgr)
                } else {
                    Log.e(TAG, "Cannot handle resolvable error: EuiccManager or Activity is null. Mgr: $currentMgr, Activity: $activityForResolution")
                    eventBody["reason"] = "Internal error: EuiccManager or Activity not available to handle resolvable error."
                    sendPluginEvent(correlationId, "fail", eventBody)
                }
            } else if (resultCodeFromBroadcast == EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_OK) {
                Log.i(TAG, "eSIM download successful. CorrelationId: $correlationId")
                sendPluginEvent(correlationId, "success", eventBody)
            } else if (resultCodeFromBroadcast == EuiccManager.EMBEDDED_SUBSCRIPTION_RESULT_ERROR) {
                Log.e(TAG, "eSIM download failed with error. ResultCode: $resultCodeFromBroadcast, CorrelationId: $correlationId")
                eventBody["errorCode"] = resultCodeFromBroadcast // Provide the error code if useful
                sendPluginEvent(correlationId, "fail", eventBody)
            } else {
                Log.w(TAG, "eSIM download unknown result. ResultCode: $resultCodeFromBroadcast, CorrelationId: $correlationId")
                eventBody["resultCode"] = resultCodeFromBroadcast
                sendPluginEvent(correlationId, "unknown", eventBody)
            }
        }
    }

    private fun handleResolvableError(
        originalIntentWithResolution: Intent, // This intent is from EuiccManager, contains resolution data
        correlationId: String?,
        activityToHostResolution: Activity,
        manager: EuiccManager
    ) {
        Log.d(TAG, "Attempting to handle resolvable error. CorrelationId: $correlationId")
        try {
            // Create a new PendingIntent for the callback *after* the resolution activity completes.
            // This new PendingIntent will trigger our esimDownloadReceiver again.
            val resolutionCallbackIntent = Intent(ACTION_DOWNLOAD_SUBSCRIPTION).apply {
                `package` = activityToHostResolution.packageName
                putExtra(EXTRA_CORRELATION_ID, correlationId) // Ensure correlation ID is propagated
            }

            val pendingIntentForCallback = PendingIntent.getBroadcast(
                activityToHostResolution.applicationContext,
                REQUEST_CODE_INSTALL_ESIM, // Can reuse or use a different code if needed for differentiation
                resolutionCallbackIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
            )

            // startResolutionActivity will show a system dialog or activity.
            // The originalIntentWithResolution is what EuiccManager needs to start this UI.
            // The pendingIntentForCallback is what the system will invoke when that UI is done.
            manager.startResolutionActivity(
                activityToHostResolution,
                REQUEST_CODE_INSTALL_ESIM, // This request code is for onActivityResult of activityToHostResolution
                originalIntentWithResolution,
                pendingIntentForCallback
            )
            Log.i(TAG, "Resolution activity started. CorrelationId: $correlationId")
            // Optionally, send an event indicating that user interaction is required.
            // sendPluginEvent(correlationId, "user_interaction_required", mapOf("type" to "resolvable_error"))

        } catch (e: Exception) {
            Log.e(TAG, "Exception in handleResolvableError: ${e.message}", e)
            val errorBody = mapOf(
                "reason" to "Failed to start or complete resolution activity for eSIM.",
                "errorDetails" to (e.message ?: "Unknown exception during resolution.")
            )
            sendPluginEvent(correlationId, "fail", errorBody)
        }
    }
}