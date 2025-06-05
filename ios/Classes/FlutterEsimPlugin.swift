import Flutter
import UIKit

// EventCallbackHandler class handles the event sink for the EventChannel.
// It's defined here as it was part of the original FlutterEsimPlugin.swift structure provided.
class EventCallbackHandler: NSObject, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?
    // It's good practice to dispatch to the main thread when calling eventSink.
    private let mainQueue = DispatchQueue.main

    companion object {
        private const val TAG = "EventCallbackHandler_Swift" // Added TAG for clarity
    }

    // Updated 'send' method signature to include 'correlationId' and clearer parameter names.
    // This method constructs the payload that will be sent to Dart.
    public func send(correlationId: String?, eventName: String, body: Any) {
        var dataPayload: [String : Any] = [
            "event": eventName,
            "body": body // 'body' here is the specific data for this event type
        ]

        if let id = correlationId {
            dataPayload["correlationId"] = id
        } else {
            print("\(EventCallbackHandler.TAG): Sending event '\(eventName)' without a correlationId.")
        }
        
        print("\(EventCallbackHandler.TAG): Preparing to send to Dart: \(dataPayload)")

        mainQueue.async { // Ensure eventSink is called on the main thread
            if let sink = self.eventSink {
                sink(dataPayload)
            } else {
                print("\(EventCallbackHandler.TAG): eventSink is nil, cannot send event '\(eventName)'.")
            }
        }
    }

    // Called when Dart starts listening to the EventChannel.
    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        print("\(EventCallbackHandler.TAG): onListen called, eventSink has been set.")
        self.eventSink = events
        return nil
    }

    // Called when Dart stops listening to the EventChannel.
    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        print("\(EventCallbackHandler.TAG): onCancel called, eventSink has been cleared.")
        self.eventSink = nil
        return nil
    }
}


public class FlutterEsimPlugin: NSObject, FlutterPlugin {
    
    private var streamHandlers: WeakArray<EventCallbackHandler> = WeakArray([])
    private var esimChecker: EsimChecker // Instance of EsimChecker
    
    // Private method for plugin-level events, if needed.
    // EsimChecker events are sent via its injected handler.
    private func sendPluginLevelEvent(_ event: String, _ body: [String : Any?]?) {
        // This method iterates through `streamHandlers`. Currently, only one handler is added.
        // If EsimChecker is the sole source of installation events, this might be less used.
        streamHandlers.reap().forEach { handlerInstance in
            handlerInstance?.send(correlationId: nil, eventName: event, body: body ?? [:])
            print("LOG (FlutterEsimPlugin): Sent plugin-level event '\(event)' via sendPluginLevelEvent.")
        }
    }
    
    // Static methods for channel creation
    private static func createMethodChannel(messenger: FlutterBinaryMessenger) -> FlutterMethodChannel {
        return FlutterMethodChannel(name: "flutter_esim", binaryMessenger: messenger)
    }
    
    private static func createEventChannel(messenger: FlutterBinaryMessenger) -> FlutterEventChannel {
        return FlutterEventChannel(name: "flutter_esim_events", binaryMessenger: messenger)
    }
    
    // Plugin registration
    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = FlutterEsimPlugin()
        instance.setupChannels(with: registrar) // Renamed from shareHandlers for clarity
        // Removed sharedInstance assignment as it was not fully implemented/used.
        // Flutter manages plugin instances.
        print("LOG (FlutterEsimPlugin): Plugin registered.")
    }
    
    // Instance method to set up channels and handlers
    private func setupChannels(with registrar: FlutterPluginRegistrar) {
        let methodChannel = Self.createMethodChannel(messenger: registrar.messenger())
        registrar.addMethodCallDelegate(self, channel: methodChannel)
        
        let eventsStreamHandler = EventCallbackHandler() // Create the handler instance
        esimChecker.handler = eventsStreamHandler; // Inject handler into EsimChecker
        
        // The streamHandlers array is for the plugin's own sendPluginLevelEvent method.
        // If all events are expected to go through EsimChecker's handler, this might be simplified.
        self.streamHandlers.append(eventsStreamHandler) 
        
        let eventChannel = Self.createEventChannel(messenger: registrar.messenger())
        eventChannel.setStreamHandler(eventsStreamHandler) // Set the handler for the event channel
        print("LOG (FlutterEsimPlugin): Method and Event channels set up.")
    }
    
    public override init() {
        self.esimChecker = EsimChecker() // Initialize EsimChecker
        super.init()
        print("LOG (FlutterEsimPlugin): Initialized.")
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("LOG (FlutterEsimPlugin): Received method call: \(call.method)")
        switch call.method {
        case "isSupportESim":
            // Calls the updated, parameterless isSupportESim method in EsimChecker
            let supported = esimChecker.isSupportESim()
            print("LOG (FlutterEsimPlugin): 'isSupportESim' returning: \(supported)")
            result(supported);
            break;

        case "installEsimProfile":
            print("LOG (FlutterEsimPlugin): 'installEsimProfile' called with arguments: \(String(describing: call.arguments))")
            guard let args = call.arguments as? [String: Any] else {
                print("ERROR (FlutterEsimPlugin): Arguments for 'installEsimProfile' are missing or not a dictionary.")
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "Expected a dictionary of arguments for installEsimProfile.",
                                    details: nil))
                return
            }

            let profileAddress = args["profile"] as? String ?? ""
            let matchingID = args["matchingID"] as? String
            let oid = args["oid"] as? String
            let confirmationCode = args["confirmationCode"] as? String
            let iccid = args["iccid"] as? String
            let eid = args["eid"] as? String
            let correlationId = args["correlationId"] as? String // Extract correlationId

            print("LOG (FlutterEsimPlugin): Extracted for installEsimProfile - Profile: '\(profileAddress)', CorrelationID: \(correlationId ?? "nil")")

            if profileAddress.isEmpty {
                print("WARNING (FlutterEsimPlugin): 'profile' (address) is empty in installEsimProfile arguments. Installation may fail.")
                // Depending on requirements, could return an error here:
                // result(FlutterError(code: "PROFILE_EMPTY", message: "Profile address cannot be empty.", details: nil))
                // return
            }
            
            esimChecker.installEsimProfile(
                address: profileAddress,
                matchingID: matchingID,
                oid: oid,
                confirmationCode: confirmationCode,
                iccid: iccid,
                eid: eid,
                correlationId: correlationId // Pass the correlationId
            )
            
            result("OK") // Acknowledge the call; actual status via events.
            break;

        case "instructions":
            print("LOG (FlutterEsimPlugin): 'instructions' called.")
            result(
                "1. Save QR Code (if applicable)\n" +
                "2. On your device, go to Settings\n" +
                "3. Tap Cellular or Mobile Data\n" + // Updated for more common terminology
                "4. Tap Add Cellular Plan or Add eSIM\n" +
                "5. Follow prompts to use a QR code or enter details manually.\n" + // Simplified instructions
                "   (Activation Code often starts with 'LPA:1$...')"
                // Removed overly specific steps that can vary more by iOS version/carrier
            )
            break;
        default:
            print("LOG (FlutterEsimPlugin): Method '\(call.method)' not implemented.")
            result(FlutterMethodNotImplemented)
        }
    }
}