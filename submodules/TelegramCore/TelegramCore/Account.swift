import Foundation
#if os(macOS)
    import PostboxMac
    import SwiftSignalKitMac
    import MtProtoKitMac
    import TelegramApiMac
#else
    import Postbox
    import SwiftSignalKit
    import TelegramApi
    #if BUCK
        import MtProtoKit
    #else
        import MtProtoKitDynamic
    #endif
    import UIKit
#endif


public protocol AccountState: PostboxCoding {
    func equalsTo(_ other: AccountState) -> Bool
}

public func ==(lhs: AccountState, rhs: AccountState) -> Bool {
    return lhs.equalsTo(rhs)
}

public class AuthorizedAccountState: AccountState {
    public final class State: PostboxCoding, Equatable, CustomStringConvertible {
        let pts: Int32
        let qts: Int32
        let date: Int32
        let seq: Int32
        
        init(pts: Int32, qts: Int32, date: Int32, seq: Int32) {
            self.pts = pts
            self.qts = qts
            self.date = date
            self.seq = seq
        }
        
        public init(decoder: PostboxDecoder) {
            self.pts = decoder.decodeInt32ForKey("pts", orElse: 0)
            self.qts = decoder.decodeInt32ForKey("qts", orElse: 0)
            self.date = decoder.decodeInt32ForKey("date", orElse: 0)
            self.seq = decoder.decodeInt32ForKey("seq", orElse: 0)
        }
        
        public func encode(_ encoder: PostboxEncoder) {
            encoder.encodeInt32(self.pts, forKey: "pts")
            encoder.encodeInt32(self.qts, forKey: "qts")
            encoder.encodeInt32(self.date, forKey: "date")
            encoder.encodeInt32(self.seq, forKey: "seq")
        }
        
        public var description: String {
            return "(pts: \(pts), qts: \(qts), seq: \(seq), date: \(date))"
        }
    }
    
    let isTestingEnvironment: Bool
    let masterDatacenterId: Int32
    let peerId: PeerId
    
    let state: State?
    
    public required init(decoder: PostboxDecoder) {
        self.isTestingEnvironment = decoder.decodeInt32ForKey("isTestingEnvironment", orElse: 0) != 0
        self.masterDatacenterId = decoder.decodeInt32ForKey("masterDatacenterId", orElse: 0)
        self.peerId = PeerId(decoder.decodeInt64ForKey("peerId", orElse: 0))
        self.state = decoder.decodeObjectForKey("state", decoder: { return State(decoder: $0) }) as? State
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        encoder.encodeInt32(self.isTestingEnvironment ? 1 : 0, forKey: "isTestingEnvironment")
        encoder.encodeInt32(self.masterDatacenterId, forKey: "masterDatacenterId")
        encoder.encodeInt64(self.peerId.toInt64(), forKey: "peerId")
        if let state = self.state {
            encoder.encodeObject(state, forKey: "state")
        }
    }
    
    public init(isTestingEnvironment: Bool, masterDatacenterId: Int32, peerId: PeerId, state: State?) {
        self.isTestingEnvironment = isTestingEnvironment
        self.masterDatacenterId = masterDatacenterId
        self.peerId = peerId
        self.state = state
    }
    
    func changedState(_ state: State) -> AuthorizedAccountState {
        return AuthorizedAccountState(isTestingEnvironment: self.isTestingEnvironment, masterDatacenterId: self.masterDatacenterId, peerId: self.peerId, state: state)
    }
    
    public func equalsTo(_ other: AccountState) -> Bool {
        if let other = other as? AuthorizedAccountState {
            return self.isTestingEnvironment == other.isTestingEnvironment && self.masterDatacenterId == other.masterDatacenterId &&
                self.peerId == other.peerId &&
                self.state == other.state
        } else {
            return false
        }
    }
}

public func ==(lhs: AuthorizedAccountState.State, rhs: AuthorizedAccountState.State) -> Bool {
    return lhs.pts == rhs.pts &&
        lhs.qts == rhs.qts &&
        lhs.date == rhs.date &&
        lhs.seq == rhs.seq
}

private let accountRecordToActiveKeychainId = Atomic<[AccountRecordId: Int]>(value: [:])

private func makeExclusiveKeychain(id: AccountRecordId, postbox: Postbox) -> Keychain {
    var keychainId = 0
    let _ = accountRecordToActiveKeychainId.modify { dict in
        var dict = dict
        if let value = dict[id] {
            dict[id] = value + 1
            keychainId = value + 1
        } else {
            keychainId = 0
            dict[id] = 0
        }
        return dict
    }
    return Keychain(get: { key in
        let enabled = accountRecordToActiveKeychainId.with { dict -> Bool in
            return dict[id] == keychainId
        }
        if enabled {
            return postbox.keychainEntryForKey(key)
        } else {
            Logger.shared.log("Keychain", "couldn't get \(key) — not current")
            return nil
        }
    }, set: { (key, data) in
        let enabled = accountRecordToActiveKeychainId.with { dict -> Bool in
            return dict[id] == keychainId
        }
        if enabled {
            postbox.setKeychainEntryForKey(key, value: data)
        } else {
            Logger.shared.log("Keychain", "couldn't set \(key) — not current")
        }
    }, remove: { key in
        let enabled = accountRecordToActiveKeychainId.with { dict -> Bool in
            return dict[id] == keychainId
        }
        if enabled {
            postbox.removeKeychainEntryForKey(key)
        } else {
            Logger.shared.log("Keychain", "couldn't remove \(key) — not current")
        }
    })
}

public class UnauthorizedAccount {
    public let networkArguments: NetworkInitializationArguments
    public let id: AccountRecordId
    public let rootPath: String
    public let basePath: String
    public let testingEnvironment: Bool
    public let postbox: Postbox
    public let network: Network
    
    public var masterDatacenterId: Int32 {
        return Int32(self.network.mtProto.datacenterId)
    }
    
    public let shouldBeServiceTaskMaster = Promise<AccountServiceTaskMasterMode>()
    
    init(networkArguments: NetworkInitializationArguments, id: AccountRecordId, rootPath: String, basePath: String, testingEnvironment: Bool, postbox: Postbox, network: Network, shouldKeepAutoConnection: Bool = true) {
        self.networkArguments = networkArguments
        self.id = id
        self.rootPath = rootPath
        self.basePath = basePath
        self.testingEnvironment = testingEnvironment
        self.postbox = postbox
        self.network = network
        
        network.shouldKeepConnection.set(self.shouldBeServiceTaskMaster.get()
        |> map { mode -> Bool in
            switch mode {
                case .now, .always:
                    return true
                case .never:
                    return false
            }
        })
        
        network.context.performBatchUpdates({
            var datacenterIds: [Int] = [1, 2]
            if !testingEnvironment {
                datacenterIds.append(contentsOf: [4])
            }
            for id in datacenterIds {
                if network.context.authInfoForDatacenter(withId: id) == nil {
                    network.context.authInfoForDatacenter(withIdRequired: id, isCdn: false)
                }
            }
            network.context.beginExplicitBackupAddressDiscovery()
        })
    }
    
    public func changedMasterDatacenterId(accountManager: AccountManager, masterDatacenterId: Int32) -> Signal<UnauthorizedAccount, NoError> {
        if masterDatacenterId == Int32(self.network.mtProto.datacenterId) {
            return .single(self)
        } else {
            let keychain = makeExclusiveKeychain(id: self.id, postbox: self.postbox)
            
            return accountManager.transaction { transaction -> (LocalizationSettings?, ProxySettings?) in
                return (transaction.getSharedData(SharedDataKeys.localizationSettings) as? LocalizationSettings, transaction.getSharedData(SharedDataKeys.proxySettings) as? ProxySettings)
            }
            |> mapToSignal { localizationSettings, proxySettings -> Signal<(LocalizationSettings?, ProxySettings?, NetworkSettings?), NoError> in
                return self.postbox.transaction { transaction -> (LocalizationSettings?, ProxySettings?, NetworkSettings?) in
                    return (localizationSettings, proxySettings, transaction.getPreferencesEntry(key: PreferencesKeys.networkSettings) as? NetworkSettings)
                }
            }
            |> mapToSignal { (localizationSettings, proxySettings, networkSettings) -> Signal<UnauthorizedAccount, NoError> in
                return initializedNetwork(arguments: self.networkArguments, supplementary: false, datacenterId: Int(masterDatacenterId), keychain: keychain, basePath: self.basePath, testingEnvironment: self.testingEnvironment, languageCode: localizationSettings?.primaryComponent.languageCode, proxySettings: proxySettings, networkSettings: networkSettings, phoneNumber: nil)
                |> map { network in
                    let updated = UnauthorizedAccount(networkArguments: self.networkArguments, id: self.id, rootPath: self.rootPath, basePath: self.basePath, testingEnvironment: self.testingEnvironment, postbox: self.postbox, network: network)
                    updated.shouldBeServiceTaskMaster.set(self.shouldBeServiceTaskMaster.get())
                    return updated
                }
            }
        }
    }
}

func accountNetworkUsageInfoPath(basePath: String) -> String {
    return basePath + "/network-usage"
}

public func accountRecordIdPathName(_ id: AccountRecordId) -> String {
    return "account-\(UInt64(bitPattern: id.int64))"
}

public enum AccountResult {
    case upgrading(Float)
    case unauthorized(UnauthorizedAccount)
    case authorized(Account)
}

let telegramPostboxSeedConfiguration: SeedConfiguration = {
    var messageHoles: [PeerId.Namespace: [MessageId.Namespace: Set<MessageTags>]] = [:]
    for peerNamespace in peerIdNamespacesWithInitialCloudMessageHoles {
        messageHoles[peerNamespace] = [
            Namespaces.Message.Cloud: Set(MessageTags.all)
        ]
    }
    
    var globalMessageIdsPeerIdNamespaces = Set<GlobalMessageIdsNamespace>()
    for peerIdNamespace in [Namespaces.Peer.CloudUser, Namespaces.Peer.CloudGroup] {
        globalMessageIdsPeerIdNamespaces.insert(GlobalMessageIdsNamespace(peerIdNamespace: peerIdNamespace, messageIdNamespace: Namespaces.Message.Cloud))
    }
    
    return SeedConfiguration(globalMessageIdsPeerIdNamespaces: globalMessageIdsPeerIdNamespaces, initializeChatListWithHole: (topLevel: ChatListHole(index: MessageIndex(id: MessageId(peerId: PeerId(namespace: Namespaces.Peer.Empty, id: 0), namespace: Namespaces.Message.Cloud, id: 1), timestamp: Int32.max - 1)), groups: ChatListHole(index: MessageIndex(id: MessageId(peerId: PeerId(namespace: Namespaces.Peer.Empty, id: 0), namespace: Namespaces.Message.Cloud, id: 1), timestamp: Int32.max - 1))), messageHoles: messageHoles, existingMessageTags: MessageTags.all, messageTagsWithSummary: MessageTags.unseenPersonalMessage, existingGlobalMessageTags: GlobalMessageTags.all, peerNamespacesRequiringMessageTextIndex: [Namespaces.Peer.SecretChat], peerSummaryCounterTags: { peer in
        if let peer = peer as? TelegramChannel {
            switch peer.info {
                case .group:
                    if let addressName = peer.addressName, !addressName.isEmpty {
                        return [.publicGroups]
                    } else {
                        return [.regularChatsAndPrivateGroups]
                    }
                case .broadcast:
                    return [.channels]
            }
        } else {
            return [.regularChatsAndPrivateGroups]
        }
    }, additionalChatListIndexNamespace: Namespaces.Message.Cloud, messageNamespacesRequiringGroupStatsValidation: [Namespaces.Message.Cloud], defaultMessageNamespaceReadStates: [Namespaces.Message.Local: .idBased(maxIncomingReadId: 0, maxOutgoingReadId: 0, maxKnownId: 0, count: 0, markedUnread: false)], chatMessagesNamespaces: Set([Namespaces.Message.Cloud, Namespaces.Message.Local, Namespaces.Message.SecretIncoming]))
}()

public enum AccountPreferenceEntriesResult {
    case progress(Float)
    case result(String, [ValueBoxKey: PreferencesEntry])
}

public func accountPreferenceEntries(rootPath: String, id: AccountRecordId, keys: Set<ValueBoxKey>, encryptionParameters: ValueBoxEncryptionParameters) -> Signal<AccountPreferenceEntriesResult, NoError> {
    let path = "\(rootPath)/\(accountRecordIdPathName(id))"
    let postbox = openPostbox(basePath: path + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryptionParameters)
    return postbox
    |> mapToSignal { value -> Signal<AccountPreferenceEntriesResult, NoError> in
        switch value {
            case let .upgrading(progress):
                return .single(.progress(progress))
            case let .postbox(postbox):
                return postbox.transaction { transaction -> AccountPreferenceEntriesResult in
                    var result: [ValueBoxKey: PreferencesEntry] = [:]
                    for key in keys {
                        if let value = transaction.getPreferencesEntry(key: key) {
                            result[key] = value
                        }
                    }
                    return .result(path, result)
                }
        }
    }
}

public enum AccountNoticeEntriesResult {
    case progress(Float)
    case result(String, [ValueBoxKey: NoticeEntry])
}

public func accountNoticeEntries(rootPath: String, id: AccountRecordId, encryptionParameters: ValueBoxEncryptionParameters) -> Signal<AccountNoticeEntriesResult, NoError> {
    let path = "\(rootPath)/\(accountRecordIdPathName(id))"
    let postbox = openPostbox(basePath: path + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryptionParameters)
    return postbox
    |> mapToSignal { value -> Signal<AccountNoticeEntriesResult, NoError> in
        switch value {
            case let .upgrading(progress):
                return .single(.progress(progress))
            case let .postbox(postbox):
                return postbox.transaction { transaction -> AccountNoticeEntriesResult in
                    return .result(path, transaction.getAllNoticeEntries())
                }
        }
    }
}

public enum LegacyAccessChallengeDataResult {
    case progress(Float)
    case result(PostboxAccessChallengeData)
}

public func accountLegacyAccessChallengeData(rootPath: String, id: AccountRecordId, encryptionParameters: ValueBoxEncryptionParameters) -> Signal<LegacyAccessChallengeDataResult, NoError> {
    let path = "\(rootPath)/\(accountRecordIdPathName(id))"
    let postbox = openPostbox(basePath: path + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryptionParameters)
    return postbox
    |> mapToSignal { value -> Signal<LegacyAccessChallengeDataResult, NoError> in
        switch value {
            case let .upgrading(progress):
                return .single(.progress(progress))
            case let .postbox(postbox):
                return postbox.transaction { transaction -> LegacyAccessChallengeDataResult in
                    return .result(transaction.legacyGetAccessChallengeData())
                }
        }
    }
}

public func accountTransaction<T>(rootPath: String, id: AccountRecordId, encryptionParameters: ValueBoxEncryptionParameters, transaction: @escaping (Transaction) -> T) -> Signal<T, NoError> {
    let path = "\(rootPath)/\(accountRecordIdPathName(id))"
    let postbox = openPostbox(basePath: path + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryptionParameters)
    return postbox
    |> mapToSignal { value -> Signal<T, NoError> in
        switch value {
            case let .postbox(postbox):
                return postbox.transaction(transaction)
            default:
                return .complete()
        }
    }
}

public func accountWithId(accountManager: AccountManager, networkArguments: NetworkInitializationArguments, id: AccountRecordId, encryptionParameters: ValueBoxEncryptionParameters, supplementary: Bool, rootPath: String, beginWithTestingEnvironment: Bool, backupData: AccountBackupData?, auxiliaryMethods: AccountAuxiliaryMethods, shouldKeepAutoConnection: Bool = true) -> Signal<AccountResult, NoError> {
    let path = "\(rootPath)/\(accountRecordIdPathName(id))"
    
    let postbox = openPostbox(basePath: path + "/postbox", seedConfiguration: telegramPostboxSeedConfiguration, encryptionParameters: encryptionParameters)
    
    return postbox
    |> mapToSignal { result -> Signal<AccountResult, NoError> in
        switch result {
            case let .upgrading(progress):
                return .single(.upgrading(progress))
            case let .postbox(postbox):
                return accountManager.transaction { transaction -> (LocalizationSettings?, ProxySettings?) in
                    return (transaction.getSharedData(SharedDataKeys.localizationSettings) as? LocalizationSettings, transaction.getSharedData(SharedDataKeys.proxySettings) as? ProxySettings)
                }
                |> mapToSignal { localizationSettings, proxySettings -> Signal<AccountResult, NoError> in
                    return postbox.transaction { transaction -> (PostboxCoding?, LocalizationSettings?, ProxySettings?, NetworkSettings?) in
                        var state = transaction.getState()
                        if state == nil, let backupData = backupData {
                            let backupState = AuthorizedAccountState(isTestingEnvironment: beginWithTestingEnvironment, masterDatacenterId: backupData.masterDatacenterId, peerId: PeerId(backupData.peerId), state: nil)
                            state = backupState
                            let dict = NSMutableDictionary()
                            dict.setObject(MTDatacenterAuthInfo(authKey: backupData.masterDatacenterKey, authKeyId: backupData.masterDatacenterKeyId, saltSet: [], authKeyAttributes: [:], mainTempAuthKey: nil, mediaTempAuthKey: nil), forKey: backupData.masterDatacenterId as NSNumber)
                            let data = NSKeyedArchiver.archivedData(withRootObject: dict)
                            transaction.setState(backupState)
                            transaction.setKeychainEntry(data, forKey: "persistent:datacenterAuthInfoById")
                        }
                        
                        return (state, localizationSettings, proxySettings, transaction.getPreferencesEntry(key: PreferencesKeys.networkSettings) as? NetworkSettings)
                    }
                    |> mapToSignal { (accountState, localizationSettings, proxySettings, networkSettings) -> Signal<AccountResult, NoError> in
                        let keychain = makeExclusiveKeychain(id: id, postbox: postbox)
                        
                        if let accountState = accountState {
                            switch accountState {
                                case let unauthorizedState as UnauthorizedAccountState:
                                    return initializedNetwork(arguments: networkArguments, supplementary: supplementary, datacenterId: Int(unauthorizedState.masterDatacenterId), keychain: keychain, basePath: path, testingEnvironment: unauthorizedState.isTestingEnvironment, languageCode: localizationSettings?.primaryComponent.languageCode, proxySettings: proxySettings, networkSettings: networkSettings, phoneNumber: nil)
                                        |> map { network -> AccountResult in
                                            return .unauthorized(UnauthorizedAccount(networkArguments: networkArguments, id: id, rootPath: rootPath, basePath: path, testingEnvironment: unauthorizedState.isTestingEnvironment, postbox: postbox, network: network, shouldKeepAutoConnection: shouldKeepAutoConnection))
                                        }
                                case let authorizedState as AuthorizedAccountState:
                                    return postbox.transaction { transaction -> String? in
                                        return (transaction.getPeer(authorizedState.peerId) as? TelegramUser)?.phone
                                    }
                                    |> mapToSignal { phoneNumber in
                                        return initializedNetwork(arguments: networkArguments, supplementary: supplementary, datacenterId: Int(authorizedState.masterDatacenterId), keychain: keychain, basePath: path, testingEnvironment: authorizedState.isTestingEnvironment, languageCode: localizationSettings?.primaryComponent.languageCode, proxySettings: proxySettings, networkSettings: networkSettings, phoneNumber: phoneNumber)
                                        |> map { network -> AccountResult in
                                            return .authorized(Account(accountManager: accountManager, id: id, basePath: path, testingEnvironment: authorizedState.isTestingEnvironment, postbox: postbox, network: network, networkArguments: networkArguments, peerId: authorizedState.peerId, auxiliaryMethods: auxiliaryMethods, supplementary: supplementary))
                                        }
                                    }
                                case _:
                                    assertionFailure("Unexpected accountState \(accountState)")
                            }
                        }
                        
                        return initializedNetwork(arguments: networkArguments, supplementary: supplementary, datacenterId: 2, keychain: keychain, basePath: path, testingEnvironment: beginWithTestingEnvironment, languageCode: localizationSettings?.primaryComponent.languageCode, proxySettings: proxySettings, networkSettings: networkSettings, phoneNumber: nil)
                        |> map { network -> AccountResult in
                            return .unauthorized(UnauthorizedAccount(networkArguments: networkArguments, id: id, rootPath: rootPath, basePath: path, testingEnvironment: beginWithTestingEnvironment, postbox: postbox, network: network, shouldKeepAutoConnection: shouldKeepAutoConnection))
                        }
                    }
                }
        }
    }
}

public enum TwoStepPasswordDerivation {
    case unknown
    case sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1: Data, salt2: Data, iterations: Int32, g: Int32, p: Data)
    
    fileprivate init(_ apiAlgo: Api.PasswordKdfAlgo) {
        switch apiAlgo {
            case .passwordKdfAlgoUnknown:
                self = .unknown
            case let .passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow(salt1, salt2, g, p):
                self = .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1: salt1.makeData(), salt2: salt2.makeData(), iterations: 100000, g: g, p: p.makeData())
        }
    }
    
    var apiAlgo: Api.PasswordKdfAlgo {
        switch self {
            case .unknown:
                return .passwordKdfAlgoUnknown
            case let .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1, salt2, iterations, g, p):
                precondition(iterations == 100000)
                return .passwordKdfAlgoSHA256SHA256PBKDF2HMACSHA512iter100000SHA256ModPow(salt1: Buffer(data: salt1), salt2: Buffer(data: salt2), g: g, p: Buffer(data: p))
        }
    }
}

public enum TwoStepSecurePasswordDerivation {
    case unknown
    case sha512(salt: Data)
    case PBKDF2_HMAC_sha512(salt: Data, iterations: Int32)
    
    init(_ apiAlgo: Api.SecurePasswordKdfAlgo) {
        switch apiAlgo {
            case .securePasswordKdfAlgoUnknown:
                self = .unknown
            case let .securePasswordKdfAlgoPBKDF2HMACSHA512iter100000(salt):
                self = .PBKDF2_HMAC_sha512(salt: salt.makeData(), iterations: 100000)
            case let .securePasswordKdfAlgoSHA512(salt):
                self = .sha512(salt: salt.makeData())
        }
    }
    
    var apiAlgo: Api.SecurePasswordKdfAlgo {
        switch self {
            case .unknown:
                return .securePasswordKdfAlgoUnknown
            case let .PBKDF2_HMAC_sha512(salt, iterations):
                precondition(iterations == 100000)
                return .securePasswordKdfAlgoPBKDF2HMACSHA512iter100000(salt: Buffer(data: salt))
            case let .sha512(salt):
                return .securePasswordKdfAlgoSHA512(salt: Buffer(data: salt))
        }
    }
}

public struct TwoStepSRPSessionData {
    public let id: Int64
    public let B: Data
}

public struct TwoStepAuthData {
    public let nextPasswordDerivation: TwoStepPasswordDerivation
    public let currentPasswordDerivation: TwoStepPasswordDerivation?
    public let srpSessionData: TwoStepSRPSessionData?
    public let hasRecovery: Bool
    public let hasSecretValues: Bool
    public let currentHint: String?
    public let unconfirmedEmailPattern: String?
    public let secretRandom: Data
    public let nextSecurePasswordDerivation: TwoStepSecurePasswordDerivation
}

public func twoStepAuthData(_ network: Network) -> Signal<TwoStepAuthData, MTRpcError> {
    return network.request(Api.functions.account.getPassword())
    |> map { config -> TwoStepAuthData in
        switch config {
            case let .password(flags, currentAlgo, srpB, srpId, hint, emailUnconfirmedPattern, newAlgo, newSecureAlgo, secureRandom):
                let hasRecovery = (flags & (1 << 0)) != 0
                let hasSecureValues = (flags & (1 << 1)) != 0
                
                let currentDerivation = currentAlgo.flatMap(TwoStepPasswordDerivation.init)
                let nextDerivation = TwoStepPasswordDerivation(newAlgo)
                let nextSecureDerivation = TwoStepSecurePasswordDerivation(newSecureAlgo)
                
                switch nextSecureDerivation {
                    case .unknown:
                        break
                    case .PBKDF2_HMAC_sha512:
                        break
                    case .sha512:
                        preconditionFailure()
                }
                
                var srpSessionData: TwoStepSRPSessionData?
                if let srpB = srpB, let srpId = srpId {
                    srpSessionData = TwoStepSRPSessionData(id: srpId, B: srpB.makeData())
                }
                
                return TwoStepAuthData(nextPasswordDerivation: nextDerivation, currentPasswordDerivation: currentDerivation, srpSessionData: srpSessionData, hasRecovery: hasRecovery, hasSecretValues: hasSecureValues, currentHint: hint, unconfirmedEmailPattern: emailUnconfirmedPattern, secretRandom: secureRandom.makeData(), nextSecurePasswordDerivation: nextSecureDerivation)
        }
    }
}

public func hexString(_ data: Data) -> String {
    let hexString = NSMutableString()
    data.withUnsafeBytes { (bytes: UnsafePointer<UInt8>) -> Void in
        for i in 0 ..< data.count {
            hexString.appendFormat("%02x", UInt(bytes.advanced(by: i).pointee))
        }
    }
    
    return hexString as String
}

public func dataWithHexString(_ string: String) -> Data {
    var hex = string
    if hex.count % 2 != 0 {
        return Data()
    }
    var data = Data()
    while hex.count > 0 {
        let subIndex = hex.index(hex.startIndex, offsetBy: 2)
        let c = String(hex[..<subIndex])
        hex = String(hex[subIndex...])
        var ch: UInt32 = 0
        if !Scanner(string: c).scanHexInt32(&ch) {
            return Data()
        }
        var char = UInt8(ch)
        data.append(&char, count: 1)
    }
    return data
}

func sha1Digest(_ data : Data) -> Data {
    return data.withUnsafeBytes { bytes -> Data in
        return CryptoSHA1(bytes, Int32(data.count))
    }
}

func sha256Digest(_ data : Data) -> Data {
    return data.withUnsafeBytes { bytes -> Data in
        return CryptoSHA256(bytes, Int32(data.count))
    }
}

func sha512Digest(_ data : Data) -> Data {
    return data.withUnsafeBytes { bytes -> Data in
        return CryptoSHA512(bytes, Int32(data.count))
    }
}

func passwordUpdateKDF(password: String, derivation: TwoStepPasswordDerivation) -> (Data, TwoStepPasswordDerivation)? {
    guard let passwordData = password.data(using: .utf8, allowLossyConversion: true) else {
        return nil
    }
    
    switch derivation {
        case .unknown:
            return nil
        case let .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1, salt2, iterations, gValue, p):
            var nextSalt1 = salt1
            var randomSalt1 = Data()
            randomSalt1.count = 32
            randomSalt1.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                arc4random_buf(bytes, 32)
            }
            nextSalt1.append(randomSalt1)
            
            let nextSalt2 = salt2
            
            var g = Data(count: 4)
            g.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                var gValue = gValue
                withUnsafeBytes(of: &gValue, { (sourceBuffer: UnsafeRawBufferPointer) -> Void in
                    let sourceBytes = sourceBuffer.bindMemory(to: Int8.self).baseAddress!
                    for i in 0 ..< 4 {
                        bytes.advanced(by: i).pointee = sourceBytes.advanced(by: 4 - i - 1).pointee
                    }
                })
            }
            
            let pbkdfInnerData = sha256Digest(nextSalt2 + sha256Digest(nextSalt1 + passwordData + nextSalt1) + nextSalt2)
            
            guard let pbkdfResult = MTPBKDF2(pbkdfInnerData, nextSalt1, iterations) else {
                return nil
            }
            
            let x = sha256Digest(nextSalt2 + pbkdfResult + nextSalt2)
            
            let gx = MTExp(g, x, p)!
            
            return (gx, .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1: nextSalt1, salt2: nextSalt2, iterations: iterations, g: gValue, p: p))
    }
}

struct PasswordKDFResult {
    let id: Int64
    let A: Data
    let M1: Data
}

private func paddedToLength(what: Data, to: Data) -> Data {
    if what.count < to.count {
        var what = what
        for _ in 0 ..< to.count - what.count {
            what.insert(0, at: 0)
        }
        return what
    } else {
        return what
    }
}

private func paddedXor(_ a: Data, _ b: Data) -> Data {
    let count = max(a.count, b.count)
    var a = a
    var b = b
    while a.count < count {
        a.insert(0, at: 0)
    }
    while b.count < count {
        b.insert(0, at: 0)
    }
    a.withUnsafeMutableBytes { (aBytes: UnsafeMutablePointer<UInt8>) -> Void in
        b.withUnsafeBytes { (bBytes: UnsafePointer<UInt8>) -> Void in
            for i in 0 ..< count {
                aBytes.advanced(by: i).pointee = aBytes.advanced(by: i).pointee ^ bBytes.advanced(by: i).pointee
            }
        }
    }
    return a
}

func passwordKDF(password: String, derivation: TwoStepPasswordDerivation, srpSessionData: TwoStepSRPSessionData) -> PasswordKDFResult? {
    guard let passwordData = password.data(using: .utf8, allowLossyConversion: true) else {
        return nil
    }
    
    switch derivation {
        case .unknown:
            return nil
        case let .sha256_sha256_PBKDF2_HMAC_sha512_sha256_srp(salt1, salt2, iterations, gValue, p):
            var a = Data(count: p.count)
            let aLength = a.count
            a.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<UInt8>) -> Void in
                let _ = SecRandomCopyBytes(nil, aLength, bytes)
            }
            
            var g = Data(count: 4)
            g.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                var gValue = gValue
                withUnsafeBytes(of: &gValue, { (sourceBuffer: UnsafeRawBufferPointer) -> Void in
                    let sourceBytes = sourceBuffer.bindMemory(to: Int8.self).baseAddress!
                    for i in 0 ..< 4 {
                        bytes.advanced(by: i).pointee = sourceBytes.advanced(by: 4 - i - 1).pointee
                    }
                })
            }
            
            if !MTCheckIsSafeB(srpSessionData.B, p) {
                return nil
            }
            
            let B = paddedToLength(what: srpSessionData.B, to: p)
            let A = paddedToLength(what: MTExp(g, a, p)!, to: p)
            let u = sha256Digest(A + B)
            
            if MTIsZero(u) {
                return nil
            }
            
            let pbkdfInnerData = sha256Digest(salt2 + sha256Digest(salt1 + passwordData + salt1) + salt2)
            
            guard let pbkdfResult = MTPBKDF2(pbkdfInnerData, salt1, iterations) else {
                return nil
            }
            
            let x = sha256Digest(salt2 + pbkdfResult + salt2)
            
            let gx = MTExp(g, x, p)!
            
            let k = sha256Digest(p + paddedToLength(what: g, to: p))
            
            let s1 = MTModSub(B, MTModMul(k, gx, p)!, p)!
            
            if !MTCheckIsSafeGAOrB(s1, p) {
                return nil
            }
            
            let s2 = MTAdd(a, MTMul(u, x)!)!
            let S = MTExp(s1, s2, p)!
            let K = sha256Digest(paddedToLength(what: S, to: p))
            let m1 = paddedXor(sha256Digest(p), sha256Digest(paddedToLength(what: g, to: p)))
            let m2 = sha256Digest(salt1)
            let m3 = sha256Digest(salt2)
            let M = sha256Digest(m1 + m2 + m3 + A + B + K)
            
            return PasswordKDFResult(id: srpSessionData.id, A: A, M1: M)
    }
}

func securePasswordUpdateKDF(password: String, derivation: TwoStepSecurePasswordDerivation) -> (Data, TwoStepSecurePasswordDerivation)? {
    guard let passwordData = password.data(using: .utf8, allowLossyConversion: true) else {
        return nil
    }
    
    switch derivation {
        case .unknown:
            return nil
        case let .sha512(salt):
            var nextSalt = salt
            var randomSalt = Data()
            randomSalt.count = 32
            randomSalt.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                arc4random_buf(bytes, 32)
            }
            nextSalt.append(randomSalt)
        
            var data = Data()
            data.append(nextSalt)
            data.append(passwordData)
            data.append(nextSalt)
            return (sha512Digest(data), .sha512(salt: nextSalt))
        case let .PBKDF2_HMAC_sha512(salt, iterations):
            var nextSalt = salt
            var randomSalt = Data()
            randomSalt.count = 32
            randomSalt.withUnsafeMutableBytes { (bytes: UnsafeMutablePointer<Int8>) -> Void in
                arc4random_buf(bytes, 32)
            }
            nextSalt.append(randomSalt)
            
            guard let passwordHash = MTPBKDF2(passwordData, nextSalt, iterations) else {
                return nil
            }
            return (passwordHash, .PBKDF2_HMAC_sha512(salt: nextSalt, iterations: iterations))
    }
}

func securePasswordKDF(password: String, derivation: TwoStepSecurePasswordDerivation) -> Data? {
    guard let passwordData = password.data(using: .utf8, allowLossyConversion: true) else {
        return nil
    }
    
    switch derivation {
        case .unknown:
            return nil
        case let .sha512(salt):
            var data = Data()
            data.append(salt)
            data.append(passwordData)
            data.append(salt)
            return sha512Digest(data)
        case let .PBKDF2_HMAC_sha512(salt, iterations):
            guard let passwordHash = MTPBKDF2(passwordData, salt, iterations) else {
                return nil
            }
            return passwordHash
    }
}

func verifyPassword(_ account: UnauthorizedAccount, password: String) -> Signal<Api.auth.Authorization, MTRpcError> {
    return twoStepAuthData(account.network)
    |> mapToSignal { authData -> Signal<Api.auth.Authorization, MTRpcError> in
        guard let currentPasswordDerivation = authData.currentPasswordDerivation, let srpSessionData = authData.srpSessionData else {
            return .fail(MTRpcError(errorCode: 400, errorDescription: "INTERNAL_NO_PASSWORD"))
        }
        
        let kdfResult = passwordKDF(password: password, derivation: currentPasswordDerivation, srpSessionData: srpSessionData)
        
        if let kdfResult = kdfResult {
            return account.network.request(Api.functions.auth.checkPassword(password: .inputCheckPasswordSRP(srpId: kdfResult.id, A: Buffer(data: kdfResult.A), M1: Buffer(data: kdfResult.M1))), automaticFloodWait: false)
        } else {
            return .fail(MTRpcError(errorCode: 400, errorDescription: "KDF_ERROR"))
        }
    }
}

public enum AccountServiceTaskMasterMode {
    case now
    case always
    case never
}

public struct AccountNetworkProxyState: Equatable {
    public let address: String
    public let hasConnectionIssues: Bool
}

public enum AccountNetworkState: Equatable {
    case waitingForNetwork
    case connecting(proxy: AccountNetworkProxyState?)
    case updating(proxy: AccountNetworkProxyState?)
    case online(proxy: AccountNetworkProxyState?)
}

public final class AccountAuxiliaryMethods {
    public let updatePeerChatInputState: (PeerChatInterfaceState?, SynchronizeableChatInputState?) -> PeerChatInterfaceState?
    public let fetchResource: (Account, MediaResource, Signal<[(Range<Int>, MediaBoxFetchPriority)], NoError>, MediaResourceFetchParameters?) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>?
    public let fetchResourceMediaReferenceHash: (MediaResource) -> Signal<Data?, NoError>
    public let prepareSecretThumbnailData: (MediaResourceData) -> (CGSize, Data)?
    
    public init(updatePeerChatInputState: @escaping (PeerChatInterfaceState?, SynchronizeableChatInputState?) -> PeerChatInterfaceState?, fetchResource: @escaping (Account, MediaResource, Signal<[(Range<Int>, MediaBoxFetchPriority)], NoError>, MediaResourceFetchParameters?) -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError>?, fetchResourceMediaReferenceHash: @escaping (MediaResource) -> Signal<Data?, NoError>, prepareSecretThumbnailData: @escaping (MediaResourceData) -> (CGSize, Data)?) {
        self.updatePeerChatInputState = updatePeerChatInputState
        self.fetchResource = fetchResource
        self.fetchResourceMediaReferenceHash = fetchResourceMediaReferenceHash
        self.prepareSecretThumbnailData = prepareSecretThumbnailData
    }
}

public struct AccountRunningImportantTasks: OptionSet {
    public var rawValue: Int32
    
    public init(rawValue: Int32) {
        self.rawValue = rawValue
    }
    
    public static let other = AccountRunningImportantTasks(rawValue: 1 << 0)
    public static let pendingMessages = AccountRunningImportantTasks(rawValue: 1 << 1)
}

public struct MasterNotificationKey: Codable {
    public let id: Data
    public let data: Data
}

public func masterNotificationsKey(account: Account, ignoreDisabled: Bool) -> Signal<MasterNotificationKey, NoError> {
    return masterNotificationsKey(masterNotificationKeyValue: account.masterNotificationKey, postbox: account.postbox, ignoreDisabled: ignoreDisabled)
}

private func masterNotificationsKey(masterNotificationKeyValue: Atomic<MasterNotificationKey?>, postbox: Postbox, ignoreDisabled: Bool) -> Signal<MasterNotificationKey, NoError> {
    if let key = masterNotificationKeyValue.with({ $0 }) {
        return .single(key)
    }
    
    return postbox.transaction(ignoreDisabled: ignoreDisabled, { transaction -> MasterNotificationKey in
        if let value = transaction.keychainEntryForKey("master-notification-secret"), !value.isEmpty {
            let authKeyHash = sha1Digest(value)
            let authKeyId = authKeyHash.subdata(in: authKeyHash.count - 8 ..< authKeyHash.count)
            let keyData = MasterNotificationKey(id: authKeyId, data: value)
            let _ = masterNotificationKeyValue.swap(keyData)
            return keyData
        } else {
            var secretData = Data(count: 256)
            let secretDataCount = secretData.count
            if !secretData.withUnsafeMutableBytes({ (bytes: UnsafeMutablePointer<Int8>) -> Bool in
                let copyResult = SecRandomCopyBytes(nil, secretDataCount, bytes)
                return copyResult == errSecSuccess
            }) {
                assertionFailure()
            }
            
            transaction.setKeychainEntry(secretData, forKey: "master-notification-secret")
            let authKeyHash = sha1Digest(secretData)
            let authKeyId = authKeyHash.subdata(in: authKeyHash.count - 8 ..< authKeyHash.count)
            let keyData = MasterNotificationKey(id: authKeyId, data: secretData)
            let _ = masterNotificationKeyValue.swap(keyData)
            return keyData
        }
    })
}

public func decryptedNotificationPayload(key: MasterNotificationKey, data: Data) -> Data? {
    if data.count < 8 {
        return nil
    }
    
    if data.subdata(in: 0 ..< 8) != key.id {
        return nil
    }
    
    let x = 8
    let msgKey = data.subdata(in: 8 ..< (8 + 16))
    let rawData = data.subdata(in: (8 + 16) ..< data.count)
    let sha256_a = sha256Digest(msgKey + key.data.subdata(in: x ..< (x + 36)))
    let sha256_b = sha256Digest(key.data.subdata(in: (40 + x) ..< (40 + x + 36)) + msgKey)
    let aesKey = sha256_a.subdata(in: 0 ..< 8) + sha256_b.subdata(in: 8 ..< (8 + 16)) + sha256_a.subdata(in: 24 ..< (24 + 8))
    let aesIv = sha256_b.subdata(in: 0 ..< 8) + sha256_a.subdata(in: 8 ..< (8 + 16)) + sha256_b.subdata(in: 24 ..< (24 + 8))
    
    guard let data = MTAesDecrypt(rawData, aesKey, aesIv), data.count > 4 else {
        return nil
    }
    
    var dataLength: Int32 = 0
    data.withUnsafeBytes { (bytes: UnsafePointer<Int8>) -> Void in
        memcpy(&dataLength, bytes, 4)
    }
    
    if dataLength < 0 || dataLength > data.count - 4 {
        return nil
    }
    
    let checkMsgKeyLarge = sha256Digest(key.data.subdata(in: (88 + x) ..< (88 + x + 32)) + data)
    let checkMsgKey = checkMsgKeyLarge.subdata(in: 8 ..< (8 + 16))
    
    if checkMsgKey != msgKey {
        return nil
    }
    
    return data.subdata(in: 4 ..< (4 + Int(dataLength)))
}

public func decryptedNotificationPayload(account: Account, data: Data) -> Signal<Data?, NoError> {
    return masterNotificationsKey(masterNotificationKeyValue: account.masterNotificationKey, postbox: account.postbox, ignoreDisabled: true)
    |> map { secret -> Data? in
        return decryptedNotificationPayload(key: secret, data: data)
    }
}

public struct AccountBackupData: Codable, Equatable {
    public var masterDatacenterId: Int32
    public var peerId: Int64
    public var masterDatacenterKey: Data
    public var masterDatacenterKeyId: Int64
}

public final class AccountBackupDataAttribute: AccountRecordAttribute, Equatable {
    public let data: AccountBackupData?
    
    public init(data: AccountBackupData?) {
        self.data = data
    }
    
    public init(decoder: PostboxDecoder) {
        self.data = try? JSONDecoder().decode(AccountBackupData.self, from: decoder.decodeDataForKey("data") ?? Data())
    }
    
    public func encode(_ encoder: PostboxEncoder) {
        if let data = self.data, let serializedData = try? JSONEncoder().encode(data) {
            encoder.encodeData(serializedData, forKey: "data")
        }
    }
    
    public static func ==(lhs: AccountBackupDataAttribute, rhs: AccountBackupDataAttribute) -> Bool {
        return lhs.data == rhs.data
    }
    
    public func isEqual(to: AccountRecordAttribute) -> Bool {
        if let to = to as? AccountBackupDataAttribute {
            return self == to
        } else {
            return false
        }
    }
}

public func accountBackupData(postbox: Postbox) -> Signal<AccountBackupData?, NoError> {
    return postbox.transaction { transaction -> AccountBackupData? in
        guard let state = transaction.getState() as? AuthorizedAccountState else {
            return nil
        }
        guard let authInfoData = transaction.keychainEntryForKey("persistent:datacenterAuthInfoById") else {
            return nil
        }
        guard let authInfo = NSKeyedUnarchiver.unarchiveObject(with: authInfoData) as? NSDictionary else {
            return nil
        }
        guard let datacenterAuthInfo = authInfo.object(forKey: state.masterDatacenterId as NSNumber) as? MTDatacenterAuthInfo else {
            return nil
        }
        guard let authKey = datacenterAuthInfo.authKey else {
            return nil
        }
        return AccountBackupData(masterDatacenterId: state.masterDatacenterId, peerId: state.peerId.toInt64(), masterDatacenterKey: authKey, masterDatacenterKeyId: datacenterAuthInfo.authKeyId)
    }
}

public class Account {
    public let id: AccountRecordId
    public let basePath: String
    public let testingEnvironment: Bool
    public let supplementary: Bool
    public let postbox: Postbox
    public let network: Network
    public let networkArguments: NetworkInitializationArguments
    public let peerId: PeerId
    
    public let auxiliaryMethods: AccountAuxiliaryMethods
    
    private let serviceQueue = Queue()
    
    public private(set) var stateManager: AccountStateManager!
    private(set) var contactSyncManager: ContactSyncManager!
    public private(set) var callSessionManager: CallSessionManager!
    public private(set) var viewTracker: AccountViewTracker!
    public private(set) var pendingMessageManager: PendingMessageManager!
    public private(set) var messageMediaPreuploadManager: MessageMediaPreuploadManager!
    private(set) var mediaReferenceRevalidationContext: MediaReferenceRevalidationContext!
    private var peerInputActivityManager: PeerInputActivityManager!
    private var localInputActivityManager: PeerInputActivityManager!
    private var accountPresenceManager: AccountPresenceManager!
    private var notificationAutolockReportManager: NotificationAutolockReportManager!
    fileprivate let managedContactsDisposable = MetaDisposable()
    fileprivate let managedStickerPacksDisposable = MetaDisposable()
    private let becomeMasterDisposable = MetaDisposable()
    private let managedServiceViewsDisposable = MetaDisposable()
    private let managedOperationsDisposable = DisposableSet()
    private var storageSettingsDisposable: Disposable?
    
    public let importableContacts = Promise<[DeviceContactNormalizedPhoneNumber: ImportableDeviceContactData]>()
    
    public let shouldBeServiceTaskMaster = Promise<AccountServiceTaskMasterMode>()
    public let shouldKeepOnlinePresence = Promise<Bool>()
    public let autolockReportDeadline = Promise<Int32?>()
    public let shouldExplicitelyKeepWorkerConnections = Promise<Bool>(false)
    public let shouldKeepBackgroundDownloadConnections = Promise<Bool>(false)
    
    private let networkStateValue = Promise<AccountNetworkState>(.waitingForNetwork)
    public var networkState: Signal<AccountNetworkState, NoError> {
        return self.networkStateValue.get()
    }
    
    private let networkTypeValue = Promise<NetworkType>()
    public var networkType: Signal<NetworkType, NoError> {
        return self.networkTypeValue.get()
    }
    
    private let _loggedOut = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var loggedOut: Signal<Bool, NoError> {
        return self._loggedOut.get()
    }
    
    private let _importantTasksRunning = ValuePromise<AccountRunningImportantTasks>([], ignoreRepeated: true)
    public var importantTasksRunning: Signal<AccountRunningImportantTasks, NoError> {
        return self._importantTasksRunning.get()
    }
    
    fileprivate let masterNotificationKey = Atomic<MasterNotificationKey?>(value: nil)
    
    var transformOutgoingMessageMedia: TransformOutgoingMessageMedia?
    
    private var lastSmallLogPostTimestamp: Double?
    private let smallLogPostDisposable = MetaDisposable()
    
    public init(accountManager: AccountManager, id: AccountRecordId, basePath: String, testingEnvironment: Bool, postbox: Postbox, network: Network, networkArguments: NetworkInitializationArguments, peerId: PeerId, auxiliaryMethods: AccountAuxiliaryMethods, supplementary: Bool) {
        self.id = id
        self.basePath = basePath
        self.testingEnvironment = testingEnvironment
        self.postbox = postbox
        self.network = network
        self.networkArguments = networkArguments
        self.peerId = peerId
        
        self.auxiliaryMethods = auxiliaryMethods
        self.supplementary = supplementary
        
        self.peerInputActivityManager = PeerInputActivityManager()
        self.callSessionManager = CallSessionManager(postbox: postbox, network: network, maxLayer: networkArguments.voipMaxLayer, addUpdates: { [weak self] updates in
            self?.stateManager?.addUpdates(updates)
        })
        self.stateManager = AccountStateManager(accountPeerId: self.peerId, accountManager: accountManager, postbox: self.postbox, network: self.network, callSessionManager: self.callSessionManager, addIsContactUpdates: { [weak self] updates in
            self?.contactSyncManager?.addIsContactUpdates(updates)
        }, shouldKeepOnlinePresence: self.shouldKeepOnlinePresence.get(), peerInputActivityManager: self.peerInputActivityManager, auxiliaryMethods: auxiliaryMethods)
        self.contactSyncManager = ContactSyncManager(postbox: postbox, network: network, accountPeerId: peerId, stateManager: self.stateManager)
        self.localInputActivityManager = PeerInputActivityManager()
        self.accountPresenceManager = AccountPresenceManager(shouldKeepOnlinePresence: self.shouldKeepOnlinePresence.get(), network: network)
        let _ = (postbox.transaction { transaction -> Void in
            transaction.updatePeerPresencesInternal(presences: [peerId: TelegramUserPresence(status: .present(until: Int32.max - 1), lastActivity: 0)], merge: { _, updated in return updated })
            transaction.setNeedsPeerGroupMessageStatsSynchronization(groupId: Namespaces.PeerGroup.archive, namespace: Namespaces.Message.Cloud)
        }).start()
        self.notificationAutolockReportManager = NotificationAutolockReportManager(deadline: self.autolockReportDeadline.get(), network: network)
        self.autolockReportDeadline.set(
            accountManager.accessChallengeData()
            |> map { dataView -> Int32? in
                guard let autolockDeadline = dataView.data.autolockDeadline else {
                    return nil
                }
                return autolockDeadline
            }
            |> distinctUntilChanged
        )
        
        self.viewTracker = AccountViewTracker(account: self)
        self.messageMediaPreuploadManager = MessageMediaPreuploadManager()
        self.mediaReferenceRevalidationContext = MediaReferenceRevalidationContext()
        self.pendingMessageManager = PendingMessageManager(network: network, postbox: postbox, accountPeerId: peerId, auxiliaryMethods: auxiliaryMethods, stateManager: self.stateManager, localInputActivityManager: self.localInputActivityManager, messageMediaPreuploadManager: self.messageMediaPreuploadManager, revalidationContext: self.mediaReferenceRevalidationContext)
        
        self.network.loggedOut = { [weak self] in
            Logger.shared.log("Account", "network logged out")
            if let strongSelf = self {
                strongSelf._loggedOut.set(true)
                strongSelf.callSessionManager.dropAll()
            }
        }
        self.network.didReceiveSoftAuthResetError = { [weak self] in
            self?.postSmallLogIfNeeded()
        }
        
        let networkStateQueue = Queue()
        /*
        let previousNetworkStatus = Atomic<Bool?>(value: nil)
        let delayNetworkStatus = self.shouldBeServiceTaskMaster.get()
        |> map { mode -> Bool in
            switch mode {
                case .now, .always:
                    return true
                case .never:
                    return false
            }
        }
        |> distinctUntilChanged
        |> deliverOn(networkStateQueue)
        |> mapToSignal { value -> Signal<Bool, NoError> in
            var shouldDelay = false
            let _ = previousNetworkStatus.modify { previous in
                if let previous = previous {
                    if !previous && value {
                        shouldDelay = true
                    }
                } else {
                    shouldDelay = true
                }
                return value
            }
            if shouldDelay {
                let delayedFalse = Signal<Bool, NoError>.single(false)
                |> delay(3.0, queue: networkStateQueue)
                return .single(true)
                |> then(delayedFalse)
            } else {
                return .single(!value)
            }
        }*/
        let networkStateSignal = combineLatest(queue: networkStateQueue, self.stateManager.isUpdating, network.connectionStatus/*, delayNetworkStatus*/)
        |> map { isUpdating, connectionStatus/*, delayNetworkStatus*/ -> AccountNetworkState in
            /*if delayNetworkStatus {
                return .online(proxy: nil)
            }*/
            
            switch connectionStatus {
                case .waitingForNetwork:
                    return .waitingForNetwork
                case let .connecting(proxyAddress, proxyHasConnectionIssues):
                    var proxyState: AccountNetworkProxyState?
                    if let proxyAddress = proxyAddress {
                        proxyState = AccountNetworkProxyState(address: proxyAddress, hasConnectionIssues: proxyHasConnectionIssues)
                    }
                    return .connecting(proxy: proxyState)
                case let .updating(proxyAddress):
                    var proxyState: AccountNetworkProxyState?
                    if let proxyAddress = proxyAddress {
                        proxyState = AccountNetworkProxyState(address: proxyAddress, hasConnectionIssues: false)
                    }
                    return .updating(proxy: proxyState)
                case let .online(proxyAddress):
                    var proxyState: AccountNetworkProxyState?
                    if let proxyAddress = proxyAddress {
                        proxyState = AccountNetworkProxyState(address: proxyAddress, hasConnectionIssues: false)
                    }
                    
                    if isUpdating {
                        return .updating(proxy: proxyState)
                    } else {
                        return .online(proxy: proxyState)
                    }
            }
        }
        self.networkStateValue.set(networkStateSignal
        |> distinctUntilChanged)
        
        self.networkTypeValue.set(currentNetworkType())
        
        let serviceTasksMasterBecomeMaster = self.shouldBeServiceTaskMaster.get()
        |> distinctUntilChanged
        |> deliverOn(self.serviceQueue)
        
        self.becomeMasterDisposable.set(serviceTasksMasterBecomeMaster.start(next: { [weak self] value in
            if let strongSelf = self, (value == .now || value == .always) {
                strongSelf.postbox.becomeMasterClient()
            }
        }))
        
        let shouldBeMaster = combineLatest(self.shouldBeServiceTaskMaster.get(), postbox.isMasterClient())
        |> map { [weak self] shouldBeMaster, isMaster -> Bool in
            if shouldBeMaster == .always && !isMaster {
                self?.postbox.becomeMasterClient()
            }
            return (shouldBeMaster == .now || shouldBeMaster == .always) && isMaster
        }
        |> distinctUntilChanged
        
        self.network.shouldKeepConnection.set(shouldBeMaster)
        self.network.shouldExplicitelyKeepWorkerConnections.set(self.shouldExplicitelyKeepWorkerConnections.get())
        self.network.shouldKeepBackgroundDownloadConnections.set(self.shouldKeepBackgroundDownloadConnections.get())
        
        let serviceTasksMaster = shouldBeMaster
        |> deliverOn(self.serviceQueue)
        |> mapToSignal { [weak self] value -> Signal<Void, NoError> in
            if let strongSelf = self, value {
                Logger.shared.log("Account", "Became master")
                return managedServiceViews(accountPeerId: peerId, network: strongSelf.network, postbox: strongSelf.postbox, stateManager: strongSelf.stateManager, pendingMessageManager: strongSelf.pendingMessageManager)
            } else {
                Logger.shared.log("Account", "Resigned master")
                return .never()
            }
        }
        self.managedServiceViewsDisposable.set(serviceTasksMaster.start())
        
        let pendingMessageManager = self.pendingMessageManager
        self.managedOperationsDisposable.add(postbox.unsentMessageIdsView().start(next: { [weak pendingMessageManager] view in
            pendingMessageManager?.updatePendingMessageIds(view.ids)
        }))
        
        self.managedOperationsDisposable.add(managedSecretChatOutgoingOperations(auxiliaryMethods: auxiliaryMethods, postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedCloudChatRemoveMessagesOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedAutoremoveMessageOperations(postbox: self.postbox).start())
        self.managedOperationsDisposable.add(managedGlobalNotificationSettings(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedSynchronizePinnedChatsOperations(postbox: self.postbox, network: self.network, accountPeerId: self.peerId, stateManager: self.stateManager).start())
        
        self.managedOperationsDisposable.add(managedSynchronizeGroupedPeersOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedSynchronizeInstalledStickerPacksOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager, namespace: .stickers).start())
        self.managedOperationsDisposable.add(managedSynchronizeInstalledStickerPacksOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager, namespace: .masks).start())
        self.managedOperationsDisposable.add(managedSynchronizeMarkFeaturedStickerPacksAsSeenOperations(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedSynchronizeRecentlyUsedMediaOperations(postbox: self.postbox, network: self.network, category: .stickers, revalidationContext: self.mediaReferenceRevalidationContext).start())
        self.managedOperationsDisposable.add(managedSynchronizeSavedGifsOperations(postbox: self.postbox, network: self.network, revalidationContext: self.mediaReferenceRevalidationContext).start())
        self.managedOperationsDisposable.add(managedSynchronizeSavedStickersOperations(postbox: self.postbox, network: self.network, revalidationContext: self.mediaReferenceRevalidationContext).start())
        self.managedOperationsDisposable.add(managedRecentlyUsedInlineBots(postbox: self.postbox, network: self.network, accountPeerId: peerId).start())
        self.managedOperationsDisposable.add(managedLocalTypingActivities(activities: self.localInputActivityManager.allActivities(), postbox: self.postbox, network: self.network, accountPeerId: self.peerId).start())
        self.managedOperationsDisposable.add(managedSynchronizeConsumeMessageContentOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedConsumePersonalMessagesActions(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedSynchronizeMarkAllUnseenPersonalMessagesOperations(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedApplyPendingMessageReactionsActions(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedSynchronizeEmojiKeywordsOperations(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedApplyPendingScheduledMessagesActions(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        
        let importantBackgroundOperations: [Signal<AccountRunningImportantTasks, NoError>] = [
            managedSynchronizeChatInputStateOperations(postbox: self.postbox, network: self.network) |> map { $0 ? AccountRunningImportantTasks.other : [] },
            self.pendingMessageManager.hasPendingMessages |> map { !$0.isEmpty ? AccountRunningImportantTasks.pendingMessages : [] },
            self.accountPresenceManager.isPerformingUpdate() |> map { $0 ? AccountRunningImportantTasks.other : [] },
            self.notificationAutolockReportManager.isPerformingUpdate() |> map { $0 ? AccountRunningImportantTasks.other : [] }
        ]
        let importantBackgroundOperationsRunning = combineLatest(queue: Queue(), importantBackgroundOperations)
        |> map { values -> AccountRunningImportantTasks in
            var result: AccountRunningImportantTasks = []
            for value in values {
                result.formUnion(value)
            }
            return result
        }
        
        self.managedOperationsDisposable.add(importantBackgroundOperationsRunning.start(next: { [weak self] value in
            if let strongSelf = self {
                strongSelf._importantTasksRunning.set(value)
            }
        }))
        self.managedOperationsDisposable.add((accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> map { sharedData -> ProxyServerSettings? in
            if let settings = sharedData.entries[SharedDataKeys.proxySettings] as? ProxySettings {
                return settings.effectiveActiveServer
            } else {
                return nil
            }
        }
        |> distinctUntilChanged).start(next: { activeServer in
            let updated = activeServer.flatMap { activeServer -> MTSocksProxySettings? in
                return activeServer.mtProxySettings
            }
            network.context.updateApiEnvironment { environment in
                let current = environment?.socksProxySettings
                let updateNetwork: Bool
                if let current = current, let updated = updated {
                    updateNetwork = !current.isEqual(updated)
                } else {
                    updateNetwork = (current != nil) != (updated != nil)
                }
                if updateNetwork {
                    network.dropConnectionStatus()
                    return environment?.withUpdatedSocksProxySettings(updated)
                } else {
                    return nil
                }
            }
        }))
        self.managedOperationsDisposable.add(managedConfigurationUpdates(accountManager: accountManager, postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedVoipConfigurationUpdates(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedAppConfigurationUpdates(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedAutodownloadSettingsUpdates(accountManager: accountManager, network: self.network).start())
        self.managedOperationsDisposable.add(managedTermsOfServiceUpdates(postbox: self.postbox, network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedAppUpdateInfo(network: self.network, stateManager: self.stateManager).start())
        self.managedOperationsDisposable.add(managedAppChangelog(postbox: self.postbox, network: self.network, stateManager: self.stateManager, appVersion: self.networkArguments.appVersion).start())
        self.managedOperationsDisposable.add(managedProxyInfoUpdates(postbox: self.postbox, network: self.network, viewTracker: self.viewTracker).start())
        self.managedOperationsDisposable.add(managedLocalizationUpdatesOperations(accountManager: accountManager, postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedPendingPeerNotificationSettings(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedSynchronizeAppLogEventsOperations(postbox: self.postbox, network: self.network).start())
        self.managedOperationsDisposable.add(managedNotificationSettingsBehaviors(postbox: self.postbox).start())
        self.managedOperationsDisposable.add(managedThemesUpdates(accountManager: accountManager, postbox: self.postbox, network: self.network).start())
        
        if !self.supplementary {
            self.managedOperationsDisposable.add(managedAnimatedEmojiUpdates(postbox: self.postbox, network: self.network).start())
        }
        
        let mediaBox = postbox.mediaBox
        self.storageSettingsDisposable = accountManager.sharedData(keys: [SharedDataKeys.cacheStorageSettings]).start(next: { [weak mediaBox] sharedData in
            guard let mediaBox = mediaBox else {
                return
            }
            let settings: CacheStorageSettings = sharedData.entries[SharedDataKeys.cacheStorageSettings] as? CacheStorageSettings ?? CacheStorageSettings.defaultSettings
            mediaBox.setMaxStoreTimes(general: settings.defaultCacheStorageTimeout, shortLived: 60 * 60)
        })
        
        let _ = masterNotificationsKey(masterNotificationKeyValue: self.masterNotificationKey, postbox: self.postbox, ignoreDisabled: false).start(next: { key in
            let encoder = JSONEncoder()
            if let data = try? encoder.encode(key) {
                let _ = try? data.write(to: URL(fileURLWithPath: "\(basePath)/notificationsKey"))
            }
        })
    }
    
    deinit {
        self.managedContactsDisposable.dispose()
        self.managedStickerPacksDisposable.dispose()
        self.managedServiceViewsDisposable.dispose()
        self.managedOperationsDisposable.dispose()
        self.storageSettingsDisposable?.dispose()
        self.smallLogPostDisposable.dispose()
    }
    
    private func postSmallLogIfNeeded() {
        let timestamp = CFAbsoluteTimeGetCurrent()
        if self.lastSmallLogPostTimestamp == nil || self.lastSmallLogPostTimestamp! < timestamp - 30.0 {
            self.lastSmallLogPostTimestamp = timestamp
            let network = self.network
            
            self.smallLogPostDisposable.set((Logger.shared.collectShortLog()
            |> mapToSignal { events -> Signal<Never, NoError> in
                if events.isEmpty {
                    return .complete()
                } else {
                    return network.request(Api.functions.help.saveAppLog(events: events.map { event -> Api.InputAppEvent in
                        return .inputAppEvent(time: event.0, type: "", peer: 0, data: .jsonString(value: event.1))
                    }))
                    |> ignoreValues
                    |> `catch` { _ -> Signal<Never, NoError> in
                        return .complete()
                    }
                }
            }).start())
        }
    }
    
    public func resetStateManagement() {
        self.stateManager.reset()
        self.restartContactManagement()
        self.managedStickerPacksDisposable.set(manageStickerPacks(network: self.network, postbox: self.postbox).start())
        if !self.supplementary {
            self.viewTracker.chatHistoryPreloadManager.start()
        }
    }
    
    public func resetCachedData() {
        self.viewTracker.reset()
    }
    
    public func restartContactManagement() {
        self.contactSyncManager.beginSync(importableContacts: self.importableContacts.get())
    }
    
    public func addAdditionalPreloadHistoryPeerId(peerId: PeerId) -> Disposable {
        return self.viewTracker.chatHistoryPreloadManager.addAdditionalPeerId(peerId: peerId)
    }
    
    public func peerInputActivities(peerId: PeerId) -> Signal<[(PeerId, PeerInputActivity)], NoError> {
        return self.peerInputActivityManager.activities(peerId: peerId)
        |> map { activities in
            return activities.map({ ($0.0, $0.1.activity) })
        }
    }
    
    public func allPeerInputActivities() -> Signal<[PeerId: [PeerId: PeerInputActivity]], NoError> {
        return self.peerInputActivityManager.allActivities()
        |> map { activities in
            var result: [PeerId: [PeerId: PeerInputActivity]] = [:]
            for (chatPeerId, chatActivities) in activities {
                result[chatPeerId] = chatActivities.mapValues({ $0.activity })
            }
            return result
        }
    }
    
    public func updateLocalInputActivity(peerId: PeerId, activity: PeerInputActivity, isPresent: Bool) {
        self.localInputActivityManager.transaction { manager in
            if isPresent {
                manager.addActivity(chatPeerId: peerId, peerId: self.peerId, activity: activity)
            } else {
                manager.removeActivity(chatPeerId: peerId, peerId: self.peerId, activity: activity)
            }
        }
    }
    
    public func acquireLocalInputActivity(peerId: PeerId, activity: PeerInputActivity) -> Disposable {
        return self.localInputActivityManager.acquireActivity(chatPeerId: peerId, peerId: self.peerId, activity: activity)
    }
}

public func accountNetworkUsageStats(account: Account, reset: ResetNetworkUsageStats) -> Signal<NetworkUsageStats, NoError> {
    return networkUsageStats(basePath: account.basePath, reset: reset)
}

public func updateAccountNetworkUsageStats(account: Account, category: MediaResourceStatsCategory, delta: NetworkUsageStatsConnectionsEntry) {
    updateNetworkUsageStats(basePath: account.basePath, category: category, delta: delta)
}

public typealias FetchCachedResourceRepresentation = (_ account: Account, _ resource: MediaResource, _ representation: CachedMediaResourceRepresentation) -> Signal<CachedMediaResourceRepresentationResult, NoError>
public typealias TransformOutgoingMessageMedia = (_ postbox: Postbox, _ network: Network, _ media: AnyMediaReference, _ userInteractive: Bool) -> Signal<AnyMediaReference?, NoError>

public func setupAccount(_ account: Account, fetchCachedResourceRepresentation: FetchCachedResourceRepresentation? = nil, transformOutgoingMessageMedia: TransformOutgoingMessageMedia? = nil, preFetchedResourcePath: @escaping (MediaResource) -> String? = { _ in return nil }) {
    account.postbox.mediaBox.preFetchedResourcePath = preFetchedResourcePath
    account.postbox.mediaBox.fetchResource = { [weak account] resource, intervals, parameters -> Signal<MediaResourceDataFetchResult, MediaResourceDataFetchError> in
        if let strongAccount = account {
            if let result = fetchResource(account: strongAccount, resource: resource, intervals: intervals, parameters: parameters) {
                return result
            } else if let result = strongAccount.auxiliaryMethods.fetchResource(strongAccount, resource, intervals, parameters) {
                return result
            } else {
                return .never()
            }
        } else {
            return .never()
        }
    }
    
    account.postbox.mediaBox.fetchCachedResourceRepresentation = { [weak account] resource, representation in
        if let strongAccount = account, let fetchCachedResourceRepresentation = fetchCachedResourceRepresentation {
            return fetchCachedResourceRepresentation(strongAccount, resource, representation)
        } else {
            return .never()
        }
    }
    
    account.transformOutgoingMessageMedia = transformOutgoingMessageMedia
    account.pendingMessageManager.transformOutgoingMessageMedia = transformOutgoingMessageMedia
}
