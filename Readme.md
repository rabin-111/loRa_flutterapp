# LoraNet

A Flutter application for long-range wireless communication using ESP32 in remote place where there is no internet and satellite access.

## 📱 Overview

LoraNet is a cross-platform mobile application that connects to ESP32 devices via Bluetooth Low Energy (BLE) to enable long-range communication through LoRa (Long Range) networks. The app provides a seamless interface for messaging

## ✨ Features

### 🔵 Bluetooth Connectivity
- Automatic device scanning and discovery
- Easy pairing with ESP32-based LoRa devices
- Real-time connection status monitoring
- Supports Nordic UART Service (NUS) protocol

### 💬 Messaging
- Send and receive messages through LoRa network
- Real-time message delivery and display
- Message history with timestamps
- Clean, intuitive chat interface



## 🛠️ Technical Stack

- **Framework**: Flutter 3.x
- **Language**: Dart (SDK ^3.10.8)
- **BLE Communication**: flutter_blue_plus (v1.32.12)
- **Permissions**: permission_handler (v11.3.0)
- **Platform Support**: Android

## 📋 Prerequisites

- Flutter SDK 3.x or higher
- Dart SDK 3.10.8 or higher
- ESP32 device with LoRa module and BLE capabilities
- ESP32 firmware configured with Nordic UART Service UUIDs:
  - Service UUID: `6e400001-b5a3-f393-e0a9-e50e24dcca9e`
  - RX Characteristic: `6e400002-b5a3-f393-e0a9-e50e24dcca9e` (Phone → ESP32)
  - TX Characteristic: `6e400003-b5a3-f393-e0a9-e50e24dcca9e` (ESP32 → Phone)


### Platform-Specific Setup

#### Android
- Minimum SDK: API 21 (Android 5.0)
- Required permissions are automatically requested:
  - Bluetooth Scan
  - Bluetooth Connect
  - Location (required for BLE scanning)

#### iOS
- Add the following to `Info.plist`:
  - `NSBluetoothAlwaysUsageDescription`
  - `NSBluetoothPeripheralUsageDescription`
  - `NSLocationWhenInUseUsageDescription`

#### Windows/macOS/Linux
- BLE support varies by platform and may require additional system configuration

## 📱 Usage

### Connecting to ESP32

1. Launch the app
2. Tap the "Connect" button in the top-right corner
3. Wait for device scanning to complete
4. Select your ESP32 device from the list
5. Once connected, the status will change to "Connected"

### Sending Messages

1. Navigate to the "Messages" tab
2. Type your message in the input field at the bottom
3. Press the send button
4. Messages are transmitted via LoRa network to other connected devices

### Using GPT/AI Chat

1. Navigate to the "GPT" tab
2. Type your question in the input field
3. Press send
4. The ESP32 forwards your question to OpenAI API
5. Response is transmitted back via LoRa network
6. View conversation history in the chat interface

### Managing Email

1. Navigate to the "Mail" tab
2. Enter recipient email address
3. Add subject and body text
4. Send the email through the LoRa network
5. Received emails appear in the inbox section

## 🔧 Message Protocol

The app uses specific prefixes for different message types:

- `RITUMS` - Regular user messages
- `RITUGP` - GPT/AI questions
- `MAILRP` - Mail recipient
- `MAILSB` - Mail subject
- `MAILBD` - Mail body
- `MS` - Incoming LoRa messages
- `GPT_RESPONSE:` or `AAEND` - GPT responses
- `MAIL:` - Incoming mail

## 🎨 Design

The app features a modern, clean design with:
- Material Design 3 principles
- Light blue color scheme (#4FC3F7)
- Intuitive tab-based navigation
- Responsive UI for different screen sizes
- Smooth animations and transitions

## 📂 Project Structure

```
lib/
├── main.dart              # App entry point and UI
└── services/
    ├── ble_service.dart   # BLE communication handling
    └── gpt_service.dart 
```


**Note**: This app requires a compatible ESP32 device with LoRa module and appropriate firmware. The ESP32 acts as a bridge between the phone (via BLE) and the LoRa network.
