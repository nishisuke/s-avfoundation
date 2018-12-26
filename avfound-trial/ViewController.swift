//
//  ViewController.swift
//  avfound-trial
//
//  Created by nishisuke on 2018/12/14.
//  Copyright © 2018年 nishisuke. All rights reserved.
//

import UIKit
import AVFoundation
import SnapKit
import Photos

class ViewController: UIViewController, AVCaptureFileOutputRecordingDelegate {
    let previewView = PreviewView()
    let captureSession = AVCaptureSession()
    let sessionQueue = DispatchQueue(label: "session queue")
    var movieFileOutput: AVCaptureMovieFileOutput?
    var backgroundRecordingID: UIBackgroundTaskIdentifier?
    let recordButton = UIButton()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // Do any additional setup after loading the view, typically from a nib.
        
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: // The user has previously granted access to the camera.
            self.setupCaptureSession()
        case .notDetermined: // The user has not yet been asked for camera access.
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    self.setupCaptureSession()
                }
            }
        case .denied: // The user has previously denied access.
            return
        case .restricted: // The user can't grant access due to restrictions.
            return
        }
        
        previewView.session = captureSession
        view.addSubview(previewView)
        previewView.snp.makeConstraints { (make) -> Void in
            make.width.height.equalTo(400)
            make.center.equalTo(self.view)
        }
        
        recordButton.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        recordButton.backgroundColor = .red
        previewView.addSubview(recordButton)
        recordButton.snp.makeConstraints { make in
            make.width.height.equalTo(60)
            make.bottom.equalTo(previewView)
        }
        captureSession.startRunning()
    }
    
    func setupCaptureSession() {
        let videoDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
        let audioDevice = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified)
        
        captureSession.beginConfiguration()
        guard
            let videoDeviceInput = try? AVCaptureDeviceInput(device: videoDevice!),
            captureSession.canAddInput(videoDeviceInput)
            else { return }
        guard
            let audioDeviceInput = try? AVCaptureDeviceInput(device: audioDevice!),
            captureSession.canAddInput(audioDeviceInput)
            else { return }
        
        captureSession.addInput(videoDeviceInput)
        captureSession.addInput(audioDeviceInput)
        
        let movieFileOutput = AVCaptureMovieFileOutput()
        guard captureSession.canAddOutput(movieFileOutput) else { return }
        captureSession.sessionPreset = .medium
        captureSession.addOutput(movieFileOutput)
        self.movieFileOutput = movieFileOutput
        captureSession.commitConfiguration()
    }
    
    @objc func toggle() {
        guard let movieFileOutput = self.movieFileOutput else {
            return
        }
        let videoPreviewLayerOrientation = previewView.videoPreviewLayer.connection?.videoOrientation
        
        sessionQueue.async {
            if !movieFileOutput.isRecording {
                if UIDevice.current.isMultitaskingSupported {
                    self.backgroundRecordingID = UIApplication.shared.beginBackgroundTask(expirationHandler: nil)
                }
                
                // Update the orientation on the movie file output video connection before recording.
                let movieFileOutputConnection = movieFileOutput.connection(with: .video)
                movieFileOutputConnection?.videoOrientation = videoPreviewLayerOrientation!
                
                let availableVideoCodecTypes = movieFileOutput.availableVideoCodecTypes
                
                if availableVideoCodecTypes.contains(.hevc) {
                    movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: movieFileOutputConnection!)
                }
                
                let outputFileName = NSUUID().uuidString
                let outputFilePath = (NSTemporaryDirectory() as NSString).appendingPathComponent((outputFileName as NSString).appendingPathExtension("mov")!)
                movieFileOutput.startRecording(to: URL(fileURLWithPath: outputFilePath), recordingDelegate: self)
            } else {
                movieFileOutput.stopRecording()
            }
        }
    }
    
    /// - Tag: DidStartRecording
    //  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    //        DispatchQueue.main.async {
    //          self.recordButton.isEnabled = true
    //    }
    //}
    
    /// - Tag: DidFinishRecording
    func fileOutput(_ output: AVCaptureFileOutput,
                    didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection],
                    error: Error?) {
        func cleanup() {
            let path = outputFileURL.path
            if FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    print("Could not remove file at url: \(outputFileURL)")
                }
            }
            
            if let currentBackgroundRecordingID = backgroundRecordingID {
                backgroundRecordingID = UIBackgroundTaskIdentifier.invalid
                
                if currentBackgroundRecordingID != UIBackgroundTaskIdentifier.invalid {
                    UIApplication.shared.endBackgroundTask(currentBackgroundRecordingID)
                }
            }
        }
        
        
        if error != nil {
            print("Movie file finishing error: \(String(describing: error))")
            let success = (((error! as NSError).userInfo[AVErrorRecordingSuccessfullyFinishedKey] as AnyObject).boolValue)!
            if !success {
                cleanup()
                return
            }
        }
        
        let ava = AVAsset(url: outputFileURL)
        let avmc = AVMutableComposition(urlAssetInitializationOptions: nil)
        let r = CMTimeRangeMake(start: CMTimeMake(value: 0, timescale: 1), duration: ava.duration)
        do {
            try avmc.insertTimeRange(r, of: ava, at: CMTimeMake(value: 0, timescale: 1))
            avmc.scaleTimeRange(r, toDuration: CMTimeMultiplyByRatio(ava.duration, multiplier: 1, divisor: 2))
        } catch {
            print("hoge")
        }
        
        guard let exporter = AVAssetExportSession(asset: avmc, presetName: AVAssetExportPresetHighestQuality) else {
            fatalError()
        }
        let outputPath = (String(Int(Date().timeIntervalSince1970)) as NSString).appendingPathExtension("mov")
        exporter.outputURL = URL(fileURLWithPath: (NSTemporaryDirectory() as NSString).appendingPathComponent(outputPath!))
        
        let filter = CIFilter(name: "CIGaussianBlur")!
        let ivf = CIFilter(name: "CIColorInvert")!
        let composition = AVVideoComposition(asset: avmc, applyingCIFiltersWithHandler: { request in
            // Clamp to avoid blurring transparent pixels at the image edges
            let source = request.sourceImage.clampedToExtent()
            filter.setValue(source, forKey: kCIInputImageKey)
            
            // Vary filter parameters based on video timing
            let seconds = CMTimeGetSeconds(request.compositionTime)
            filter.setValue(seconds * 10.0, forKey: kCIInputRadiusKey)
            
            // Crop the blurred output to the bounds of the original image
            let output = filter.outputImage!.cropped(to: request.sourceImage.extent)
            ivf.setValue(output, forKey: kCIInputImageKey)
            let hoge = ivf.outputImage!.cropped(to: request.sourceImage.extent)
            
            // Provide the filter output to the composition
            request.finish(with: hoge, context: nil)
        })
        exporter.videoComposition = composition
        exporter.outputFileType = .mov
        // exporter.videoComposition = composition
        exporter.exportAsynchronously {
            if exporter.status != .completed {
                print(exporter.status.rawValue)
                return
            }
            
            // 再生
            let player = AVPlayer(url: exporter.outputURL!)
            
            NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                player.seek(to: CMTime.zero)
                player.play()
            }
            let playerLayer = AVPlayerLayer(player: player)
            playerLayer.frame = self.view.bounds
            self.view.layer.addSublayer(playerLayer)
            player.play()
            
            // Check authorization status.
            PHPhotoLibrary.requestAuthorization { status in
                if status != .authorized {
                    cleanup()
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    let options = PHAssetResourceCreationOptions()
                    options.shouldMoveFile = true
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    creationRequest.addResource(with: .video, fileURL: exporter.outputURL!, options: options)
                }, completionHandler: { success, error in
                    if !success {
                        print("AVCam couldn't save the movie to your photo library: \(String(describing: error))")
                    }
                    cleanup()
                })
            }
        }
    }
}
