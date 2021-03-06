//
//  Client+WebSocket.swift
//  StreamChatCore
//
//  Created by Alexey Bukhtin on 20/04/2019.
//  Copyright © 2019 Stream.io Inc. All rights reserved.
//

import Foundation
import Starscream

extension Client {
    
    func setupWebSocket(user: User, token: Token) throws -> WebSocket {
        let logger = logOptions.logger(icon: "🦄", for: [.webSocketError, .webSocket, .webSocketInfo])
        let jsonParameter = WebSocketPayload(user: user, token: token)
        
        var urlComponents = URLComponents()
        urlComponents.scheme = baseURL.wsURL.scheme
        urlComponents.host = baseURL.wsURL.host
        urlComponents.path = baseURL.wsURL.path.appending("connect")
        urlComponents.queryItems = [URLQueryItem(name: "api_key", value: apiKey)]
        
        if user.isAnonymous {
            urlComponents.queryItems?.append(URLQueryItem(name: "stream-auth-type", value: "anonymous"))
        } else {
            urlComponents.queryItems?.append(URLQueryItem(name: "authorization", value: token))
            urlComponents.queryItems?.append(URLQueryItem(name: "stream-auth-type", value: "jwt"))
        }
        
        let jsonData = try JSONEncoder.default.encode(jsonParameter)
        
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            urlComponents.queryItems?.append(URLQueryItem(name: "json", value: jsonString))
        } else {
            logger?.log("❌ Can't create a JSON parameter string from the json: \(jsonParameter)", level: .error)
        }
        
        guard let url = urlComponents.url else {
            logger?.log("❌ Bad URL: \(urlComponents)", level: .error)
            throw ClientError.invalidURL(urlComponents.description)
        }
        
        var request = URLRequest(url: url)
        request.allHTTPHeaderFields = authHeaders(token: token)
        
        let webSocket = WebSocket(request,
                                  callbackQueue: callbackQueue,
                                  stayConnectedInBackground: stayConnectedInBackground,
                                  logger: logger)
        
        webSocket.onConnect = setupWebSocketOnConnect
        subscriptionBag.add(webSocket.subscribe(callback: webSocketOnEvent))
        
        return webSocket
    }
    
    func setupWebSocketOnConnect(_ connection: Connection) {
        guard isExpiredTokenInProgress, connection.isConnected else {
            onConnect(connection)
            return
        }
        
        performInCallbackQueue { [unowned self] in self.sendWaitingRequests() }
    }
    
    func webSocketOnEvent(_ event: Event) {
        // Update the current user on login.
        if case let .healthCheck(_, user) = event {
            userAtomic.set(user)
            return
        }
        
        updateUserUnreadCount(event: event) // User unread counts should be updated before channels unread counts.
        updateChannelsUnreadCount(event: event)
    }
}

private struct WebSocketPayload: Encodable {
    private enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case userDetails = "user_details"
        case token = "user_token"
        case serverDeterminesConnectionId = "server_determines_connection_id"
    }
    
    let userDetails: User
    let userId: String
    let token: Token
    let serverDeterminesConnectionId = true
    
    init(user: User, token: Token) {
        userDetails = user
        userId = user.id
        self.token = token
    }
}
