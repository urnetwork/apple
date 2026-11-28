//
//  ProviderUtils.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 2024/12/12.
//

import Foundation
import URnetworkSdk
import SwiftUI

func getProviderColor(_ provider: SdkConnectLocation) -> Color {
    return Color(hex: SdkGetColorHex(
        provider.locationType == SdkLocationTypeCountry ? provider.countryCode : provider.connectLocationId?.string()
    ))
}

func getProviderColor(locationType: String, countryCode: String, id: String?) -> Color {
    return Color(hex: SdkGetColorHex(
        locationType == SdkLocationTypeCountry ? countryCode : id
    ))
}

/// The name the location list (and the connect screen's selected location)
/// shows. A country reads in the app's language: the platform's name for its
/// code, the lookup the connection region screens use (connectionRegionName),
/// so both name a country alike. The server's English name stays the fallback,
/// for a code the platform does not name and for every region, city, group and
/// device, which the platform cannot name.
func locationDisplayName(_ location: SdkConnectLocation, locale: Locale = .current) -> String {
    locationDisplayName(
        isCountry: location.locationType == SdkLocationTypeCountry,
        countryCode: location.countryCode,
        serverName: location.name,
        locale: locale
    )
}

/// Pure, for tests.
func locationDisplayName(isCountry: Bool, countryCode: String, serverName: String, locale: Locale = .current) -> String {
    let code = countryCode.uppercased()
    guard isCountry, code.count == 2,
          let name = locale.localizedString(forRegionCode: code),
          !name.isEmpty, name.uppercased() != code else {
        return serverName
    }
    return name
}
