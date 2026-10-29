//
//  iPicUploadResult.swift
//  iPicUploadImageDemo
//
//  Created by Jason Zheng on 8/31/16.
//  Copyright © 2016 Jason Zheng. All rights reserved.
//

import Foundation

public class iPicUploadResult: NSObject, NSSecureCoding {
  public static var supportsSecureCoding: Bool { true }
  public static let sharedClassName: String = "net.toolinbox.iPic.iPicUploadResult"
  
  private static let idKey = "id"
  private static let imageLinkKey = "imageLink"
  private static let errorKey = "error"
  
  private static let versionKey = "version"
  private static let jsonKey = "json"
  
  public var id = UUID().uuidString
  public var imageLink: String?
  public var error: NSError?
  
  public var version = 1
  public var json: Any?
  
  public init(imageLink: String?, error: NSError?) {
    super.init()
    
    self.imageLink = imageLink
    self.error = error
  }
  
  // MARK: - NSCoding
  
  public required init?(coder aDecoder: NSCoder) {
    super.init()
    
    id = (aDecoder.decodeObject(of: NSString.self, forKey: iPicUploadResult.idKey) as String?) ?? ""
    imageLink = aDecoder.decodeObject(of: NSString.self, forKey: iPicUploadResult.imageLinkKey) as String?
    error = aDecoder.decodeObject(of: NSError.self, forKey: iPicUploadResult.errorKey)
    
    version = aDecoder.decodeInteger(forKey: iPicUploadResult.versionKey)
    json = aDecoder.decodeObject(of: [NSArray.self, NSDictionary.self, NSString.self, NSNumber.self, NSNull.self], forKey: iPicUploadResult.jsonKey)
  }
  
  public func encode(with aCoder: NSCoder) {
    aCoder.encode(id, forKey: iPicUploadResult.idKey)
    aCoder.encode(imageLink, forKey: iPicUploadResult.imageLinkKey)
    aCoder.encode(error, forKey: iPicUploadResult.errorKey)
    
    aCoder.encode(version, forKey: iPicUploadResult.versionKey)
    aCoder.encode(json, forKey: iPicUploadResult.jsonKey)
  }
}

@objc public class iPicUploadError: NSObject {
  
  public static let Unknown             = iPicUploadError.create(-1, "Unknown error.")
  public static let iPicNotInstalled    = iPicUploadError.create(-11, "iPic wasn't installed.")
  public static let iPicIncompatible    = iPicUploadError.create(-12, "iPic isn't compatible.")
  public static let macOSIncompatible   = iPicUploadError.create(-13, "macOS isn't compatible.")
  public static let FileInaccessable    = iPicUploadError.create(-21, "The file isn't accessable.")
  public static let InvalidImageFile    = iPicUploadError.create(-22, "Invalid image file.")
  public static let InvalidImageHost    = iPicUploadError.create(-31, "Invalid image host.")
  public static let FailedToUpload      = iPicUploadError.create(-32, "Failed to upload.")
  public static let ImageHostNotFound   = iPicUploadError.create(-33, "Image host not found.")
  public static let TimeOut             = iPicUploadError.create(-41, "Time out.")
  
  private static let iPicUploaderDomain = "net.toolinbox.ipic.uploader"
  
  private static func create(_ code: Int, _ description: String) -> NSError {
    return NSError(domain: iPicUploaderDomain, code: code, userInfo: [NSLocalizedDescriptionKey: description])
  }
}
