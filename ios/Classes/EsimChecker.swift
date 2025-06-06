//
//  EsimChecker.swift
//  flutter_esim
//
//  Created by Hien Nguyen on 29/02/2024.
//
//  Comment: This class provides functionalities to check for eSIM support
//  and to initiate eSIM profile installation on iOS.
//

import Foundation
import CoreTelephony // Required for eSIM functionalities

@available(iOS 10.0, *)
class EsimChecker: NSObject {

    // Comment: This handler is responsible for sending events back to the Dart side.
    // It should be injected by the main plugin class (FlutterEsimPlugin).
    // Its 'send' method will need to be updated to accept a correlationId.
    public var handler: EventCallbackHandler?;

    // Comment: Checks if the device supports eSIM provisioning.
    func isSupportESim() -> Bool {
        if #available(iOS 12.0, *) {
            let ctcp = CTCellularPlanProvisioning()
            return ctcp.supportsCellularPlan()
        } else {
            print("LOG: eSIM support check: iOS version \(UIDevice.current.systemVersion) is older than 12.0. Reporting eSIM as unsupported by this check.")
            return false
        }
    }

    // Comment: Initiates the installation of an eSIM profile.
    // Now includes 'correlationId' to be passed along with events.
    // Note: The 'handler?.send' method signature is assumed to be updated in EventCallbackHandler
    // to accept 'correlationId' as its first parameter.
    func installEsimProfile(address: String, 
                            matchingID: String?, 
                            oid: String?, 
                            confirmationCode: String?, 
                            iccid: String?, 
                            eid: String?, 
                            correlationId: String?) { // Added correlationId parameter

        if #available(iOS 12.0, *) {
            let ctpr = CTCellularPlanProvisioningRequest();
            ctpr.address = address;
            
            // Assign optional parameters if they are provided and not empty
            if let unwrappedMatchingID = matchingID, !unwrappedMatchingID.isEmpty {
                ctpr.matchingID = unwrappedMatchingID;
            }
            if let unwrappedOid = oid, !unwrappedOid.isEmpty {
                ctpr.oid = unwrappedOid
            }
            if let unwrappedConfirmationCode = confirmationCode, !unwrappedConfirmationCode.isEmpty {
                ctpr.confirmationCode = unwrappedConfirmationCode
            }
            if let unwrappedIccid = iccid, !unwrappedIccid.isEmpty {
                ctpr.iccid = unwrappedIccid
            }
            if let unwrappedEid = eid, !unwrappedEid.isEmpty {
                ctpr.eid = unwrappedEid
            }

            let ctcp = CTCellularPlanProvisioning()
            
            if !ctcp.supportsCellularPlan() {
                print("LOG: installEsimProfile: Device does not support cellular plan provisioning (iOS 12+ check). CorrelationID: \(correlationId ?? "nil")")
                // Assuming handler.send will be: send(correlationId: String?, eventName: String, body: Any)
                handler?.send(correlationId: correlationId, eventName: "unsupport", body: ["reason": "Device does not support cellular plan provisioning."])
                return;
            }
            
            print("LOG: Attempting to add eSIM plan with address: \(address), CorrelationID: \(correlationId ?? "nil")")
            ctcp.addPlan(with: ctpr) { (result) in
                switch result {
                case .unknown:
                    print("LOG: eSIM installation result: Unknown. CorrelationID: \(correlationId ?? "nil")")
                    self.handler?.send(correlationId: correlationId, eventName: "unknown", body: [:])
                case .fail:
                    print("LOG: eSIM installation result: Fail. CorrelationID: \(correlationId ?? "nil")")
                    self.handler?.send(correlationId: correlationId, eventName: "fail", body: [:])
                case .success:
                    print("LOG: eSIM installation result: Success. CorrelationID: \(correlationId ?? "nil")")
                    self.handler?.send(correlationId: correlationId, eventName: "success", body: [:])
                case .cancel: // User cancelled the process via system UI
                    print("LOG: eSIM installation result: Cancelled by user. CorrelationID: \(correlationId ?? "nil")")
                    self.handler?.send(correlationId: correlationId, eventName: "cancel", body: [:])
                @unknown default:
                    print("LOG: eSIM installation result: Unknown default case. CorrelationID: \(correlationId ?? "nil")")
                    self.handler?.send(correlationId: correlationId, eventName: "unknown", body: ["reason": "Unknown default result from addPlan."])
                }
            }
        } else {
            print("LOG: installEsimProfile: Attempted on iOS version older than 12.0. CorrelationID: \(correlationId ?? "nil")")
            handler?.send(correlationId: correlationId, eventName: "unsupport", body: ["reason": "iOS 12.0 or higher is required to install eSIM profiles."])
        }
    }
}