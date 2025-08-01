//
//  BlockedLocationsView.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 7/29/25.
//

import SwiftUI

struct BlockedLocationsView: View {
    
    @StateObject private var viewModel: ViewModel
    @EnvironmentObject var themeManager: ThemeManager
    
    init(api: UrApiServiceProtocol) {
        _viewModel = .init(wrappedValue: .init(api: api))
    }
    
    var body: some View {
    
        List {
            
            if (viewModel.isInitializing) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            } else {
                
                if viewModel.blockedLocations.isEmpty {
                    VStack {
                        Text("No Blocked Locations")
                            .font(themeManager.currentTheme.secondaryTitleFont)
                    }
                } else {
                 
                    ForEach(viewModel.blockedLocations, id: \.locationId) { location in
                        HStack {
                            Text("\(location.locationName)")
                            Spacer()
                        }
                        .swipeActions(edge: .trailing) {
                            
                            Button(role: .destructive) {
                                if let locationId = location.locationId {
    //                                Task {
    //                                    await viewModel.unblockLocation(locationId)
    //                                }
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

            }
            
        }
        .listStyle(.inset)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Blocked Locations")
                    .font(themeManager.currentTheme.toolbarTitleFont).fontWeight(.bold)
            }
            
            ToolbarItem(placement: .primaryAction) {
                Button(action: {}) {
                    Image(systemName: "plus")
                }
            }
        }
        .refreshable {
            await viewModel.fetchBlockedLocations()
        }
    }
}

//#Preview {
//    BlockedLocationsView()
//}
