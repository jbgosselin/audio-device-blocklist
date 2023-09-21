//
//  AudioContext.swift
//  Audio Device Blocker
//
//  Created by Jean-Baptiste Gosselin on 2023-09-18.
//

import SwiftUI
import CoreAudio
import UserNotifications

final class AudioContext: NSObject, NSApplicationDelegate, ObservableObject {
    @AppStorage(StorageKey.outputBlocklist.rawValue) private var outputBlocklist = [SavedAudioDevice]()
    @AppStorage(StorageKey.inputBlocklist.rawValue) private var inputBlocklist = [SavedAudioDevice]()
    @AppStorage(StorageKey.outputFallbacks.rawValue) private var outputFallbacks = [SavedAudioDevice]()
    @AppStorage(StorageKey.inputFallbacks.rawValue) private var inputFallbacks = [SavedAudioDevice]()

    @Published var availableDevices: [AudioDevice] = []
    
    private var mainOutputDevice: AudioDevice?
    private var mainInputDevice: AudioDevice?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        self.registerAudioCallbacks()
        self.fetchAvailableDevices()
        self.fetchMainDevice(.output)
        self.fetchMainDevice(.input)
        
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { success, error in
            if let error = error {
                print(error.localizedDescription)
                return
            }
            print("Notification authorized \(success)")
        }
    }
    
    @objc func coreAudioCallback(_ notif: Notification) {
        guard let data = notif.object as? CoreAudioCallback else {
            debugPrint("Fails to retrieve notification data in \(notif)")
            return
        }

        for property in data.inAddresses {
            switch property.mSelector {
            case kAudioHardwarePropertyDefaultInputDevice:
                print("Main Audio Input Device changed")
                self.fetchMainDevice(.input)
            case kAudioHardwarePropertyDefaultOutputDevice:
                print("Main Audio Output Device changed")
                self.fetchMainDevice(.output)
            case kAudioHardwarePropertyDevices:
                print("Audio Device Changed")
                self.fetchAvailableDevices()
            default:
                print("Unknown selector \(property)")
            }
        }
    }

    private func registerAudioCallbacks() {
        NotificationCenter.default.addObserver(self, selector: #selector(coreAudioCallback), name: coreAudioPropertyListenerCallbackNotification, object: nil)

        let selectors = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
            kAudioHardwarePropertyDefaultInputDevice,
        ]
        
        for selector in selectors {
            let _ = registerCoreAudioCallback(selector)
        }
    }
    
    func fetchAvailableDevices() {
        self.availableDevices = listAudioDevices() ?? self.availableDevices
        dump(self.availableDevices)
    }
    
    private func setMainDevice(_ direction: AudioStreamDirection, _ device: AudioDevice) {
        switch direction {
        case .input:
            self.mainInputDevice = device
        case .output:
            self.mainOutputDevice = device
        }
    }
    
    func fetchMainDevice(_ direction: AudioStreamDirection) {
        guard let device = fetchSpecificDevice(mSelector: direction.kAudioHardwarePropertyDefaultDevice) else {
            print("Failed to retrieve default \(direction) device")
            return
        }
        
        print("New Default \(direction) Device")
        dump(device)
        
        let blocklist = switch direction {
        case .input:
            self.inputBlocklist
        case .output:
            self.outputBlocklist
        }
        
        // Check if device is blocklisted, otherwise nothing to do
        if !blocklist.hasDevice(device) {
            self.setMainDevice(direction, device)
            return
        }
        
        print("Reverting new \(direction) device because in blocklist")
        
        let previousDevice = switch direction {
        case .input:
            self.mainInputDevice
        case .output:
            self.mainOutputDevice
        }
        
        let availableDevices = self.availableDevices.withDirectionLazy(direction)
        
        // If we had a device before and it is available
        if let previousDevice = previousDevice, availableDevices.contains(previousDevice) {
            self.setMainDevice(direction, device)
            if setDefaultDevice(mSelector: direction.kAudioHardwarePropertyDefaultDevice, audioObjectID: previousDevice.id) {
                print("    successfully reverted previous \(direction) device")
                self.notifyUser(device)
                return
            } else {
                print("    error reverting to previous \(direction) device")
            }
        }
        
        self.setMainDevice(direction, device)
        
        // Otherwise, find the best fallback
        
        let fallbacks = switch direction {
        case .input:
            self.inputFallbacks
        case .output:
            self.outputFallbacks
        }
        
        let availableFallbacks = fallbacks.lazy.compactMap { f in
            availableDevices.first { a in a.deviceUID == f.deviceUID }
        }
        
        for dev in availableFallbacks {
            if setDefaultDevice(mSelector: direction.kAudioHardwarePropertyDefaultDevice, audioObjectID: dev.id) {
                print("    successfully reverted to fallback \(direction) device \(dev.deviceUID)")
                self.notifyUser(device)
                return
            } else {
                print("    error reverting to fallback \(direction) device ")
            }
        }
        
        print("Failed to revert \(direction) device")
    }
    
    func notifyUser(_ device: AudioDevice) {
        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = "Blocked device"
        notificationContent.subtitle = device.name
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: notificationContent, trigger: trigger)
        UNUserNotificationCenter.current().add(req)
    }
}
