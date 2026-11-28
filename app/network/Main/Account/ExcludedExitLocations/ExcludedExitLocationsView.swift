//
//  ExcludedExitLocationsView.swift
//  URnetwork
//
//  Settings › Excluded exit locations: the countries, regions (such as US
//  states) and cities the connection's picks avoid, which the sdk keeps in the
//  network space's local state (exit_location_preferences.go).
//

import SwiftUI
import URnetworkSdk

/**
 * Modeled on Blocked locations (BlockedLocationsView, AddBlockedLocationSheet),
 * on one screen: what the list does, the excluded places with Remove or the
 * empty state, and a search that finds places as the location list does (a
 * ProviderListStore of its own, over the sdk's filter), with Exclude on each
 * country, region or city it finds that is not excluded yet. The list and its
 * changes are the connect view model's, which applies a change to a
 * connection it affects at once (ConnectViewModel.changeExcludedExitLocations).
 */
struct ExcludedExitLocationsView: View {

    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var connectViewModel: ConnectViewModel

    // the location list's search, with its debounce and the sdk's filter, and
    // a query of its own, not the connect screen's
    @StateObject private var searchStore: ProviderListStore

    init(api: UrApiServiceProtocol) {
        _searchStore = StateObject(wrappedValue: ProviderListStore(urApiService: api))
    }

    var body: some View {

        List {

            Text("Connections won't use exits in these places, unless you pick one of them directly.")
                .font(themeManager.currentTheme.secondaryBodyFont)
                .foregroundColor(themeManager.currentTheme.textMutedColor)
                .fixedSize(horizontal: false, vertical: true)
                .listRowBackground(themeManager.currentTheme.backgroundColor)

            Section {

                if connectViewModel.excludedExitLocations.isEmpty {
                    Text("No excluded locations yet. Search for a country, region or city to exclude it.")
                        .font(themeManager.currentTheme.bodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowBackground(themeManager.currentTheme.backgroundColor)
                } else {
                    ForEach(connectViewModel.excludedExitLocations, id: \.connectLocationId) { location in
                        locationRow(location) {
                            Button(role: .destructive) {
                                connectViewModel.removeExcludedExitLocation(location)
                            } label: {
                                Text("Remove")
                            }
                            // only the button, not the whole row, removes
                            .buttonStyle(.borderless)
                        }
                    }
                }

            }

            Section {

                searchField
                    .listRowBackground(themeManager.currentTheme.backgroundColor)

                if searchStore.providersLoading && searchResults.isEmpty && !searchQuery.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(themeManager.currentTheme.backgroundColor)
                }

                ForEach(searchResults, id: \.connectLocationId) { location in
                    locationRow(location) {
                        if !connectViewModel.isExcludedExitLocation(location) {
                            Button {
                                connectViewModel.addExcludedExitLocation(location)
                            } label: {
                                Text("Exclude")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

            }

        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(themeManager.currentTheme.backgroundColor)
        .onAppear {
            // the list as the local state keeps it now
            connectViewModel.loadExitLocationPreferences()
        }
    }

    /// The query as the store searches it.
    private var searchQuery: String {
        searchStore.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The countries, regions and cities the search found: its best matches
    /// first, as the location list shows them (an exact match is only among
    /// them), then the rest. Collections and devices cannot be excluded and
    /// are left out (SdkCanExcludeExitLocation). None before a query.
    private var searchResults: [SdkConnectLocation] {
        if searchQuery.isEmpty {
            return []
        }
        return [
            searchStore.providerBestSearchMatches,
            searchStore.providerCountries,
            searchStore.providerRegions,
            searchStore.providerCities,
        ].joined().filter { SdkCanExcludeExitLocation($0) }
    }

    /// The search, in the style of Blocked locations' macOS search.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(themeManager.currentTheme.textMutedColor)
            TextField("Search countries, regions and cities", text: $searchStore.searchQuery)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
        }
        .padding(8)
        .background(themeManager.currentTheme.tintedBackgroundBase)
        .cornerRadius(8)
    }

    /// A place in the style of Blocked locations' rows: its color and name,
    /// where it lies when it is a region or city, and `action` at the end.
    private func locationRow<Action: View>(
        _ location: SdkConnectLocation,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack {

            ProviderColorCircle(
                color: getProviderColor(location)
            )

            Spacer().frame(width: 16)

            VStack(alignment: .leading) {
                Text(verbatim: locationDisplayName(location))
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)

                let container = containerName(location)
                if !container.isEmpty {
                    Text(verbatim: container)
                        .font(themeManager.currentTheme.secondaryBodyFont)
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
            }

            Spacer()

            action()
        }
        .listRowBackground(themeManager.currentTheme.backgroundColor)
    }

    /// Where a region or city lies, which tells places of one name apart
    /// (Georgia the country and the US state): a city's region and country, a
    /// region's country, the country named as the location list names it
    /// (locationDisplayName). Empty for a country.
    private func containerName(_ location: SdkConnectLocation) -> String {
        if location.locationType == SdkLocationTypeCountry {
            return ""
        }
        var names: [String] = []
        if location.locationType == SdkLocationTypeCity && !location.region.isEmpty {
            names.append(location.region)
        }
        let countryName = locationDisplayName(
            isCountry: true,
            countryCode: location.countryCode,
            serverName: location.country
        )
        if !countryName.isEmpty {
            names.append(countryName)
        }
        return names.joined(separator: ", ")
    }
}
