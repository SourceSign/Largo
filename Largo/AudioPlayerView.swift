//
//  ContentView.swift
//  Largo
//
//  Created by Lars on 11.09.24.
//

import SwiftUI


struct ContentView: View {
    
    @ObservedObject var viewModel: LargoPlayer = LargoPlayer()
    
    @State var playerPaused = true

    @State var isShowing = false
    
    var body: some View {
        VStack {
            openFileButton
            playButton
        }
    }
    
    
    var openFileButton: some View {
        Button(action: {
            isShowing.toggle()
        }) {
            HStack {
                Image(systemName: "folder")
                    .font(.title)
            }
            .padding()
            .foregroundColor(.gray)
        }.fileImporter(isPresented: $isShowing, allowedContentTypes: [.mp3], allowsMultipleSelection: false, onCompletion: { results in
            switch results {
            case .success(let fileurls):
                //print(fileurls.count)
                
                for fileurl in fileurls {
                    print(fileurl.path)
                }
                viewModel.setUrl(url: fileurls.first!)
            case .failure(let error):
                print(error)
            }
            
        })
    }
    
    var playButton: some View {
        VStack {
            Button(action: {
                viewModel.play()
                playerPaused.toggle()
            }) {
                HStack {
                    Image(systemName: playerPaused ? "play.fill" : "pause.fill").frame(width: 1.0, height: 1.0).font(.title)
                }
                .padding()
                .foregroundColor(.black)
            }
        }

    }
}

#Preview {
    ContentView()
}
