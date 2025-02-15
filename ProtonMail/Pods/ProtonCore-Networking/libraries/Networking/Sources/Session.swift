//
//  Session.swift
//  ProtonCore-Networking - Created on 6/24/21.
//
//  Copyright (c) 2022 Proton Technologies AG
//
//  This file is part of Proton Technologies AG and ProtonCore.
//
//  ProtonCore is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonCore is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonCore.  If not, see <https://www.gnu.org/licenses/>.

import Foundation
import TrustKit

public typealias JSONDictionary = [String: Any]
public typealias JSONCompletion = (_ task: URLSessionDataTask?, _ result: Result<JSONDictionary, NSError>) -> Void
public typealias SessionDecodableResponse = Decodable

public typealias APIDecodableResponse = SessionDecodableResponse

public enum SessionResponseError: Error {

    case configurationError
    case responseBodyIsNotAJSONDictionary(body: Data?, response: HTTPURLResponse?)
    case responseBodyIsNotADecodableObject(body: Data?, response: HTTPURLResponse?)
    case networkingEngineError(underlyingError: NSError)

    private var withoutResponse: SessionResponseError {
        switch self {
        case .configurationError: return self
        case .responseBodyIsNotAJSONDictionary(let body, _): return .responseBodyIsNotAJSONDictionary(body: body, response: nil)
        case .responseBodyIsNotADecodableObject(let body, _): return .responseBodyIsNotADecodableObject(body: body, response: nil)
        case .networkingEngineError: return self
        }
    }

    public var underlyingError: NSError {
        switch self {
        case .configurationError: return self as NSError
        case .responseBodyIsNotAJSONDictionary(let data, let response?), .responseBodyIsNotADecodableObject(let data, let response?):
            if let data = data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return ResponseError(httpCode: response.statusCode, responseCode: object["Code"] as? Int, userFacingMessage: object["Error"] as? String,
                                     underlyingError: self.withoutResponse as NSError) as NSError
            } else {
                return ResponseError(httpCode: response.statusCode, responseCode: nil, userFacingMessage: nil,
                                     underlyingError: self.withoutResponse as NSError) as NSError
            }
        case .responseBodyIsNotAJSONDictionary, .responseBodyIsNotADecodableObject:
            return self as NSError
        case .networkingEngineError(let underlyingError): return underlyingError
        }
    }
}

extension SessionResponseError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .configurationError: return "Configuration error"
        case .responseBodyIsNotAJSONDictionary(let data, _),
             .responseBodyIsNotADecodableObject(let data, _):
            let genericMessage: String = "Network error"
            if let data = data, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object["Error"] as? String ?? genericMessage
            } else {
                return genericMessage
            }
        case .networkingEngineError(let underlyingError): return underlyingError.localizedDescription
        }
    }
}

@available(*, deprecated, message: "Use the signatures with either a JSON dictionary or codable type in the response")
public typealias ResponseCompletion = (_ task: URLSessionDataTask?, _ response: Any?, _ error: NSError?) -> Void

public typealias DownloadCompletion = (_ response: URLResponse?, _ url: URL?, _ error: NSError?) -> Void
public typealias ProgressCompletion = (_ progress: Progress) -> Void

public let defaultTimeout: TimeInterval = 60.0

public func handleAuthenticationChallenge(
    didReceive challenge: URLAuthenticationChallenge,
    noTrustKit: Bool,
    trustKit: TrustKit?,
    challengeCompletionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    trustKitCompletionHandler: @escaping(URLSession.AuthChallengeDisposition,
                                         URLCredential?, @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void = { disposition, credential, completionHandler in completionHandler(disposition, credential) }
) {
    if noTrustKit {
        guard let trust = challenge.protectionSpace.serverTrust else {
            challengeCompletionHandler(.performDefaultHandling, nil)
            return
        }
        let credential = URLCredential(trust: trust)
        challengeCompletionHandler(.useCredential, credential)

    } else if let tk = trustKit {
        let wrappedCompletionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, credential in
            trustKitCompletionHandler(disposition, credential, challengeCompletionHandler)
        }
        guard tk.pinningValidator.handle(challenge, completionHandler: wrappedCompletionHandler) else {
            // TrustKit did not handle this challenge: perhaps it was not for server trust
            // or the domain was not pinned. Fall back to the default behavior
            challengeCompletionHandler(.performDefaultHandling, nil)
            return
        }

    } else {
        assertionFailure("TrustKit not initialized correctly")
        challengeCompletionHandler(.performDefaultHandling, nil)

    }
}

public protocol Session {

    typealias DecodableResponseCompletion<T> = (_ task: URLSessionDataTask?,
                                                _ result: Result<T, SessionResponseError>) -> Void where T: SessionDecodableResponse

    typealias JSONResponseCompletion = (_ task: URLSessionDataTask?, _ result: Result<JSONDictionary, SessionResponseError>) -> Void

    func generate(with method: HTTPMethod,
                  urlString: String,
                  parameters: Any?,
                  timeout: TimeInterval?,
                  retryPolicy: ProtonRetryPolicy.RetryMode) throws -> SessionRequest

    func request(with request: SessionRequest,
                 onDataTaskCreated: @escaping (URLSessionDataTask) -> Void,
                 completion: @escaping JSONResponseCompletion)

    func request<T>(with request: SessionRequest,
                    jsonDecoder: JSONDecoder?,
                    onDataTaskCreated: @escaping (URLSessionDataTask) -> Void,
                    completion: @escaping DecodableResponseCompletion<T>) where T: SessionDecodableResponse

    func download(with request: SessionRequest,
                  destinationDirectoryURL: URL,
                  completion: @escaping DownloadCompletion)

    func upload(with request: SessionRequest,
                keyPacket: Data,
                dataPacket: Data,
                signature: Data?,
                completion: @escaping JSONResponseCompletion,
                uploadProgress: ProgressCompletion?)

    func upload<T>(with request: SessionRequest,
                   keyPacket: Data,
                   dataPacket: Data,
                   signature: Data?,
                   jsonDecoder: JSONDecoder?,
                   completion: @escaping DecodableResponseCompletion<T>,
                   uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse

    func upload(with request: SessionRequest,
                files: [String: URL],
                completion: @escaping JSONResponseCompletion,
                uploadProgress: ProgressCompletion?)

    func upload<T>(with request: SessionRequest,
                   files: [String: URL],
                   jsonDecoder: JSONDecoder?,
                   completion: @escaping DecodableResponseCompletion<T>,
                   uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse

    func uploadFromFile(with request: SessionRequest,
                        keyPacket: Data,
                        dataPacketSourceFileURL: URL,
                        signature: Data?,
                        completion: @escaping JSONResponseCompletion,
                        uploadProgress: ProgressCompletion?)

    func uploadFromFile<T>(with request: SessionRequest,
                           keyPacket: Data,
                           dataPacketSourceFileURL: URL,
                           signature: Data?,
                           jsonDecoder: JSONDecoder?,
                           completion: @escaping DecodableResponseCompletion<T>,
                           uploadProgress: ProgressCompletion?) where T: SessionDecodableResponse

    func setChallenge(noTrustKit: Bool, trustKit: TrustKit?)

    func failsTLS(request: SessionRequest) -> String?

    var sessionConfiguration: URLSessionConfiguration { get }
}

public extension Session {
    func request(with request: SessionRequest,
                 completion: @escaping JSONResponseCompletion) {
        self.request(with: request, onDataTaskCreated: { _ in }, completion: completion)
    }

    func request<T>(with request: SessionRequest,
                    jsonDecoder: JSONDecoder?,
                    completion: @escaping DecodableResponseCompletion<T>) where T: SessionDecodableResponse {
        self.request(with: request, jsonDecoder: jsonDecoder, onDataTaskCreated: { _ in }, completion: completion)
    }
}

public extension Session {

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func request(with request: SessionRequest, completion: @escaping ResponseCompletion) {
        self.request(with: request) { task, result in
            switch result {
            case .success(let response): completion(task, response, nil)
            case .failure(let error):
                completion(task, nil, error.underlyingError)
            }
        }
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func upload(with request: SessionRequest,
                keyPacket: Data,
                dataPacket: Data,
                signature: Data?,
                completion: @escaping ResponseCompletion) {
        self.upload(with: request,
                    keyPacket: keyPacket,
                    dataPacket: dataPacket,
                    signature: signature,
                    completion: completion,
                    uploadProgress: nil)
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func upload(with request: SessionRequest,
                keyPacket: Data, dataPacket: Data, signature: Data?,
                completion: @escaping ResponseCompletion,
                uploadProgress: ProgressCompletion?) {
        upload(with: request, keyPacket: keyPacket, dataPacket: dataPacket, signature: signature) { task, result in
            switch result {
            case .success(let response): completion(task, response, nil)
            case .failure(let error): completion(task, nil, error.underlyingError)
            }
        } uploadProgress: { progress in
            uploadProgress?(progress)
        }
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func upload(with request: SessionRequest,
                files: [String: URL],
                completion: @escaping ResponseCompletion) {
        self.upload(with: request, files: files, completion: completion, uploadProgress: nil)
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func upload(with request: SessionRequest,
                files: [String: URL],
                completion: @escaping ResponseCompletion,
                uploadProgress: ProgressCompletion?) {
        self.upload(with: request, files: files) { task, result in
            switch result {
            case .success(let response): completion(task, response, nil)
            case .failure(let error): completion(task, nil, error.underlyingError)
            }
        } uploadProgress: { progress in
            uploadProgress?(progress)
        }
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func uploadFromFile(with request: SessionRequest,
                        keyPacket: Data,
                        dataPacketSourceFileURL: URL,
                        signature: Data?,
                        completion: @escaping ResponseCompletion) {
        self.uploadFromFile(with: request,
                            keyPacket: keyPacket,
                            dataPacketSourceFileURL: dataPacketSourceFileURL,
                            signature: signature,
                            completion: completion,
                            uploadProgress: nil)
    }

    @available(*, deprecated, message: "Please use the variant returning either DecodableResponseCompletion or JSONResponseCompletion")
    func uploadFromFile(with request: SessionRequest,
                        keyPacket: Data,
                        dataPacketSourceFileURL: URL,
                        signature: Data?,
                        completion: @escaping ResponseCompletion,
                        uploadProgress: ProgressCompletion?) {
        self.uploadFromFile(with: request,
                            keyPacket: keyPacket,
                            dataPacketSourceFileURL: dataPacketSourceFileURL,
                            signature: signature) { task, result in
            switch result {
            case .success(let response): completion(task, response, nil)
            case .failure(let error): completion(task, nil, error.underlyingError)
            }
        } uploadProgress: { progress in
            uploadProgress?(progress)
        }
    }
}

extension Session {

    public func generate(with method: HTTPMethod, urlString: String, parameters: Any? = nil, timeout: TimeInterval? = nil, retryPolicy: ProtonRetryPolicy.RetryMode) throws -> SessionRequest {
        return SessionRequest.init(parameters: parameters,
                                   urlString: urlString,
                                   method: method,
                                   timeout: timeout ?? defaultTimeout,
                                   retryPolicy: retryPolicy)
    }
}

public protocol SessionFactoryInterface {
    func createSessionInstance(url apiHostUrl: String) -> Session
    func createSessionRequest(parameters: Any?, urlString: String, method: HTTPMethod, timeout: TimeInterval, retryPolicy: ProtonRetryPolicy.RetryMode) -> SessionRequest
}

public final class SessionFactory: SessionFactoryInterface {

    public static let instance = SessionFactory()

    private init() {}

    public static func createSessionInstance(url apiHostUrl: String) -> Session {
        instance.createSessionInstance(url: apiHostUrl)
    }

    public static func createSessionRequest(parameters: Any?,
                                            urlString: String,
                                            method: HTTPMethod,
                                            timeout: TimeInterval,
                                            retryPolicy: ProtonRetryPolicy.RetryMode = .userInitiated) -> SessionRequest {
        instance.createSessionRequest(parameters: parameters, urlString: urlString, method: method, timeout: timeout, retryPolicy: retryPolicy)
    }

    public func createSessionInstance(url apiHostUrl: String) -> Session {
        AlamofireSession()
    }

    public func createSessionRequest(
        parameters: Any?, urlString: String, method: HTTPMethod, timeout: TimeInterval, retryPolicy: ProtonRetryPolicy.RetryMode = .userInitiated
    ) -> SessionRequest {
        AlamofireRequest(parameters: parameters, urlString: urlString, method: method, timeout: timeout, retryPolicy: retryPolicy)
    }
}

public class SessionRequest {
    init(parameters: Any?, urlString: String, method: HTTPMethod, timeout: TimeInterval, retryPolicy: ProtonRetryPolicy.RetryMode = .userInitiated) {
        self.parameters = parameters
        self.method = method
        self.urlString = urlString
        self.timeout = timeout
        self.interceptor = ProtonRetryPolicy(mode: retryPolicy)
    }

    var _request: URLRequest?
    public var request: URLRequest? {
        get {
            return self._request
        }
        set {
            self._request = newValue
            self._request?.timeoutInterval = self.timeout
        }
    }

    let parameters: Any?
    let urlString: String
    let method: HTTPMethod
    let timeout: TimeInterval
    let interceptor: ProtonRetryPolicy

    // in the future this dict may have race condition issue. fix it later
    private var headers: [String: String] = [:]

    internal func headerCounts() -> Int {
        return self.headers.count
    }

    internal func hasHeader(key: String) -> Bool {
        return self.headers[key] != nil
    }

    internal func matches(key: String, value: String) -> Bool {
        guard let v = self.headers[key] else {
            return false
        }
        return v == value
    }

    internal func value(key: String) -> String? {
        return self.headers[key]
    }

    public func setValue(header: String, _ value: String) {
        self.headers[header] = value
    }

    // must call after the request be set
    public func updateHeader() {
        for (header, value) in self.headers {
            self.request?.setValue(value, forHTTPHeaderField: header)
        }
    }
}
