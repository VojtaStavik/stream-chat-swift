//
//  Client+Events.swift
//  StreamChatClient
//
//  Created by Bahadir Oncel on 30.03.2020.
//  Copyright © 2020 Stream.io Inc. All rights reserved.
//

import Foundation

/// Reference for the subscription initiated. Call `cancel()` to end subscription.
public protocol Cancellable {
    /// Cancel the underlying subscription for this object.
    func cancel()
}

/// Reference for the subscription initiated. Call `cancel()` to end the subscription.
/// Alternatively, when this object is deallocated, it calls `cancel()` on itself automatically.
public protocol AutoCancellable: Cancellable {}

struct Subscription: Cancellable {
    private let onCancel: (String) -> Void
    let uuid: String
    
    init(onCancel: @escaping (String) -> Void) {
        self.onCancel = onCancel
        uuid = UUID().uuidString
    }
    
    public func cancel() {
        onCancel(uuid)
    }
}

/// A subscription bag allows you collect multiple subscriptions and cancel them at once.
public final class SubscriptionBag: Cancellable {
    private var subscriptions = [Cancellable]()
    
    /// Add a subscription.
    /// - Parameter subscription: a subscriiption.
    public func add(_ subscription: Cancellable) {
        subscriptions.append(subscription)
    }
    
    /// Add multiple subscriptions in a chain way.
    /// - Parameter subscription: a subscription
    /// - Returns: this subscription bag.
    @discardableResult
    public func adding(_ subscription: Cancellable) -> Self {
        subscriptions.append(subscription)
        return self
    }
    
    /// Cancel and clear all subscriptions in the bag.
    public func cancel() {
        subscriptions.forEach { $0.cancel() }
        subscriptions = []
    }
}

extension Client {
    
    /// Observe events for the given event types.
    /// - Parameters:
    ///   - eventTypes: A set of event types to be observed. Defaults to all events.
    ///   - callback: Callback closure to be called for each new event.
    /// - Returns: `Subscription` object to be able to cancel observing.
    ///            Call `subscription.cancel()` when you want to stop observing.
    /// - Warning: Subscriptions do not cancel on `deinit` and that can cause crashes / memory leaks,
    ///            so make sure you handle subscriptions correctly.
    public func subscribe(forEvents eventTypes: Set<EventType> = Set(EventType.allCases),
                          _ callback: @escaping OnEvent) -> Cancellable {
        subscribe(forEvents: eventTypes, cid: nil, callback)
    }
    
    func subscribe(forEvents eventTypes: Set<EventType> = Set(EventType.allCases),
                   cid: ChannelId?,
                   _ callback: @escaping OnEvent) -> Cancellable {
        let handler: OnEvent = { event in
            if let cid = cid, event.cid != cid {
                return
            }
            
            callback(event)
        }
        
        return webSocket.subscribe(forEvents: eventTypes, callback: handler)
    }
    
    public func subscribeToUserUpdates(_ callback: @escaping OnUpdate<User>) -> Cancellable {
        let subscription = Subscription { [unowned self] uuid in
            self.eventsHandlingQueue.async {
                self.onUserUpdateObservers[uuid] = nil
            }
        }
        
        eventsHandlingQueue.async { [unowned self] in
            self.onUserUpdateObservers[subscription.uuid] = callback
            
            // Send the current value.
            if !self.user.isUnknown {
                callback(self.user)
            }
        }
        
        return subscription
    }
    
    public func subscribeToUnreadCount(_ callback: @escaping OnUpdate<UnreadCount>) -> Cancellable {
        let subscription = Subscription { [unowned self] uuid in
            self.eventsHandlingQueue.async {
                self.onUnreadCountUpdateObservers[uuid] = nil
            }
        }
        
        self.eventsHandlingQueue.async { [unowned self] in
            self.onUnreadCountUpdateObservers[subscription.uuid] = callback
            // Send the current value.
            callback(self.unreadCount)
        }
        
        return subscription
    }
    
    func subscribeToUnreadCount(for channel: Channel, _ callback: @escaping Completion<ChannelUnreadCount>) -> Cancellable {
        let subscriptions = SubscriptionBag()
        
        let query = ChannelQuery(channel: channel, messagesPagination: [.limit(100)], options: [.state, .watch])
        
        let urlSessionTask = queryChannel(query: query) { [unowned self] result in
            if let error = result.error {
                callback(.failure(error))
            }
            
            if let response = result.value {
                let subscription = self.subscribe(cid: response.channel.cid) { _ in
                    callback(.success(channel.unreadCount))
                }
                
                subscriptions.add(subscription)
            }
        }
        
        subscriptions.add(Subscription { _ in urlSessionTask.cancel() })
        
        return subscriptions
    }

    /// Subscribes to the watcher count for a channel that the user is watching
    func subscribeToWatcherCount(for channel: Channel, _ callback: @escaping Completion<Int>) -> Cancellable {
        channel.subscribe(forEvents: [.userStartWatching, .userStopWatching, .messageNew], { event in
            switch event {
            case .userStartWatching(_, let watcherCount, _, _),
                 .userStopWatching(_, let watcherCount, _, _),
                 .messageNew(_, let watcherCount, _, _):
                callback(.success(watcherCount))
            default:
                break
            }
        })
    }
}
