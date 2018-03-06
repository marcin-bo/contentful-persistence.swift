//
//  Asset+CoreDataProperties.swift
//
//
//  Created by Boris Bügling on 31/03/16.
//
//
//  Choose "Create NSManagedObject Subclass…" from the Core Data editor menu
//  to delete and recreate this implementation file for your updated model.
//

import Foundation
import CoreData
@testable import ContentfulPersistence
import Contentful

extension Asset: AssetPersistable, Decodable {

    // ContentSysPersistable
    @NSManaged var id: String
    @NSManaged var localeCode: String
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?

    // AssetPersistable
    @NSManaged var title: String?
    @NSManaged var assetDescription: String?
    @NSManaged var urlString: String?
    @NSManaged var fileType: String?
    @NSManaged var fileName: String?

    @NSManaged var size: NSNumber?
    @NSManaged var width: NSNumber?
    @NSManaged var height: NSNumber?

    @NSManaged var featuredImage_2wKn6yEnZewu2SCCkus4as_Inverse: NSSet?
    @NSManaged var icon_5KMiN6YPvi42icqAUQMCQe_Inverse: NSSet?
    @NSManaged var profilePhoto_1kUEViTN4EmGiEaaeC6ouY_Inverse: NSSet?

    public convenience init(from decoder: Decoder) throws {
        // Create NSEntityDescription with NSManagedObjectContext
        guard let managedObjectContext = decoder.userInfo[.managedObjectContextKey] as? NSManagedObjectContext,
            let entity = NSEntityDescription.entity(forEntityName: String(describing: Asset.self), in: managedObjectContext) else {
                fatalError("Failed to decode Person!")
        }
        self.init(entity: entity, insertInto: managedObjectContext)

        let sys     = try decoder.sys()
        id          = sys.id
        updatedAt   = sys.updatedAt
        createdAt   = sys.createdAt
        localeCode  = decoder.localizationContext.currentLocale.code

        let fields      = try decoder.contentfulFieldsContainer(keyedBy: Contentful.Asset.Fields.self)

        title = try fields.decode(String.self, forKey: .title)
        assetDescription = try fields.decode(String.self, forKey: .description)

        let file = try fields.decode(Contentful.Asset.FileMetadata.self, forKey: .file)
        urlString = file.url?.absoluteString
        fileType = file.contentType
        fileName = file.fileName

        size = file.details?.size != nil ? NSNumber(value: file.details!.size) : nil
        width = file.details?.imageInfo?.width != nil ? NSNumber(value: file.details!.imageInfo!.width) : nil
        height = file.details?.imageInfo?.height != nil ? NSNumber(value: file.details!.imageInfo!.height) : nil
    }
}
