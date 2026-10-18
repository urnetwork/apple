//
//  SelectedProviderCount.swift
//  URnetwork
//

import Foundation

/// The provider count to show for the selected location on the connect screen.
///
/// The selected location is a copy taken when it was chosen, so its count is
/// as old as the selection. Whenever the provider list has been fetched since,
/// its entry for the same location id has the current count, so that one is
/// shown; the selection's own count is the fallback.
///
/// `fetched` holds the fetched locations as (location id, provider count).
func selectedProviderCount<S: Sequence>(
    selectedId: String?,
    selectedCount: Int,
    fetched: S
) -> Int where S.Element == (String, Int) {
    guard let selectedId else {
        return selectedCount
    }
    return fetched.first(where: { $0.0 == selectedId })?.1 ?? selectedCount
}
