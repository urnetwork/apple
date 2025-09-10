//
//  URNodeCarousel.swift
//  URnetwork
//
//  Created by Stuart Kuentzel on 9/10/25.
//

import SwiftUI

struct URNodeCarousel: View {
    
    @EnvironmentObject var themeManager: ThemeManager

    private let imgs = ["URnode1", "URnode2", "URnode3"]
    private let cornerRadius: CGFloat = 24

    var body: some View {
        VStack {
            Spacer().frame(height: 24)
            
            HStack {
                Text("URnode")
                    .font(themeManager.currentTheme.titleCondensedFont)
                    .foregroundColor(themeManager.currentTheme.textColor)
                Spacer()
            }
            .padding(.horizontal)
            
            Spacer().frame(height: 12)
            
            Group {
                if #available(iOS 17, macOS 14, *) {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(imgs, id: \.self) { img in

                                    Image(img)
                                        .resizable()
                                        .scaledToFill()
                                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                        .padding(.horizontal)
                                        .containerRelativeFrame(.horizontal)

                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollIndicators(.hidden)
                    .scrollTargetBehavior(.paging)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(imgs, id: \.self) { img in
                                Image(img)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(height: 200)
                                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
                                    // .frame(width: UIScreen.main.bounds.width) // approximate full-width fallback
                            }
                        }
                    }
                }
            }
            
            Spacer().frame(height: 24)
            
            HStack {
                UrButton(
                    text: "Preorder Now",
                    action: {
                        if let url = URL(string: "https://ur.io/urnode") {
                            #if canImport(UIKit)
                            UIApplication.shared.open(url, options: [:], completionHandler: nil)
                            #endif
                            #if canImport(AppKit)
                            NSWorkspace.shared.open(url)
                            #endif
                        }
                    }
                )
            }
            .padding(.horizontal)
        }
    }
}

#Preview {
    URNodeCarousel()
}
