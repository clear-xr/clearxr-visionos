# ClearXR

A visionOS client for streaming immersive worlds, games, and applications from a PC to Apple Vision Pro.

## For End Users 

Download the [latest server release](https://github.com/clear-xr/clearxr-server/releases) for your Windows 10/11 PC

Download the client from Test Flight

[![Clear XR](https://i.imgur.com/DHhfmmK.png)](https://testflight.apple.com/join/ed6778fF)

discord server: https://discord.gg/AzZZXvBR8p

## Requirements

- visionOS 26.4+ 
- Apple Vision Pro M2 or M5
- Windows 10/11 PC with NVIDIA Ada or Blackwell GPU (40xx, 50xx, RTX 5000/6000, L40, L40S), running the Clear XR Server 

## For Developers & Hackers


ClearXR connects your Apple Vision Pro to a PC running an OpenXR application, letting you interact with PC-rendered VR content directly on the headset. The streaming transport uses Apple's Foveated Streaming framework, powered by NVIDIA CloudXR on the server side.

The app is designed to be paired with a companion test Clear XR Server and API overlay on the PC, which together add session robustness and PSVR2 Sense controller support -- including capacitive touch events and haptic feedback -- to the streaming pipeline.

## Features

- **Session management** -- Connect to a streaming endpoint via automatic network discovery or manual IP/port entry. Pause, resume, and disconnect sessions from the headset.
- **PSVR2 Sense controller input** -- Reads spatial controller state (buttons, triggers, grips, thumbsticks, capacitive touch) that may be missed by NVIDIA Cloud XR 
- **Haptic feedback** -- Receives haptic event packets from the OpenXR app and plays them on the correct controller hand via CoreHaptics.
- **Configuration** -- Adjust resolution and other configuration settings on the Clear XR server from within the headset

## Layout

```
ClearXR/                   visionOS app target
  ClearXRApp.swift           App entry point, session and immersive space setup
  Views/                     SwiftUI views (connection, controls, settings)
  Models/                    Session actions, message channels, controller I/O
  ViewModifiers/             Immersive presentation and window state tracking

ClearXRSimulator/          Framework target
  ClearXRSimulator.swift     Simulator stub for FoveatedStreamingSession types
```

On device, the app imports Apple's `FoveatedStreaming` framework. The `ClearXRSimulator` framework provides matching type stubs so the project builds and previews in the Xcode simulator.



## Getting Started

1. Open `ClearXR.xcodeproj` in Xcode.
2. Select the **ClearXR** scheme and your Apple Vision Pro as the run destination.
3. Build and run.
4. On launch, choose **Automatic** to discover a streaming endpoint on your local network, or switch to **Local IP** and enter the server address and port.
5. Once connected, use the floating controls to pause, resume, or disconnect the session. Tap the gear icon to open developer settings.
6. Use your PC directly to launch OpenXR apps or a remote desktop software such as Windows App or Moonlight XROS + Apollo.   **Note that Apollo needs to run on custom ports as it uses the same NVIDIA GameStream protocol as this software**

## Tips & Tricks
- For OpenVR games such as Aircar, Vertigo, Half Life Alyx, VRchat, etc. you can try to install and run OpenComposite.   A better solution may come eventually.

## Wishful thinking Roadmap
1. Supporting Steam VR / Open VR games through some kind of clever janky hacks that are, with luck, less janky than OpenComposite.  
1. Linux server support
1. Better telemetry on FPS, latency, jitter, etc.
1. Supporting NVIDIA Cloud XR directly (only fixed foveated rendering) to provide more telemetry & tuning for experimentation

## License

See [LICENSE.txt](LICENSE.txt) for this project's licensing information.
