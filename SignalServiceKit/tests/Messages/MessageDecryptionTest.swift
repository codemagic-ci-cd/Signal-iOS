//
// Copyright 2022 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import XCTest
@testable import SignalServiceKit
import LibSignalClient

class MessageDecryptionTest: SSKBaseTestSwift {
    let localE164Identifier = "+13235551234"
    let localAci = UUID()
    let localPni = UUID()

    let remoteE164Identifier = "+14715355555"
    lazy var remoteClient: TestSignalClient = FakeSignalClient.generate(e164Identifier: remoteE164Identifier)

    let localClient = LocalSignalClient()
    let localPniClient = LocalSignalClient(identity: .pni)
    let runner = TestProtocolRunner()

    let sealedSenderTrustRoot = Curve25519.generateKeyPair()

    private var fakeMessageSender: FakeMessageSender {
        MockSSKEnvironment.shared.messageSender as! FakeMessageSender
    }

    // MARK: - Hooks

    override func setUp() {
        super.setUp()

        // ensure local client has necessary "registered" state
        identityManager.generateAndPersistNewIdentityKey(for: .aci)
        identityManager.generateAndPersistNewIdentityKey(for: .pni)
        tsAccountManager.registerForTests(withLocalNumber: localE164Identifier, uuid: localAci, pni: localPni)

        (notificationsManager as! NoopNotificationsManager).expectErrors = true
        (udManager as! OWSUDManagerImpl).trustRoot = try! sealedSenderTrustRoot.ecPublicKey()
    }

    // MARK: - Tests

    private let message = "abc"

    private func generateAndDecrypt(type: SSKProtoEnvelopeType,
                                    destinationIdentity: OWSIdentity?,
                                    destinationUuid: UUID? = nil,
                                    prepareForDecryption: (SDSAnyWriteTransaction) -> Void = { _ in },
                                    handleResult: (Result<OWSMessageDecryptResult, Error>, SSKProtoEnvelope) -> Void) {
        write { transaction in
            let localClient: TestSignalClient
            if destinationIdentity == .pni {
                localClient = self.localPniClient
            } else {
                localClient = self.localClient
            }

            switch type {
            case .ciphertext:
                try! runner.initialize(senderClient: remoteClient,
                                       recipientClient: localClient,
                                       transaction: transaction)
            case .prekeyBundle, .unidentifiedSender:
                try! runner.initializePreKeys(senderClient: remoteClient,
                                              recipientClient: localClient,
                                              transaction: transaction)
            default:
                XCTFail("unsupported envelope type for this test: \(type)")
                return
            }

            let ciphertext = try! runner.encrypt(message.data(using: .utf8)!,
                                                 senderClient: remoteClient,
                                                 recipient: localClient.protocolAddress,
                                                 context: transaction)

            let envelopeBuilder = SSKProtoEnvelope.builder(timestamp: Date.ows_millisecondTimestamp())
            envelopeBuilder.setType(type)
            if let destinationUuid = destinationUuid {
                envelopeBuilder.setDestinationUuid(destinationUuid.uuidString)
            } else if destinationIdentity != nil {
                envelopeBuilder.setDestinationUuid(localClient.uuidIdentifier)
            } else {
                XCTFail("Envelope that lacks a destination UUID")
                return
            }

            if type == .unidentifiedSender {
                let senderCert = SMKSecretSessionCipherTest.createCertificateFor(
                    trustRoot: sealedSenderTrustRoot.identityKeyPair,
                    senderAddress: try! SealedSenderAddress(e164: remoteClient.e164Identifier,
                                                            uuidString: remoteClient.uuidIdentifier,
                                                            deviceId: remoteClient.deviceId),
                    identityKey: remoteClient.identityKeyPair.identityKeyPair.publicKey,
                    expirationTimestamp: 13337)
                let usmc = try! UnidentifiedSenderMessageContent(ciphertext,
                                                                 from: senderCert,
                                                                 contentHint: .default,
                                                                 groupId: [])
                envelopeBuilder.setContent(Data(try! sealedSenderEncrypt(usmc,
                                                                         for: localClient.protocolAddress,
                                                                         identityStore: remoteClient.identityKeyStore,
                                                                         context: transaction)))
                envelopeBuilder.setServerTimestamp(13336)
            } else {
                envelopeBuilder.setSourceUuid(remoteClient.uuidIdentifier)
                envelopeBuilder.setSourceDevice(remoteClient.deviceId)
                envelopeBuilder.setContent(Data(ciphertext.serialize()))
            }

            let envelope = try! envelopeBuilder.build()

            prepareForDecryption(transaction)
            handleResult(messageDecrypter.decryptEnvelope(envelope, envelopeData: nil, transaction: transaction),
                         envelope)
        }
    }

    private func expectDecryptsSuccessfully(type: SSKProtoEnvelopeType, destinationIdentity: OWSIdentity) {
        generateAndDecrypt(type: type, destinationIdentity: destinationIdentity) { result, originalEnvelope in
            let decrypted = try! result.get()
            XCTAssertNil(decrypted.envelopeData)
            XCTAssertEqual(decrypted.identity, destinationIdentity)
            XCTAssertNotNil(decrypted.plaintextData)
            XCTAssertEqual(String(data: decrypted.plaintextData!, encoding: .utf8), message)

            if type == .unidentifiedSender {
                XCTAssertNotIdentical(decrypted.envelope, originalEnvelope)
            } else {
                XCTAssertIdentical(decrypted.envelope, originalEnvelope)
            }
        }
    }

    private func expectDecryptionFailure(type: SSKProtoEnvelopeType,
                                         destinationIdentity: OWSIdentity,
                                         destinationUuid: UUID? = nil,
                                         prepareForDecryption: (SDSAnyWriteTransaction) -> Void = { _ in },
                                         isExpectedError: (Error) -> Bool) {
        generateAndDecrypt(type: type,
                           destinationIdentity: destinationIdentity,
                           destinationUuid: destinationUuid,
                           prepareForDecryption: prepareForDecryption) { result, _ in
            switch result {
            case .success:
                XCTFail("should not have decrypted successfully")
            case .failure(let error):
                XCTAssert(isExpectedError(error), "unexpected error: \(error)")
            }
        }
    }

    func testDecryptWhisperExplicitAci() {
        expectDecryptsSuccessfully(type: .ciphertext, destinationIdentity: .aci)
    }

    func testDecryptWhisperPni() {
        expectDecryptionFailure(type: .ciphertext, destinationIdentity: .pni) { error in
            if case MessageProcessingError.invalidMessageTypeForDestinationUuid = error {
                return true
            }
            return false
        }
    }

    func testDecryptPreKeyExplicitAci() {
        expectDecryptsSuccessfully(type: .prekeyBundle, destinationIdentity: .aci)
    }

    func testDecryptPreKeyPni() {
        expectDecryptsSuccessfully(type: .prekeyBundle, destinationIdentity: .pni)
    }

    func testDecryptPreKeyPniWithAciDestinationUuid() {
        expectDecryptionFailure(type: .prekeyBundle,
                                destinationIdentity: .pni,
                                destinationUuid: localClient.uuid) { error in
            if let error = error as? OWSError {
                let underlyingError = error.errorUserInfo[NSUnderlyingErrorKey]
                if case SSKSignedPreKeyStore.Error.noPreKeyWithId(_)? = underlyingError {
                    return true
                }
            }
            return false
        }
    }

    func testDecryptPreKeyPniWithWrongDestinationUuid() {
        expectDecryptionFailure(type: .prekeyBundle,
                                destinationIdentity: .pni,
                                destinationUuid: UUID()) { error in
            if case MessageProcessingError.wrongDestinationUuid = error {
                return true
            }
            return false
        }
    }

    func testDecryptSealedSenderPreKeyPni() {
        expectDecryptionFailure(type: .unidentifiedSender, destinationIdentity: .pni) { error in
            if case MessageProcessingError.invalidMessageTypeForDestinationUuid = error {
                return true
            }
            return false
        }
    }

    private func waitForResendRequestRatchetKey(line: UInt = #line) -> Promise<PublicKey> {
        let (promise, future) = Promise<PublicKey>.pending()

        fakeMessageSender.sendMessageWasCalledBlock = { message in
            guard let resendRequest = message as? OWSOutgoingResendRequest else {
                return
            }
            let decryptionError = try! DecryptionErrorMessage(bytes: resendRequest.decryptionErrorData)
            if let ratchetKey = decryptionError.ratchetKey {
                future.resolve(ratchetKey)
            } else {
                XCTFail("missing ratchet key", line: line)
            }

            self.fakeMessageSender.sendMessageWasCalledBlock = nil
        }
        return promise
    }

    private func checkRemoteRatchetKey(expected: PublicKey) {
        guard let session = try! remoteClient.sessionStore.loadSession(for: localClient.protocolAddress,
                                                                       context: NullContext()) else {
            XCTFail("no session established")
            return
        }
        XCTAssert(try! session.currentRatchetKeyMatches(expected))
    }

    func testMissingSignedPreKey() {
        sskJobQueues.messageSenderJobQueue.setup()

        let requestRatchetKey = waitForResendRequestRatchetKey()

        expectDecryptionFailure(type: .prekeyBundle,
                                destinationIdentity: .aci,
                                prepareForDecryption: { transaction in
            signalProtocolStore(for: .aci).signedPreKeyStore.removeAll(transaction)
        }) { error in
            if let error = error as? OWSError {
                let underlyingError = error.errorUserInfo[NSUnderlyingErrorKey]
                if case SSKSignedPreKeyStore.Error.noPreKeyWithId(_)? = underlyingError {
                    return true
                }
            }
            return false
        }

        checkRemoteRatchetKey(expected: requestRatchetKey.expect(timeout: 1))

        let sealedSenderResendRequestRatchetKey = waitForResendRequestRatchetKey()

        expectDecryptionFailure(type: .unidentifiedSender,
                                destinationIdentity: .aci,
                                prepareForDecryption: { transaction in
            signalProtocolStore(for: .aci).signedPreKeyStore.removeAll(transaction)
        }) { error in
            if let error = error as? OWSError {
                let underlyingError = error.errorUserInfo[NSUnderlyingErrorKey]
                if case SSKSignedPreKeyStore.Error.noPreKeyWithId(_)? = underlyingError {
                    return true
                }
            }
            return false
        }

        checkRemoteRatchetKey(expected: sealedSenderResendRequestRatchetKey.expect(timeout: 1))
    }

    func testMissingOneTimePreKey() {
        sskJobQueues.messageSenderJobQueue.setup()

        let requestRatchetKey = waitForResendRequestRatchetKey()

        expectDecryptionFailure(type: .prekeyBundle,
                                destinationIdentity: .aci,
                                prepareForDecryption: { transaction in
            signalProtocolStore(for: .aci).preKeyStore.removeAll(transaction)
        }) { error in
            if let error = error as? OWSError {
                let underlyingError = error.errorUserInfo[NSUnderlyingErrorKey]
                if case SSKPreKeyStore.Error.noPreKeyWithId(_)? = underlyingError {
                    return true
                }
            }
            return false
        }

        checkRemoteRatchetKey(expected: requestRatchetKey.expect(timeout: 1))

        let sealedSenderResendRequestRatchetKey = waitForResendRequestRatchetKey()

        expectDecryptionFailure(type: .unidentifiedSender,
                                destinationIdentity: .aci,
                                prepareForDecryption: { transaction in
            signalProtocolStore(for: .aci).preKeyStore.removeAll(transaction)
        }) { error in
            if let error = error as? OWSError {
                let underlyingError = error.errorUserInfo[NSUnderlyingErrorKey]
                if case SSKPreKeyStore.Error.noPreKeyWithId(_)? = underlyingError {
                    return true
                }
            }
            return false
        }

        checkRemoteRatchetKey(expected: sealedSenderResendRequestRatchetKey.expect(timeout: 1))
    }
}
