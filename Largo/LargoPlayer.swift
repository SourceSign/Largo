//
//  LargoPlayer.swift
//  Largo
//
//  Created by Lars on 12.09.24.
//

import SwiftUI 


class LargoPlayer: ObservableObject {
    
    @Published private var model = CustomPlayer()
    
    
    // MARK: - Intents

    func play() {
        model.play()
    }
    
    func setUrl(url: URL) {
        model.audioFileURL = url
    }

}
