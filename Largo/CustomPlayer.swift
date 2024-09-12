//
//  CustomPlayer.swift
//  Largo
//
//  Created by Lars on 12.09.24.
//

import Foundation
import AVFoundation

struct CustomPlayer {
    
    let engine = AVAudioEngine()
    let player = AVAudioPlayerNode()
    
    var pitchControl = AVAudioUnitTimePitch()
    var speedControl = AVAudioUnitVarispeed()
    var audioFormat: AVAudioFormat?
    var audioSampleRate: Float = 0
    var audioLengthSeconds: Float = 0
    var audioLengthSamples: AVAudioFramePosition = 0
    var needsFileScheduled = true
    var seekFrame: AVAudioFramePosition = 0
    var audioLengthMinutes : String = ""
    
    init() {
          setupAudio()
      }
    
    mutating func scheduleAudioFile() {
        
        guard let audioFile = audioFile else { return }
        
        seekFrame = 0
        player.scheduleFile(audioFile, at: nil)
        needsFileScheduled = true
        /*player.scheduleFile(audioFile, at: nil) {
            needsFileScheduled = true
        }*/
    }
    
    var audioFile: AVAudioFile? {
          didSet {
            if let audioFile = audioFile {
              audioLengthSamples = audioFile.length
              audioFormat = audioFile.processingFormat
              audioSampleRate = Float(audioFormat?.sampleRate ?? 44100)
              audioLengthSeconds = Float(audioLengthSamples) / audioSampleRate
            }
          }
        }
        
        var audioFileURL: URL? {
          didSet {
            if let audioFileURL = audioFileURL {
                
                // Start accessing a security-scoped resource.
                guard audioFileURL.startAccessingSecurityScopedResource() else {
                    // Handle the failure here.
                    return
                }
                
                // Make sure you release the security-scoped resource when you are done.
                defer { audioFileURL.stopAccessingSecurityScopedResource() }

                // Use file coordination for reading and writing any of the URL’s content.
                var error: NSError? = nil
                NSFileCoordinator().coordinate(readingItemAt: audioFileURL, error: &error) { (audioFileURL) in
                    
                    let keys : [URLResourceKey] = [.nameKey, .isDirectoryKey]
                    
                    //Get an enumerator for the directory's content.
                    guard let fileList =
                        FileManager.default.enumerator(at: audioFileURL, includingPropertiesForKeys: keys) else {
                            print("*** Unable to access the contents of \(audioFileURL.path) ***\n")
                            return
                    }
                    
                    audioFile =  try? AVAudioFile(forReading: audioFileURL)
    //ToDo Check This!
    //                for case let file as URL in fileList {
    //                    // Also start accessing the content's security-scoped URL.
    //                    guard audioFileURL.startAccessingSecurityScopedResource() else {
    //                        print("ErrorHandler :-)")
    //                        continue
    //                    }
    //
    //                    // Make sure you release the security-scoped resource when you are done.
    //                    defer { audioFileURL.stopAccessingSecurityScopedResource() }
    //
    //                    audioFile =  try? AVAudioFile(forReading: file)
    //
    //                }
                }
            }
          }
        }
    
    mutating func setupAudio() {
         // 1
         //audioFileURL = Bundle.main.url(forResource: "track_139_mix", withExtension: "mp3")
         // 2
         engine.attach(player)
         engine.attach(pitchControl)
         engine.attach(speedControl)
         engine.connect(player, to: speedControl, format: audioFormat)
         engine.connect(speedControl, to: pitchControl, format: audioFormat)
         engine.connect(pitchControl, to: engine.mainMixerNode, format: audioFormat)
         engine.prepare()

         do {
           // 3
           try engine.start()
         } catch let error {
           print(error.localizedDescription)
         }
     }
    
    //Mark - intent(s)
      
    mutating func play() {
          if player.isPlaying {
            player.pause()
          } else {
              if self.needsFileScheduled {
                  self.needsFileScheduled = false
              scheduleAudioFile()
            }
            player.play()
          }
      }
      
      func setRateWithPich(value : Float) {
          self.speedControl.rate = value
          self.pitchControl.pitch = -1200 * logC(val: value, forBase: 10.0) / logC(val: 2.0, forBase: 10.0)
      }
      
      func getTitlefromfile() -> String {
          let url = Bundle.main.url(forResource: "track_139_mix", withExtension: "mp3")!
          let asset = AVAsset(url: url)
          var title = ""
          
          for metaDataItem in asset.metadata {
              if metaDataItem.commonKey?.rawValue == "title" {
                  title = metaDataItem.value as? String ?? "Unknown Title"
              }
          }
          return title
      }
    
    
      
      func getArtistfromfile() -> String {
          let url = Bundle.main.url(forResource: "track_139_mix", withExtension: "mp3")!
          let asset = AVAsset(url: url)
          var artist = ""
          
          for metaDataItem in asset.metadata {
              if metaDataItem.commonKey?.rawValue == "artist" {
                  artist = metaDataItem.value as? String ?? "Unknown Artist"
              }
          }
          return artist
      }
    

      
      //Mark - helper functions
      
      func logC(val: Float, forBase base: Float) -> Float {
          return log(val)/log(base)
      }
}

