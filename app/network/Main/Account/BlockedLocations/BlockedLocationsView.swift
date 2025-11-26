//
//  BlockedLocationsView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/29/25.
//

import SwiftUI
import URnetworkSdk

struct BlockedLocationsView: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    
    init(
        api: UrApiServiceProtocol,
        countries: [SdkConnectLocation]
    ) {
        _viewModel = .init(
            wrappedValue: .init(
                api: api,
                countries: countries
            )
        )
    }
    
    var body: some View {
        
        Group {
            
            if (viewModel.isInitializing) {
                VStack {
                    
                    Spacer()
                    
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                    
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                
                if viewModel.blockedLocations.isEmpty {
                    VStack {
                        Text("No blocked locations")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    
                    List {
                        
                        ForEach(viewModel.blockedLocations, id: \.locationId) { location in
                            HStack {
                                
                                ProviderColorCircle(
                                    color: getProviderColor(
                                        locationType: location.locationType,
                                        countryCode: location.countryCode,
                                        id: location.locationId?.idStr
                                    ),
                                    isStrongPrivacy: false // todo - fix this
                                )
                                
                                Spacer().frame(width: 16)
                                
                                Text("\(location.locationName)")
                                Spacer()
                            }
                            .swipeActions(edge: .trailing) {
                                
                                Button(role: .destructive) {
                                    if let locationId = location.locationId {
                                        viewModel.removeFromList(locationId)
                                    } else {
                                        print("location id not found!")
                                    }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                
                            }
                        
                        }
                        
                    }
                    .listStyle(.inset)
                    
                }
                    
            }
                
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Blocked Locations")
                    .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: {
                    viewModel.displayProviderSheet = true
                }) {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await viewModel.fetchBlockedLocations()
        }
        .sheet(isPresented: $viewModel.displayProviderSheet) {
            
            #if os(macOS)
            
            HStack {
                Spacer()
                
                Text("Select country to block")
                    .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                
                Spacer()
                Button(action: {
                    viewModel.displayProviderSheet = false
                }) {
                    Image(systemName: "xmark")
                        .foregroundColor(themeManager.currentTheme.textMutedColor)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Spacer().frame(height: 8)
            
            AddBlockedLocationSheet(
                providerCountries: viewModel.availableCountries,
                onSelect: { provider in
                    print("\(provider.name) selected")
                    viewModel.displayProviderSheet = false
                    viewModel.blockLocation(
                        locationId: provider.connectLocationId?.locationId,
                        locationName: provider.name,
                        countryCode: provider.countryCode
                    )
                    viewModel.searchCountry = ""
                }
            )
            .frame(minHeight: 400)
            
            #else
            
            NavigationStack {
                
                AddBlockedLocationSheet(
                    providerCountries: viewModel.availableCountries,
                    onSelect: { provider in
                        print("\(provider.name) selected")
                        viewModel.displayProviderSheet = false
                        viewModel.blockLocation(
                            locationId: provider.connectLocationId?.locationId,
                            locationName: provider.name,
                            countryCode: provider.countryCode
                        )
                        viewModel.searchCountry = ""
                    }
                )
                .navigationBarTitleDisplayMode(.inline)
                
                .searchable(text: $viewModel.searchCountry)
                .toolbar {
                    
                    ToolbarItem(placement: .principal) {
                        Text("Select country to block")
                            .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
                    }
                    
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: {
                            viewModel.displayProviderSheet = false
                        }) {
                            Image(systemName: "xmark")
                        }
                    }
                    
                }
            }
            
            #endif
            
        }
    }
}

//#Preview {
//    BlockedLocationsView()
//}
