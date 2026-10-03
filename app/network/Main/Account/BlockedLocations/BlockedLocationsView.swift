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
                
                if viewModel.blockedLocations.isEmpty && viewModel.loadFailed {
                    VStack(spacing: 12) {
                        Text("Blocked locations could not be loaded.")
                            .font(themeManager.currentTheme.bodyFont)
                            .foregroundStyle(themeManager.currentTheme.textMutedColor)

                        Button("Retry") {
                            Task { await viewModel.fetchBlockedLocations() }
                        }
                        .disabled(viewModel.isLoading)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.blockedLocations.isEmpty {
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
                                )
                                
                                Spacer().frame(width: 16)
                                
                                Text("\(location.locationName)")
                                Spacer()
                            }
                            .listRowBackground(themeManager.currentTheme.backgroundColor)
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
                    .scrollContentBackground(.hidden)
                    .background(themeManager.currentTheme.backgroundColor)
                    
                }
                    
            }
                
        }
        .safeAreaInset(edge: .bottom) {
            // a failed add or remove reverts the row; say why instead of
            // letting it silently reappear (or vanish)
            if let processingErrorMsg = viewModel.processingErrorMsg {
                Text(processingErrorMsg)
                    .font(themeManager.currentTheme.bodyFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                    .multilineTextAlignment(.center)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(themeManager.currentTheme.tintedBackgroundBase)
                    .cornerRadius(8)
                    .padding()
            }
        }
        .toolbar {
            
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

            // country search (parity with the iOS .searchable field)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(themeManager.currentTheme.textMutedColor)
                TextField("Search countries", text: $viewModel.searchCountry)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(themeManager.currentTheme.tintedBackgroundBase)
            .cornerRadius(8)
            .padding(.horizontal)

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
            .environmentObject(themeManager)
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
                .environmentObject(themeManager)
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
