//
//  Adapty.swift
//  Adapty
//
//  Created by Andrey Kyashkin on 28/10/2019.
//  Copyright © 2019 Adapty. All rights reserved.
//

import Foundation
import UIKit

@objc public class Adapty: NSObject {
    
    private static let shared = Adapty()
    private var profile: ProfileModel? = DefaultsManager.shared.profile {
        didSet {
            DefaultsManager.shared.profile = profile
        }
    }
    private var installation: InstallationModel? = DefaultsManager.shared.installation {
        didSet {
            DefaultsManager.shared.installation = installation
        }
    }
    private lazy var apiManager: ApiManager = {
        return ApiManager.shared
    }()
    private lazy var sessionsManager: SessionsManager = {
        return SessionsManager()
    }()
    private lazy var iapManager: IAPManager = {
        return IAPManager()
    }()
    
    override private init() {
        super.init()
    }
    
    @objc public class func activate(_ apiKey: String) {
        Constants.APIKeys.secretKey = apiKey
        shared.configure()
    }
    
    private func configure() {
        AppDelegateSwizzler.startSwizzlingIfPossible(self)
        
        if profile == nil {
            // didn't find existing profile, create a new one and perform initial requests right after
            createProfile()
        } else {
            // already have a profile, just perform initial requests
            performInitialRequests()
        }
        
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] (_) in
            self?.sessionsManager.trackLiveEventInBackground()
        }
    }
    
    private func performInitialRequests() {
        // sync installation data and receive cognito credentials
        syncInstallation { _, _ in
            // start live tracking
            self.sessionsManager.startTrackingLiveEvent()
        }
        
        // start observing purchases
        iapManager.startObservingPurchases()
        
        // sync latest receipt to server and obtain eligibility criteria for introductory and promotional offers
        syncTransactionsHistory()
    }
    
    //MARK: - REST
    
    private func createProfile(_ completion: ErrorCompletion? = nil) {
        if profile != nil {
            completion?(NetworkResponse.alreadyAuthenticatedError)
            return
        }
        
        var attributes = Parameters()
        
        if let idfa = UserProperties.idfa { attributes["idfa"] = idfa }
        
        let params = Parameters.formatData(with: UserProperties.staticUuid, type: Constants.TypeNames.profile, attributes: attributes)
        
        apiManager.createProfile(id: UserProperties.staticUuid, params: params) { (profile, error, isNew) in
            self.profile = profile
            completion?(error)
            
            if error == nil {
                self.performInitialRequests()
            }
        }
    }
    
    @objc public class func updateProfile(
        customerUserId: String? = nil,
        email: String? = nil,
        phoneNumber: String? = nil,
        facebookUserId: String? = nil,
        firstName: String? = nil,
        lastName: String? = nil,
        gender: String? = nil,
        birthday: Date? = nil,
        completion: ErrorCompletion? = nil)
    {
        guard let profileId = shared.profile?.profileId else {
            completion?(NetworkResponse.missingRequiredParams)
            return
        }
        
        var attributes = Parameters()
        
        if let customerUserId = customerUserId { attributes["customer_user_id"] = customerUserId }
        if let email = email { attributes["email"] = email }
        if let phoneNumber = phoneNumber { attributes["phone_number"] = phoneNumber }
        if let facebookUserId = facebookUserId { attributes["facebook_user_id"] = facebookUserId }
        if let firstName = firstName { attributes["first_name"] = firstName }
        if let lastName = lastName { attributes["last_name"] = lastName }
        if let gender = gender { attributes["gender"] = gender }
        if let birthday = birthday { attributes["birthday"] = birthday.stringValue }
        if let idfa = UserProperties.idfa { attributes["idfa"] = idfa }
        
        let params = Parameters.formatData(with: profileId, type: Constants.TypeNames.profile, attributes: attributes)
        
        shared.apiManager.updateProfile(id: profileId, params: params) { (profile, error) in
            if let profile = profile {
                // do not overwrite in case of error
                shared.profile = profile
            }
            completion?(error)
        }
    }
    
    private func syncInstallation(_ completion: InstallationCompletion? = nil) {
        guard let profileId = profile?.profileId else {
            completion?(nil, NetworkResponse.missingRequiredParams)
            return
        }
        
        let installationMetaId = installation?.profileInstallationMetaId ?? UserProperties.uuid

        var attributes = Parameters()
        
        if let sdkVersion = UserProperties.sdkVersion { attributes["adapty_sdk_version"] = sdkVersion }
        attributes["adapty_sdk_version_build"] = UserProperties.sdkVersionBuild
        if let appBuild = UserProperties.appBuild { attributes["app_build"] = appBuild }
        if let appVersion = UserProperties.appVersion { attributes["app_version"] = appVersion }
        attributes["device"] = UserProperties.device
        attributes["locale"] = UserProperties.locale
        attributes["os"] = UserProperties.OS
        attributes["platform"] = UserProperties.platform
        attributes["timezone"] = UserProperties.timezone
        if let deviceIdentifier = UserProperties.deviceIdentifier { attributes["device_identifier"] = deviceIdentifier }
        if let apnsTokenString = apnsTokenString { attributes["device_token"] = apnsTokenString }
        
        #warning("Handle Adjust params")
        
        let params = Parameters.formatData(with: installationMetaId, type: Constants.TypeNames.installation, attributes: attributes)
        
        apiManager.syncInstallation(id: installationMetaId, profileId: profileId, params: params) { (installation, error) in
            if let installation = installation {
                // do not overwrite in case of error
                self.installation = installation
            }
            completion?(installation, error)
        }
    }
    
    @objc public class func updateAdjustAttribution(_ attribution: NSObject?, completion: ErrorCompletion? = nil) {
        guard let profileId = shared.profile?.profileId, let installationMetaId = shared.installation?.profileInstallationMetaId else {
            completion?(NetworkResponse.missingRequiredParams)
            return
        }
        
        var attributes = Parameters()

        if let network = attribution?.value(forKey: "network") { attributes["attribution_network"] = network }
        if let campaign = attribution?.value(forKey: "campaign") { attributes["attribution_campaign"] = campaign }
        if let trackerToken = attribution?.value(forKey: "trackerToken") { attributes["attribution_tracker_token"] = trackerToken }
        if let trackerName = attribution?.value(forKey: "trackerName") { attributes["attribution_tracker_name"] = trackerName }
        if let adgroup = attribution?.value(forKey: "adgroup") { attributes["attribution_adgroup"] = adgroup }
        if let creative = attribution?.value(forKey: "creative") { attributes["attribution_creative"] = creative }
        if let clickLabel = attribution?.value(forKey: "clickLabel") { attributes["attribution_click_label"] = clickLabel }
        if let adid = attribution?.value(forKey: "adid") { attributes["attribution_adid"] = adid }
        
        let params = Parameters.formatData(with: installationMetaId, type: Constants.TypeNames.installation, attributes: attributes)
        
        shared.apiManager.syncInstallation(id: installationMetaId, profileId: profileId, params: params) { (installation, error) in
            if let installation = installation {
                // do not overwrite in case of error
                shared.installation = installation
            }
            completion?(error)
        }
    }
    
    @objc public class func getPurchaseContainers(_ completion: @escaping PurchaseContainersCompletion) {
        shared.iapManager.getPurchaseContainers(completion)
    }
    
    @objc public class func makePurchase(product: ProductModel, offerId: String? = nil, completion: @escaping BuyProductCompletion) {
        shared.iapManager.makePurchase(product: product, offerId: offerId, completion: completion)
    }
    
    @objc public class func restorePurchases(completion: @escaping ErrorCompletion) {
        shared.iapManager.restorePurchases(completion)
    }
    
    @objc public class func validateReceipt(_ receiptEncoded: String, variationId: String? = nil, originalPrice: NSDecimalNumber? = nil, discountPrice: NSDecimalNumber? = nil, priceLocale: Locale? = nil, completion: @escaping JSONCompletion) {
        guard let profileId = shared.profile?.profileId else {
            completion(nil, NetworkResponse.missingRequiredParams)
            return
        }
        
        var attributes = Parameters()
        
        attributes["profile_id"] = profileId
        attributes["receipt_encoded"] = receiptEncoded
        if let variationId = variationId { attributes["variation_id"] = variationId }
        if let originalPrice = originalPrice { attributes["original_price"] = originalPrice.stringValue }
        if let discountPrice = discountPrice { attributes["discount_price"] = discountPrice.stringValue }
        if let priceLocale = priceLocale {
            attributes["price_locale"] = priceLocale.currencyCode
            attributes["store_country"] = priceLocale.regionCode
        }
        
        let params = Parameters.formatData(with: "", type: Constants.TypeNames.appleReceipt, attributes: attributes)
        
        shared.apiManager.validateReceipt(params: params, completion: completion)
    }
    
    @objc public static var apnsToken: Data? {
        didSet {
            shared.apnsTokenString = apnsToken?.map { String(format: "%02.2hhx", $0) }.joined()
        }
    }
    
    private var apnsTokenString: String? {
        didSet {
            syncInstallation()
        }
    }
    
    @objc public class var customerUserId: String? {
        return shared.profile?.customerUserId
    }
    
    private func syncTransactionsHistory() {
        guard let receipt = iapManager.latestReceipt else {
            return
        }
        
        Self.validateReceipt(receipt) { _,_  in
#warning("sync eligibility criteria for user")
        }
    }
    
    @objc public class func getPurchaserInfo(_ completion: @escaping PurchaserInfoCompletion) {
        guard let profileId = shared.profile?.profileId else {
            completion(nil, NetworkResponse.missingRequiredParams)
            return
        }
        
        shared.apiManager.getPurchaserInfo(id: profileId, completion: completion)
    }
    
    @objc public class func logout() {
        shared.sessionsManager.invalidateLiveTrackerTimer()
        shared.profile = nil
        shared.installation = nil
        DefaultsManager.shared.clean()
        
        // automatically create new profile
        shared.createProfile()
    }
    
}

extension Adapty: AppDelegateSwizzlerDelegate {
    
    func didReceiveAPNSToken(_ deviceToken: Data) {
        Self.apnsToken = deviceToken
    }
    
}
