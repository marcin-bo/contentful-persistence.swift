//
//  ShallowSync.swift
//  ContentfulPersistence
//
//  Created by JP Wright on 06.03.18.
//  Copyright © 2018 Contentful GmbH. All rights reserved.
//

import Foundation
import Interstellar
import CoreData
import Contentful

extension Client {

    /**
     Perform a subsequent synchronization operation, updating this object with
     the latest content from Contentful.

     Calling this will mutate the instance and also return a reference to itself to the completion
     handler in order to allow chaining of operations.

     - Parameter syncSpace: the relevant `SyncSpace` to perform the subsequent sync on.
     - Parameter syncableTypes: The types that can be synchronized.
     
     - Returns: An `Observable` which will be fired when the `SyncSpace` is fully synchronized with Contentful.
     */
    @discardableResult public func shallowSync(for syncSpace: SyncCoordinator = SyncCoordinator(),
                                               syncableTypes: SyncSpace.SyncableTypes = .all) -> Observable<Result<SyncCoordinator>> {

        let observable = Observable<Result<SyncCoordinator>>()
        self.shallowSync(for: syncSpace, syncableTypes: syncableTypes) { result in
            observable.update(result)
        }
        return observable
    }


    /**
     Perform a subsequent synchronization operation, updating the passed in `SyncSpace` with the
     latest content from Contentful.

     Calling this will mutate passed in SyncSpace and also return a reference to itself to the completion
     handler in order to allow chaining of operations.

     - Parameter syncSpace: the relevant `SyncSpace` to perform the subsequent sync on.
     - Parameter syncableTypes: The types that can be synchronized.
     - Parameter completion: A handler which will be called on completion of the operation

     - Returns: The data task being used, enables cancellation of requests.
     */

    @discardableResult public func shallowSync(for syncSpace: SyncCoordinator = SyncCoordinator(),
                                               syncableTypes: SyncSpace.SyncableTypes = .all,
                                               then completion: @escaping ResultsHandler<SyncCoordinator>) -> URLSessionDataTask? {

        // Sync currently only works for the master environemnt.
        guard environmentId == "master" else {
            completion(Result.error(SDKError.nonMasterEnvironmentsDoNotSupportSync()))
            return nil
        }

        // Preview mode only supports `initialSync` not `nextSync`. The only reason `nextSync` should
        // be called while in preview mode, is internally by the SDK to finish a multiple page sync.
        // We are doing a multi page sync only when syncSpace.hasMorePages is true.
        if !syncSpace.syncToken.isEmpty && clientConfiguration.previewMode == true && syncSpace.hasMorePages == false {
            completion(Result.error(SDKError.previewAPIDoesNotSupportSync()))
            return nil
        }

        let parameters = syncableTypes.parameters + syncSpace.parameters
        return fetch(url: url(endpoint: .sync, parameters: parameters)) { (result: Result<SyncCoordinator>) in

            var mutableResult = result
            if case .success(let newSyncSpace) = result {
                // On each new page, update the original sync space and forward the diffs to the
                // persistence integration.
                syncSpace.updateWithDiffs(from: newSyncSpace)

                // Cache to enable link resolution.
                self.jsonDecoder.linkResolver.cache(resources: newSyncSpace.items)

                mutableResult = .success(syncSpace)
            }
            if let syncSpace = result.value, syncSpace.hasMorePages == true {
                self.shallowSync(for: syncSpace, syncableTypes: syncableTypes, then: completion)
            } else {


                // Resolve links.
                self.jsonDecoder.linkResolver.churnLinks()
                completion(mutableResult)
            }
        }
    }
}

/// Helper methods for decoding instances of the various types in your content model.
public extension JSONDecoder {

    public var managedObjectContext: NSManagedObjectContext {
        get {
            return userInfo[.managedObjectContextKey] as! NSManagedObjectContext
        } set {
            userInfo[.managedObjectContextKey] = newValue
        }
    }
}

public extension Decoder {

    public var managedObjectContext: NSManagedObjectContext {
        return userInfo[.managedObjectContextKey] as! NSManagedObjectContext
    }
}

internal extension CodingUserInfoKey {
    static let managedObjectContextKey = CodingUserInfoKey(rawValue: "managedObjectContext")!
}

/// A container for the synchronized state of a Space
public final class SyncCoordinator: Decodable {

    var parameters: [String: Any] {

        if syncToken.isEmpty {
            return ["initial": true]
        } else {
            return ["sync_token": syncToken]
        }
    }


    internal var assetsMap = [String: Asset]()
    internal var unmappedEntriesMap = [String: Entry]()
    internal var mappedEntriesMap = [String: EntryDecodable]()

    /// An array of identifiers for assets that were deleted after the last sync operations.
    public var deletedAssetIds = [String]()
    /// An array of identifiers for entries that were deleted after the last sync operations.
    public var deletedEntryIds = [String]()

    internal var hasMorePages: Bool

    /// A token which needs to be present to perform a subsequent synchronization operation
    internal(set) public var syncToken = ""

    /// List of Assets currently published on the Space being synchronized
    public var assets: [Asset] {
        return Array(assetsMap.values)
    }

    /// List of Entries currently published on the Space being synchronized
    public var unmappedEntries: [Entry] {
        return Array(unmappedEntriesMap.values)
    }

    /// List of Entries currently published on the Space being synchronized
    public var mappedEntries: [EntryDecodable] {
        return Array(mappedEntriesMap.values)
    }

    public var items: [ResourceProtocol & Decodable] = []

    /**
     Continue a synchronization with previous data.

     - parameter syncToken: The sync token from a previous synchronization

     - returns: An initialized synchronized space instance
     */
    public init(syncToken: String = "") {
        self.hasMorePages = false
        self.syncToken = syncToken
    }

    internal static func syncToken(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString)?.queryItems else { return "" }
        for component in components {
            if let value = component.value, component.name == "sync_token" {
                return value
            }
        }
        return ""
    }

    public required init(from decoder: Decoder) throws {
        let container   = try decoder.container(keyedBy: CodingKeys.self)
        var syncUrl     = try container.decodeIfPresent(String.self, forKey: .nextPageUrl)

        var hasMorePages = true
        if syncUrl == nil {
            hasMorePages = false
            syncUrl         = try container.decodeIfPresent(String.self, forKey: .nextSyncUrl)
        }

        guard let nextSyncUrl = syncUrl else {
            throw SDKError.unparseableJSON(data: nil, errorMessage: "No sync url for future sync operations was serialized from the response.")
        }

        self.syncToken = SyncCoordinator.syncToken(from: nextSyncUrl)
        self.hasMorePages = hasMorePages

        let managedObjectContext = decoder.managedObjectContext

        var error: Error?
        managedObjectContext.performAndWait {
            do {
                let contentTypes = decoder.userInfo[.contentTypesContextKey] as! [ContentTypeId: EntryDecodable.Type]
                let localizationContext = decoder.localizationContext
                self.items = []
                for (_, locale) in localizationContext.locales {
                    localizationContext.currentLocale = locale
                    let newItems = try container.decodeHeterogeneousCollection(forKey: .items,
                                                                               contentTypes: contentTypes,
                                                                               throwIfNotPresent: true) ?? []
                    self.items.append(contentsOf: newItems)
                }

            } catch let parsingError {
                error = parsingError
            }
        }
        if let error = error {
            throw(error)
        }
        cache(resources: self.items)
    }

    private enum CodingKeys: String, CodingKey {
        case nextSyncUrl
        case nextPageUrl
        case items
    }

    // FIXME: this is called after each page so links are resolved again
    internal func updateWithDiffs(from syncSpace: SyncCoordinator) {
        // FIXME: Update with diffs in a better way.
//
        self.items = syncSpace.items
//        for asset in syncSpace.assets {
//            assetsMap[asset.sys.id] = asset
//        }
//
//        // Update and deduplicate all entries.
//        for items in syncSpace.items {
//            unmappedEntriesMap[entry.sys.id] = entry
//        }

        for deletedAssetId in syncSpace.deletedAssetIds {
            assetsMap.removeValue(forKey: deletedAssetId)
        }

        for deletedEntryId in syncSpace.deletedEntryIds {
            mappedEntriesMap.removeValue(forKey: deletedEntryId)
            unmappedEntriesMap.removeValue(forKey: deletedEntryId)
        }

        syncToken = syncSpace.syncToken
    }

    internal func cache(resources: [ResourceProtocol]) {
        for resource in resources {
            switch resource {
            case let asset as Asset:
                self.assetsMap[asset.sys.id] = asset

            case let entry as EntryDecodable:
                self.mappedEntriesMap[entry.id] = entry

            case let deletedResource as DeletedResource:
                switch deletedResource.type {
                case "DeletedAsset": self.deletedAssetIds.append(deletedResource.sys.id)
                case "DeletedEntry": self.deletedEntryIds.append(deletedResource.sys.id)
                default: break
                }
            default: break
            }
        }
    }
}


