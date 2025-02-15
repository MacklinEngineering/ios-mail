// Copyright (c) 2021 Proton AG
//
// This file is part of Proton Mail.
//
// Proton Mail is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Mail is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Mail. If not, see https://www.gnu.org/licenses/.

import CoreData
import PromiseKit
import ProtonCoreCrypto
import ProtonCoreDataModel
import ProtonCoreHash
import ProtonCoreServices
import SwiftSoup

/// A sending message request builder
///
/// You can create new builder like:
/// ````
///     let builder = MessageSendingRequestBuilder()
/// ````
///

final class MessageSendingRequestBuilder {
    enum BuilderError: Error {
        case MIMEDataNotPrepared
        case plainTextDataNotPrepared
        case packagesFailedToCreate
        case sessionKeyFailedToCreate
    }

    private(set) var bodySessionKey: Data?
    private(set) var bodySessionAlgo: Algorithm?

    private(set) var addressSendPreferences: [String: SendPreferences] = [:]

    private(set) var preAttachments = [PreAttachment]()
    private(set) var password: Passphrase?
    private(set) var hint: String?

    private(set) var mimeSessionKey: Data?
    private(set) var mimeSessionAlgo: Algorithm?
    private(set) var mimeDataPackage: String?

    private(set) var clearBody: String?

    private(set) var plainTextSessionKey: Data?
    private(set) var plainTextSessionAlgo: Algorithm?
    private(set) var plainTextDataPackage: String?

    // [AttachmentID: base64 attachment body]
    private var attachmentBodys: [String: String] = [:]

    private let dependencies: Dependencies

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func update(bodySession: Data, algo: Algorithm) {
        self.bodySessionKey = bodySession
        self.bodySessionAlgo = algo
    }

    func set(password: Passphrase, hint: String?) {
        self.password = password
        self.hint = hint
    }

    func set(clearBody: String) {
        self.clearBody = clearBody
    }

    func add(email: String, sendPreferences: SendPreferences) {
        self.addressSendPreferences[email] = sendPreferences
    }

    func add(attachment: PreAttachment) {
        self.preAttachments.append(attachment)
    }

    func add(encodedAttachmentBodies: [AttachmentID: String]) {
        self.attachmentBodys = Dictionary(
            uniqueKeysWithValues: encodedAttachmentBodies.map { ($0.key.rawValue, $0.value) }
        )
    }

    var clearMimeBodyPackage: ClearBodyPackage? {
        let hasClearMIME = contains(type: .cleartextMIME) || addressSendPreferences.contains(
                where: {
                    $0.value.pgpScheme == .pgpMIME &&
                    $0.value.encrypt == false
                }
            )
        guard hasClearMIME,
              let base64MIMESessionKey = mimeSessionKey?.encodeBase64(),
              let algorithm = mimeSessionAlgo else {
            return nil
        }
        return ClearBodyPackage(
            key: base64MIMESessionKey,
            algo: algorithm
        )
    }

    var clearPlainBodyPackage: ClearBodyPackage? {
        let hasClearPlainText = contains(type: .cleartextInline) ||
            contains(type: .cleartextMIME) ||
            addressSendPreferences.contains(
                where: { $0.value.pgpScheme == .pgpInline && $0.value.encrypt == false }
            )
        guard hasClearPlainText,
              let base64SessionKey = plainTextSessionKey?.encodeBase64(),
              let algorithm = plainTextSessionAlgo else {
            return nil
        }
        return ClearBodyPackage(
            key: base64SessionKey,
            algo: algorithm
        )
    }

    var mimeBody: String {
        if hasMime, let dataPackage = mimeDataPackage {
            return dataPackage
        }
        return ""
    }

    var plainBody: String {
        if hasPlainText, let dataPackage = plainTextDataPackage {
            return dataPackage
        }
        return ""
    }

    var hasMime: Bool {
        return self.contains(type: .pgpMIME) || self.contains(type: .cleartextMIME)
    }

    var hasPlainText: Bool {
        addressSendPreferences.contains(where: { $0.value.mimeType == .plainText })
    }

    func contains(type: PGPScheme) -> Bool {
        addressSendPreferences.contains(where: { $0.value.pgpScheme == type })
    }

    var encodedSessionKey: String? {
        return self.bodySessionKey?.base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
    }

    func getClearBodyPackageIfNeeded(_ addressPackages: [AddressPackageBase]) -> ClearBodyPackage? {
        guard addressPackages.contains(where: { $0.scheme == .cleartextInline || $0.scheme == .cleartextMIME }),
              let algorithm = bodySessionAlgo,
              let encodedSessionKey = self.encodedSessionKey else { return nil }
        return ClearBodyPackage(key: encodedSessionKey, algo: algorithm)
    }

    func getClearAttachmentPackagesIfNeeded(_ addressPackages: [AddressPackageBase]) -> [ClearAttachmentPackage]? {
        guard addressPackages.contains(where: { $0.scheme == .cleartextMIME || $0.scheme == .cleartextInline }) else {
            return nil
        }
        var attachments = [ClearAttachmentPackage]()
        for preAttachment in preAttachments {
            let encodedSession = preAttachment.session
                .base64EncodedString(options: NSData.Base64EncodingOptions(rawValue: 0))
            attachments.append(
                ClearAttachmentPackage(
                    attachmentID: preAttachment.attachmentId,
                    encodedSession: encodedSession,
                    algo: preAttachment.algo
                )
            )
        }
        return attachments.isEmpty ? nil : attachments
    }
}

// MARK: - Build Message Body
extension MessageSendingRequestBuilder {

    func prepareMime(
        senderKey: Key,
        passphrase: Passphrase,
        userKeys: [ArmoredKey],
        keys: [Key]
    ) throws {
        let boundaryMsg = self.generateMessageBoundaryString()
        let messageBody = self.clearBody ?? ""
        var (processedBody, inlines) = extractBase64(clearBody: messageBody, boundary: boundaryMsg)
        processedBody = QuotedPrintable.encode(string: processedBody)

        var signbody = self.buildFirstPartOfBody(boundaryMsg: boundaryMsg, messageBody: processedBody)

        for preAttachment in self.preAttachments {
            guard let attachmentBody = self.attachmentBodys[preAttachment.attachmentId] else {
                continue
            }
            let attachment = preAttachment.att
            // The format is =?charset?encoding?encoded-text?=
            // encoding = B means base64
            let attName = "=?utf-8?B?\(attachment.name.encodeBase64())?="
            let contentID = attachment.contentId ?? ""

            let bodyToAdd = self.buildAttachmentBody(boundaryMsg: boundaryMsg,
                                                     base64AttachmentContent: attachmentBody,
                                                     attachmentName: attName,
                                                     contentID: contentID,
                                                     attachmentMIMEType: attachment.rawMimeType)
            signbody.append(contentsOf: bodyToAdd)
        }
        inlines.forEach { signbody.append(contentsOf: $0) }

        signbody.append(contentsOf: "--\(boundaryMsg)--")

        let encrypted = try signbody.encrypt(withKey: senderKey,
                                             userKeys: userKeys,
                                             mailboxPassphrase: passphrase)
        let (keyPacket, dataPacket) = try self.preparePackages(encrypted: encrypted)

        guard let sessionKey = try keyPacket.getSessionFromPubKeyPackage(
            userKeys: userKeys,
            passphrase: passphrase,
            keys: keys
        ) else {
            throw BuilderError.sessionKeyFailedToCreate
        }
        self.mimeSessionKey = sessionKey.sessionKey
        self.mimeSessionAlgo = sessionKey.algo
        self.mimeDataPackage = dataPacket.base64EncodedString()
    }

    func preparePlainText(
        senderKey: Key,
        passphrase: Passphrase,
        userKeys: [ArmoredKey],
        keys: [Key]
    ) throws {
        let plainText = self.generatePlainTextBody()

        let encrypted = try plainText.encrypt(
            withKey: senderKey,
            userKeys: userKeys,
            mailboxPassphrase: passphrase
        )

        let (keyPacket, dataPacket) = try self.preparePackages(encrypted: encrypted)

        guard let sessionKey = try keyPacket.getSessionFromPubKeyPackage(
            userKeys: userKeys,
            passphrase: passphrase,
            keys: keys
        ) else {
            throw BuilderError.sessionKeyFailedToCreate
        }

        self.plainTextSessionKey = sessionKey.sessionKey
        self.plainTextSessionAlgo = sessionKey.algo
        self.plainTextDataPackage = dataPacket.base64EncodedString()
    }

    func buildAttachmentBody(boundaryMsg: String,
                             base64AttachmentContent: String,
                             attachmentName: String,
                             contentID: String,
                             isAttachment: Bool = true, // false means inline
                             encoding: String = "base64",
                             attachmentMIMEType: String) -> String {
        let disposition = isAttachment ? "attachment" : "inline"
        var body = ""
        body.append(contentsOf: "--\(boundaryMsg)" + "\r\n")
        body.append(contentsOf: "Content-Type: \(attachmentMIMEType); name=\"\(attachmentName)\"" + "\r\n")
        body.append(contentsOf: "Content-Transfer-Encoding: \(encoding)" + "\r\n")
        body.append(contentsOf: "Content-Disposition: \(disposition); filename=\"\(attachmentName)\"" + "\r\n")
        body.append(contentsOf: "Content-ID: <\(contentID)>\r\n")

        body.append(contentsOf: "\r\n")
        body.append(contentsOf: base64AttachmentContent + "\r\n")
        return body
    }

    func buildFirstPartOfBody(boundaryMsg: String, messageBody: String) -> String {
        let typeMessage = "Content-Type: multipart/mixed; boundary=\(boundaryMsg)"
        var signbody = ""
        signbody.append(contentsOf: typeMessage + "\r\n")
        signbody.append(contentsOf: "\r\n")
        signbody.append(contentsOf: "--\(boundaryMsg)" + "\r\n")
        signbody.append(contentsOf: "Content-Type: text/html; charset=utf-8" + "\r\n")
        signbody.append(contentsOf: "Content-Transfer-Encoding: quoted-printable" + "\r\n")
        signbody.append(contentsOf: "Content-Language: en-US" + "\r\n")
        signbody.append(contentsOf: "\r\n")
        signbody.append(contentsOf: messageBody + "\r\n")
        signbody.append(contentsOf: "\r\n")
        signbody.append(contentsOf: "\r\n")
        signbody.append(contentsOf: "\r\n")
        return signbody
    }

    func preparePackages(encrypted: String) throws -> (Data, Data) {
        guard let spilted = try encrypted.split(),
              let keyPacket = spilted.keyPacket,
              let dataPacket = spilted.dataPacket else {
                  throw BuilderError.packagesFailedToCreate
              }
        return (keyPacket, dataPacket)
    }

    func generatePlainTextBody() -> String {
        let body = self.clearBody ?? ""
        // Need to improve replace part
        return body.html2String.preg_replace("\n", replaceto: "\r\n")
    }

    func generateMessageBoundaryString() -> String {
        var boundaryMsg = "uF5XZWCLa1E8CXCUr2Kg8CSEyuEhhw9WU222" // default
        if let random = try? Crypto.random(byte: 20), !random.isEmpty {
            boundaryMsg = HMAC.hexStringFromData(random)
        }
        return boundaryMsg
    }
}

// MARK: - Create builders for each type of message
extension MessageSendingRequestBuilder {
    // swiftlint:disable:next function_body_length
    func generatePackageBuilder() throws -> [PackageBuilder] {
        var out = [PackageBuilder]()
        for (email, sendPreferences) in self.addressSendPreferences {
            var sessionKey = bodySessionKey ?? Data()
            var sessionKeyAlgorithm = bodySessionAlgo ?? .AES256

            if sendPreferences.mimeType == .plainText {
                if let plainTextSessionKey = plainTextSessionKey,
                   let algorithm = plainTextSessionAlgo {
                    sessionKey = plainTextSessionKey
                    sessionKeyAlgorithm = algorithm
                } else {
                    throw BuilderError.plainTextDataNotPrepared
                }
            }

            switch sendPreferences.pgpScheme {
            case .proton:
                out.append(InternalAddressBuilder(
                    type: .proton,
                    email: email,
                    sendPreferences: sendPreferences,
                    session: sessionKey,
                    algo: sessionKeyAlgorithm,
                    atts: self.preAttachments
                ))
            case .encryptedToOutside where self.password != nil:
                out.append(EOAddressBuilder(
                    type: .encryptedToOutside,
                    email: email,
                    sendPreferences: sendPreferences,
                    session: sessionKey,
                    algo: sessionKeyAlgorithm,
                    password: self.password ?? Passphrase(value: ""),
                    atts: self.preAttachments,
                    passwordHint: self.hint,
                    apiService: dependencies.apiService
                ))
            case .cleartextInline:
                out.append(ClearAddressBuilder(
                    type: .cleartextInline,
                    email: email,
                    sendPreferences: sendPreferences
                ))
            case .pgpInline where sendPreferences.publicKeys != nil &&
                sendPreferences.encrypt:
                out.append(PGPAddressBuilder(
                    type: .pgpInline,
                    email: email,
                    sendPreferences: sendPreferences,
                    session: sessionKey,
                    algo: sessionKeyAlgorithm,
                    atts: self.preAttachments
                ))
            case .pgpInline:
                out.append(ClearAddressBuilder(
                    type: .cleartextInline,
                    email: email,
                    sendPreferences: sendPreferences
                ))
            // TODO: Fix the issue about PGP/MIME signed only message.
            case .pgpMIME where sendPreferences.publicKeys != nil: // && sendPreferences.encrypt:
                guard let sessionData = mimeSessionKey,
                      let algorithm = mimeSessionAlgo else {
                    throw BuilderError.MIMEDataNotPrepared
                }
                out.append(PGPMimeAddressBuilder(
                    type: .pgpMIME,
                    email: email,
                    sendPreferences: sendPreferences,
                    session: sessionData,
                    algo: algorithm
                ))
            case .pgpMIME:
                out.append(ClearMimeAddressBuilder(
                    type: .cleartextMIME,
                    email: email,
                    sendPreferences: sendPreferences
                ))
            case .cleartextMIME:
                out.append(ClearMimeAddressBuilder(
                    type: .cleartextMIME,
                    email: email,
                    sendPreferences: sendPreferences
                ))
            default:
                break
            }
        }
        return out
    }
}

extension MessageSendingRequestBuilder {
    struct Dependencies {
        let apiService: APIService
    }
}

// MARK: Build MIME
extension MessageSendingRequestBuilder {
    /// Extract base64 image data from message body
    /// transform these base64 to content ID format
    /// and convert extracted base64 data to EML string value
    /// - Parameters:
    ///   - clearBody: Clear message body
    ///   - boundary: A string for multipart boundary
    /// - Returns:
    ///   - body: Processed message body, every base64 image becomes content ID format
    ///           <img src="data..."> -> <img src="cid:...">
    ///   - inlines: EML string value to represent base64 image
    func extractBase64(clearBody: String, boundary: String) -> (body: String, inlines: [String]) {
        guard
            let document = try? SwiftSoup.parse(clearBody),
            let inlines = try? document.select(#"img[src^="data"]"#).array(),
            !inlines.isEmpty
        else { return (clearBody, []) }

        var data: [String] = []
        for element in inlines {
            let contentID = "\(String.randomString(8))@pm.me"
            guard
                let src = try? element.attr("src"),
                let emlData = inlineDataForEML(from: src, contentID: contentID, boundary: boundary)
            else { continue }
            data.append(emlData)
            _ = try? element.attr("src", "cid:\(contentID)")
        }
        document.outputSettings().prettyPrint(pretty: false)
        guard let updatedBody = try? document.html() else { return (clearBody, []) }
        return (updatedBody, data)
    }

    /// Convert base64 data URI to EML string value
    /// - Parameters:
    ///   - dataURI: "data:image/png;base64,iVBOR.....", the meaning is `data:(mimeType);(encoding), (data)`
    ///   - contentID: inline content ID
    ///   - boundary: A string for multipart boundary
    /// - Returns: EML string value
    private func inlineDataForEML(from dataURI: String, contentID: String, boundary: String) -> String? {
        let pattern = #"^(.*?):(.*?);(.*?),(.*)"#
        guard
            let regex = try? RegularExpressionCache.regex(for: pattern, options: [.allowCommentsAndWhitespace]),
            let match = regex.firstMatch(in: dataURI, range: .init(location: 0, length: dataURI.count)),
            match.numberOfRanges == 5
        else { return nil }

        let mimeType = dataURI[match.range(at: 2)].trimmingCharacters(in: .whitespacesAndNewlines)
        let encoding = dataURI[match.range(at: 3)].trimmingCharacters(in: .whitespacesAndNewlines)
        // The maximum length is 64, should insert `\r\n` every 64 characters
        // Otherwise the EML is broken
        let base64 = dataURI[match.range(at: 4)]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .insert(every: 64, with: "\r\n")
        let name = "\(String.randomString(8))"
        return buildAttachmentBody(
            boundaryMsg: boundary,
            base64AttachmentContent: base64,
            attachmentName: name,
            contentID: contentID,
            isAttachment: false,
            encoding: encoding,
            attachmentMIMEType: mimeType
        )
    }
}
