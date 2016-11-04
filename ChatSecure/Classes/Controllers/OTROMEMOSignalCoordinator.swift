//
//  OTROMEMOSignalCoordinator.swift
//  ChatSecure
//
//  Created by David Chiles on 8/4/16.
//  Copyright © 2016 Chris Ballinger. All rights reserved.
//

import UIKit
import XMPPFramework
import YapDatabase

/** 
 * This is the glue between XMPP/OMEMO and Signal
 */
@objc public class OTROMEMOSignalCoordinator: NSObject {
    
    public let signalEncryptionManager:OTRAccountSignalEncryptionManager
    public let omemoStorageManager:OTROMEMOStorageManager
    public let accountYapKey:String
    public let databaseConnection:YapDatabaseConnection
    public weak var omemoModule:OMEMOModule?
    public weak var omemoModuleQueue:dispatch_queue_t?
    public var callbackQueue:dispatch_queue_t
    public let workQueue:dispatch_queue_t
    private var myJID:XMPPJID? {
        get {
            return omemoModule?.xmppStream.myJID
        }
    }
    let preKeyCount:UInt = 100
    private var outstandingXMPPStanzaResponseBlocks:[String: (Bool) -> Void]
    /**
     Create a OTROMEMOSignalCoordinator for an account. 
     
     - parameter accountYapKey: The accounts unique yap key
     - parameter databaseConnection: A yap database connection on which all operations will be completed on
 `  */
    @objc public required init(accountYapKey:String,  databaseConnection:YapDatabaseConnection) throws {
        try self.signalEncryptionManager = OTRAccountSignalEncryptionManager(accountKey: accountYapKey,databaseConnection: databaseConnection)
        self.omemoStorageManager = OTROMEMOStorageManager(accountKey: accountYapKey, accountCollection: OTRAccount.collection(), databaseConnection: databaseConnection)
        self.accountYapKey = accountYapKey
        self.databaseConnection = databaseConnection
        self.outstandingXMPPStanzaResponseBlocks = [:]
        self.callbackQueue = dispatch_queue_create("OTROMEMOSignalCoordinator-callback", DISPATCH_QUEUE_SERIAL)
        self.workQueue = dispatch_queue_create("OTROMEMOSignalCoordinator-work", DISPATCH_QUEUE_SERIAL)
    }
    
    /**
     Checks that a jid matches our own JID using XMPPJIDCompareBare
     */
    private func isOurJID(jid:XMPPJID) -> Bool {
        guard let ourJID = self.myJID else {
            return false;
        }
        
        return jid.isEqualToJID(ourJID, options: XMPPJIDCompareBare)
    }
    
    /** Always call on internal work queue */
    private func callAndRemoveOutstandingBundleBlock(elementId:String,success:Bool) {
        
        guard let outstandingBlock = self.outstandingXMPPStanzaResponseBlocks[elementId] else {
            return
        }
        outstandingBlock(success)
        self.outstandingXMPPStanzaResponseBlocks.removeValueForKey(elementId)
    }
    
    /**
     Check if a buddy supports OMEMO. This checks if we've seen devices for this buddy.
     
     - parameter buddyYapKey: The yap key of the buddy.
     
     - returns: True if there are devices and the buddy supports OMEMO otherwise false.
     */
    public func buddySupportsOMEMO(buddyYapKey:String) -> Bool {
        return self.omemoStorageManager.getDevicesForParentYapKey(buddyYapKey, yapCollection: OTRBuddy.collection(), trusted: true).count > 0
    }
    
    /** 
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter buddyYapKey: The yap key for the buddy to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    public func prepareSessionForBuddy(buddyYapKey:String, completion:(Bool) -> Void) {
        self.prepareSession(buddyYapKey, yapCollection: OTRBuddy.collection(), completion: completion)
    }
    
    /**
     This must be called before sending every message. It ensures that for every device there is a session and if not the bundles are fetched.
     
     - parameter yapKey: The yap key for the buddy or account to check
     - parameter yapCollection: The yap key for the buddy or account to check
     - parameter completion: The completion closure called on callbackQueue. If it successfully was able to fetch all the bundles or if it wasn't necessary. If there were no devices for this buddy it will also return flase
     */
    public func prepareSession(yapKey:String, yapCollection:String, completion:(Bool) -> Void) {
        var devices:[OTROMEMODevice]? = nil
        var user:String? = nil
        
        //Get all the devices ID's for this buddy as well as their username for use with signal and XMPPFramework.
        self.databaseConnection.readWithBlock { (transaction) in
            devices = OTROMEMODevice.allDevicesForParentKey(yapKey, collection: yapCollection, transaction: transaction)
            user = self.fetchUsername(yapKey, yapCollection: yapCollection, transaction: transaction)
        }
        
        guard let devs = devices, let username = user else {
            dispatch_async(self.callbackQueue, {
                completion(false)
            })
            return
        }
        
        var finalSuccess = true
        dispatch_async(self.workQueue) { [weak self] in
            guard let strongself = self else {
                return
            }
            
            let group = dispatch_group_create()
            //For each device Check if we have a session. If not then we need to fetch it from their XMPP server.
            for device in devs where device.deviceId.unsignedIntValue != self?.signalEncryptionManager.registrationId {
                if !strongself.signalEncryptionManager.sessionRecordExistsForUsername(username, deviceId: device.deviceId.intValue) {
                    //No session for this buddy and device combo. We need to fetch the bundle.
                    
                    let elementId = NSUUID().UUIDString
                    
                    dispatch_group_enter(group)
                    // Hold on to a closure so that when we get the call back from OMEMOModule we can call this closure.
                    strongself.outstandingXMPPStanzaResponseBlocks[elementId] = { success in
                        if (!success) {
                            finalSuccess = false
                        }
                        
                        dispatch_group_leave(group)
                    }
                    //Fetch the bundle
                    strongself.omemoModule?.fetchBundleForDeviceId(device.deviceId.unsignedIntValue, jid: XMPPJID.jidWithString(username), elementId: elementId)
                }
            }
            
            if let cQueue = self?.callbackQueue {
                dispatch_group_notify(group, cQueue) {
                    completion(finalSuccess)
                }

            }
        }
    }
    
    private func fetchUsername(yapKey:String, yapCollection:String, transaction:YapDatabaseReadTransaction) -> String? {
        if let object = transaction.objectForKey(yapKey, inCollection: yapCollection) {
            if object is OTRAccount {
                return object.username
            } else if object is OTRBuddy {
                return object.username
            }
        }
        return nil
    }
    
    /**
     Check if we have valid sessions with our other devices and if not fetch their bundles and start sessions.
     */
    func prepareSessionWithOurDevices(completion:(success:Bool) -> Void) {
        self.prepareSession(self.accountYapKey, yapCollection: OTRAccount.collection(), completion: completion)
    }
    
    private func encryptPayloadWithSignalForDevice(device:OTROMEMODevice, payload:NSData) throws -> OMEMOKeyData? {
        var user:String? = nil
        self.databaseConnection.readWithBlock({ (transaction) in
            user = self.fetchUsername(device.parentKey, yapCollection: device.parentCollection, transaction: transaction)
        })
        if let username = user {
            let encryptedKeyData = try self.signalEncryptionManager.encryptToAddress(payload, name: username, deviceId: device.deviceId.unsignedIntValue)
            return OMEMOKeyData(deviceId: device.deviceId.unsignedIntValue, data: encryptedKeyData.data)
        }
        return nil
    }
    
    /**
     Gathers necessary information to encrypt a message to the buddy and all this accounts devices that are trusted. Then sends the payload via OMEMOModule
     
     - parameter messageBody: The boddy of the message
     - parameter buddyYapKey: The unique buddy yap key. Used for looking up the username and devices 
     - parameter messageId: The preffered XMPP element Id to be used.
     - parameter completion: The completion block is called after all the necessary omemo preperation has completed and sendKeyData:iv:toJID:payload:elementId: is invoked
     */
    public func encryptAndSendMessage(messageBody:String, buddyYapKey:String, messageId:String?, completion:(Bool,NSError?) -> Void) {
        // Gather bundles for buddy and account here
        let group = dispatch_group_create()
        
        let prepareCompletion = { (success:Bool) in
            dispatch_group_leave(group)
        }
        
        dispatch_group_enter(group)
        dispatch_group_enter(group)
        self.prepareSessionForBuddy(buddyYapKey, completion: prepareCompletion)
        self.prepareSessionWithOurDevices(prepareCompletion)
        //Even if something went wrong fetching bundles we should push ahead. We may have sessions that can be used.
        
        dispatch_group_notify(group, self.workQueue) { [weak self] in
            guard let strongSelf = self else {
                return
            }
            //Strong self work here
            var bud:OTRBuddy? = nil
            strongSelf.databaseConnection.readWithBlock { (transaction) in
                bud = OTRBuddy.fetchObjectWithUniqueID(buddyYapKey, transaction: transaction)
            }
            
            guard let ivData = OTRSignalEncryptionHelper.generateIV(), let keyData = OTRSignalEncryptionHelper.generateSymmetricKey(), let messageBodyData = messageBody.dataUsingEncoding(NSUTF8StringEncoding) , let buddy = bud else {
                return
            }
            do {
                //Create the encrypted payload
                let payload = try OTRSignalEncryptionHelper.encryptData(messageBodyData, key: keyData, iv: ivData)
                
                
                // this does the signal encryption. If we fail it doesn't matter here. We end up trying the next device and fail later if no devices worked.
                let encryptClosure:(OTROMEMODevice) -> (OMEMOKeyData?) = { device in
                    do {
                        return try strongSelf.encryptPayloadWithSignalForDevice(device, payload: keyData)
                    } catch {
                        return nil
                    }
                }
                
                /**
                 1. Get all devices for this buddy.
                 2. Filter only devices that are trusted.
                 3. encrypt to those devices.
                 4. Remove optional values
                */
                let buddyKeyDataArray = strongSelf.omemoStorageManager.getDevicesForParentYapKey(buddy.uniqueId, yapCollection: buddy.dynamicType.collection(), trusted: true).map(encryptClosure).flatMap{ $0 }
                
                // Stop here if we were not able to encrypt to any of the buddies
                if (buddyKeyDataArray.count == 0) {
                    dispatch_async(strongSelf.callbackQueue, {
                        let error = NSError.chatSecureError(OTROMEMOError.NoDevicesForBuddy, userInfo: nil)
                        completion(false,error)
                    })
                    return
                }
                
                /**
                 1. Get all devices for this this account.
                 2. Filter only devices that are trusted and not ourselves.
                 3. encrypt to those devices.
                 4. Remove optional values
                 */
                let ourDevicesKeyData = strongSelf.omemoStorageManager.getDevicesForOurAccount(true).filter({ (device) -> Bool in
                    return device.deviceId.unsignedIntValue != strongSelf.signalEncryptionManager.registrationId
                }).map(encryptClosure).flatMap{ $0 }
                
                // Combine teh two arrays for all key data
                let keyDataArray = ourDevicesKeyData + buddyKeyDataArray
                
                //Make sure we have encrypted the symetric key to someone
                if (keyDataArray.count > 0) {
                    guard let payloadData = payload?.data, let authTag = payload?.authTag else {
                        return
                    }
                    let finalPayload = NSMutableData()
                    finalPayload.appendData(payloadData)
                    finalPayload.appendData(authTag)
                    strongSelf.omemoModule?.sendKeyData(keyDataArray, iv: ivData, toJID: XMPPJID.jidWithString(buddy.username), payload: finalPayload, elementId: messageId)
                    dispatch_async(strongSelf.callbackQueue, {
                        completion(true,nil)
                    })
                    return
                } else {
                    dispatch_async(strongSelf.callbackQueue, {
                        let error = NSError.chatSecureError(OTROMEMOError.NoDevices, userInfo: nil)
                        completion(false,error)
                    })
                    return
                }
            } catch let err as NSError {
                //This should only happen if we had an error encrypting the payload
                dispatch_async(strongSelf.callbackQueue, {
                    completion(false,err)
                })
                return
            }
            
        }
    }
    
    /**
     Remove a device from the yap store and from the XMPP server.
     
     - parameter deviceId: The OMEMO device id
    */
    public func removeDevice(deviceIds:[NSNumber], completion:((Bool) -> Void)) {
        
        dispatch_async(self.workQueue) { [weak self] in
            if let module = self?.omemoModule {
                let elementId = NSUUID().UUIDString
                
                self?.outstandingXMPPStanzaResponseBlocks[elementId] = { [weak self] success in
                    
                    if(success) {
                        guard let pKey = self?.accountYapKey else {
                            return
                        }
                        
                        self?.databaseConnection.readWriteWithBlock({ (transaction) in
                            for did in deviceIds {
                                let yapKey = OTROMEMODevice.yapKeyWithDeviceId(did, parentKey: pKey, parentCollection: OTRAccount.collection())
                                transaction.removeObjectForKey(yapKey, inCollection: OTROMEMODevice.collection())
                            }
                        })
                    }
                    
                    completion(success)
                }
                module.removeDeviceIds(deviceIds, elementId: elementId)
            }
        }
        
        
    }
}

extension OTROMEMOSignalCoordinator: OMEMOModuleDelegate {
    
    public func omemo(omemo: OMEMOModule, publishedDeviceIds deviceIds: [NSNumber], responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //print("publishedDeviceIds: \(responseIq)")
    }
    
    public func omemo(omemo: OMEMOModule, failedToPublishDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //print("failedToPublishDeviceIds: \(errorIq)")
    }
    
    public func omemo(omemo: OMEMOModule, deviceListUpdate deviceIds: [NSNumber], fromJID: XMPPJID, incomingElement: XMPPElement) {
        //print("deviceListUpdate: \(fromJID) \(deviceIds)")
        dispatch_async(self.workQueue) { [weak self] in
            if let eid = incomingElement.elementID() {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: true)
            }
        }
    }
    
    public func omemo(omemo: OMEMOModule, failedToFetchDeviceIdsForJID fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(omemo: OMEMOModule, publishedBundle bundle: OMEMOBundle, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        //print("publishedBundle: \(responseIq) \(outgoingIq)")
    }
    
    public func omemo(omemo: OMEMOModule, failedToPublishBundle bundle: OMEMOBundle, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        //print("failedToPublishBundle: \(errorIq) \(outgoingIq)")
    }
    
    public func omemo(omemo: OMEMOModule, fetchedBundle bundle: OMEMOBundle, fromJID: XMPPJID, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        
        if (self.isOurJID(fromJID) && bundle.deviceId == self.signalEncryptionManager.registrationId) {
            //We fetched our own bundle
            if let ourDatabaseBundle = self.fetchMyBundle() {
                //This bundle doesn't have the correct identity key. Something has gone wrong and we should republish
                if !ourDatabaseBundle.identityKey.isEqualToData(bundle.identityKey) {
                    omemo.publishBundle(ourDatabaseBundle, elementId: nil)
                }
            }
            return;
        }
        
        dispatch_async(self.workQueue) { [weak self] in
            let elementId = outgoingIq.elementID()
            if (bundle.preKeys.count == 0) {
                self?.callAndRemoveOutstandingBundleBlock(elementId, success: false)
                return
            }
            //Create incoming bundle from OMEMOBundle
            let innerBundle = OTROMEMOBundle(deviceId: bundle.deviceId, publicIdentityKey: bundle.identityKey, signedPublicPreKey: bundle.signedPreKey.publicKey, signedPreKeyId: bundle.signedPreKey.preKeyId, signedPreKeySignature: bundle.signedPreKey.signature)
            //Select random pre key to use
            let index = Int(arc4random_uniform(UInt32(bundle.preKeys.count)))
            let preKey = bundle.preKeys[index]
            let incomingBundle = OTROMEMOBundleIncoming(bundle: innerBundle, preKeyId: preKey.preKeyId, preKeyData: preKey.publicKey)
            //Consume the incoming bundle. This goes through signal and should hit the storage delegate. So we don't need to store ourselves here.
            self?.signalEncryptionManager.consumeIncomingBundle(fromJID.bare(), bundle: incomingBundle)
            self?.callAndRemoveOutstandingBundleBlock(elementId, success: true)
        }
        
    }
    public func omemo(omemo: OMEMOModule, failedToFetchBundleForDeviceId deviceId: gl_uint32_t, fromJID: XMPPJID, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        
        dispatch_async(self.workQueue) { [weak self] in
            let elementId = outgoingIq.elementID()
            self?.callAndRemoveOutstandingBundleBlock(elementId, success: false)
        }
    }
    
    public func omemo(omem: OMEMOModule, removedBundleId bundleId: gl_uint32_t, responseIq: XMPPIQ, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(omemo: OMEMOModule, failedToRemoveBundleId bundleId: gl_uint32_t, errorIq: XMPPIQ?, outgoingIq: XMPPIQ) {
        
    }
    
    public func omemo(omemo: OMEMOModule, failedToRemoveDeviceIds deviceIds: [NSNumber], errorIq: XMPPIQ?, elementId: String?) {
        dispatch_async(self.workQueue) { [weak self] in
            if let eid = elementId {
                self?.callAndRemoveOutstandingBundleBlock(eid, success: false)
            }
        }
    }
    
    public func omemo(omemo: OMEMOModule, receivedKeyData keyData: [OMEMOKeyData], iv: NSData, senderDeviceId: gl_uint32_t, fromJID: XMPPJID, payload: NSData?, message: XMPPMessage) {
        let aesGcmBlockLength = 16
        guard let encryptedPayload = payload where encryptedPayload.length > aesGcmBlockLength else {
            return
        }
        
        let rid = self.signalEncryptionManager.registrationId
        
        //Could have multiple matching device id. This is extremely rare but possible that the sender has another device that collides with our device id.
        var unencryptedKeyData:NSData?
        for key in keyData {
            if key.deviceId == rid {
                let keyData = key.data
                do {
                    unencryptedKeyData = try self.signalEncryptionManager.decryptFromAddress(keyData, name: fromJID.bare(), deviceId: senderDeviceId)
                    // have successfully decripted the AES key. We should break and use it to decrypt the payload
                    break
                } catch {
                    return
                }
            }
        }
        guard let aesKey = unencryptedKeyData else {
            return
        }
        
        let encryptedBody = encryptedPayload.subdataWithRange(NSMakeRange(0, encryptedPayload.length - aesGcmBlockLength))
        let tag = encryptedPayload.subdataWithRange(NSMakeRange(encryptedPayload.length - aesGcmBlockLength, aesGcmBlockLength))
        
        do {
            guard let messageBody = try OTRSignalEncryptionHelper.decryptData(encryptedBody, key: aesKey, iv: iv, authTag: tag) else {
                return
            }
            let messageString = String(data: messageBody, encoding: NSUTF8StringEncoding)
            let databaseMessage = OTRMessage()
            self.databaseConnection.readWriteWithBlock({ (transaction) in
                // TODO: check if it's our jid and handle as an outgoing message from another device
                guard let buddy = OTRBuddy.fetchBuddyWithUsername(fromJID.bare(), withAccountUniqueId: self.accountYapKey, transaction: transaction) else {
                    return
                }
                databaseMessage.incoming = true
                databaseMessage.text = messageString
                databaseMessage.buddyUniqueId = buddy.uniqueId
                databaseMessage.messageSecurity = .OMEMO
                databaseMessage.messageId = message.elementID()
                
                databaseMessage.saveWithTransaction(transaction)
                
                // Should we be using the date of the xmpp message?
                buddy.lastMessageDate = NSDate()
                buddy.saveWithTransaction(transaction)
                
                //Update device last received message
                let deviceNumber = NSNumber(unsignedInt: senderDeviceId)
                let deviceYapKey = OTROMEMODevice.yapKeyWithDeviceId(deviceNumber, parentKey: buddy.uniqueId, parentCollection: OTRBuddy.collection())
                guard let device = OTROMEMODevice.fetchObjectWithUniqueID(deviceYapKey, transaction: transaction) else {
                    return
                }
                let newDevice = OTROMEMODevice(deviceId: device.deviceId, trustLevel: device.trustLevel, parentKey: device.parentKey, parentCollection: device.parentCollection, publicIdentityKeyData: device.publicIdentityKeyData, lastSeenDate: NSDate())
                newDevice.saveWithTransaction(transaction)
                
                // Send delivery receipt
                guard let account = OTRAccount.fetchObjectWithUniqueID(buddy.accountUniqueId, transaction: transaction) else {
                    return
                }
                guard let protocolManager = OTRProtocolManager.sharedInstance().protocolForAccount(account) as? OTRXMPPManager else {
                    return
                }
                protocolManager.sendDeliveryReceiptForMessage(databaseMessage)
            })
            // Display local notification
            if let _ = databaseMessage.text {
                let messageCopy = databaseMessage.copy() as! OTRMessage
                dispatch_async(dispatch_get_main_queue(), { 
                    UIApplication.sharedApplication().showLocalNotification(messageCopy)
                })
            }
        } catch {
            return
        }
    }
}

extension OTROMEMOSignalCoordinator:OMEMOStorageDelegate {
    
    public func configureWithParent(aParent: OMEMOModule, queue: dispatch_queue_t) -> Bool {
        self.omemoModule = aParent
        self.omemoModuleQueue = queue
        return true
    }
    
    public func storeDeviceIds(deviceIds: [NSNumber], forJID jid: XMPPJID) {
        
        let isOurDeviceList = self.isOurJID(jid)
        
        if (isOurDeviceList) {
            self.omemoStorageManager.storeOurDevices(deviceIds)
        } else {
            self.omemoStorageManager.storeBuddyDevices(deviceIds, buddyUsername: jid.bare())
        }
    }
    
    public func fetchDeviceIdsForJID(jid: XMPPJID) -> [NSNumber] {
        var devices:[OTROMEMODevice]?
        if self.isOurJID(jid) {
            devices = self.omemoStorageManager.getDevicesForOurAccount(nil)
            
        } else {
            devices = self.omemoStorageManager.getDevicesForBuddy(jid.bare(), trusted:nil)
        }
        //Convert from devices array to NSNumber array.
        return (devices?.map({ (device) -> NSNumber in
            return device.deviceId
        })) ?? [NSNumber]()
        
    }

    //Always returns most complete bundle with correct count of prekeys
    public func fetchMyBundle() -> OMEMOBundle? {
        
        guard let bundle = self.signalEncryptionManager.storage.fetchOurExistingBundle() ?? self.signalEncryptionManager.generateOutgoingBundle(self.preKeyCount) else {
            return nil
        }
        
        var preKeys = bundle.preKeys
        
        let keysToGenerate = Int(self.preKeyCount) - preKeys.count
        
        //Check if we don't have all the prekeys we need
        if (keysToGenerate > 0) {
            var start:UInt = 0
            if let maxId = self.signalEncryptionManager.storage.currentMaxPreKeyId() {
                start = UInt(maxId) + 1
            }
            
            let newPreKeys = self.signalEncryptionManager.generatePreKeys(start, count: UInt(keysToGenerate))
            newPreKeys?.forEach({ (preKey) in
                preKeys.updateValue(preKey.keyPair().publicKey, forKey: preKey.preKeyId())
            })
        }
        
        var preKeysArray = [OMEMOPreKey]()
        preKeys.forEach { (id,data) in
            let omemoPreKey = OMEMOPreKey(preKeyId: id, publicKey: data)
            preKeysArray.append(omemoPreKey)
        }
        
        let omemoSignedPreKey = OMEMOSignedPreKey(preKeyId: bundle.bundle.signedPreKeyId, publicKey: bundle.bundle.signedPublicPreKey, signature: bundle.bundle.signedPreKeySignature)
        return OMEMOBundle(deviceId: bundle.bundle.deviceId, identityKey: bundle.bundle.publicIdentityKey, signedPreKey: omemoSignedPreKey, preKeys: preKeysArray)
    }

    public func isSessionValid(jid: XMPPJID, deviceId: gl_uint32_t) -> Bool {
        return self.signalEncryptionManager.sessionRecordExistsForUsername(jid.bare(), deviceId: Int32(deviceId))
    }
}
