///
/// Filename: c:\projects\lora_net\lora_net_app\lib\services\ble_service.dart
/// Path: c:\projects\lora_net\lora_net_app\lib\services
/// Created Date: Monday, February 9th 2026, 2:31:32 pm
/// Author: Prashant Bhandari
/// Last Modified: Friday, February 14th 2026, 10:45:00 am
/// Modified By: Prashant Bhandari
/// 
/// Copyright (c) 2026 Electrophobia Tech
library;

import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService {
  static final BleService _instance = BleService._internal();
  factory BleService() => _instance;
  BleService._internal();

  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxCharacteristic; // For writing to ESP32
  BluetoothCharacteristic? _txCharacteristic; // For receiving from ESP32
  
  final StreamController<String> _connectionStatusController = StreamController<String>.broadcast();
  final StreamController<String> _messageController = StreamController<String>.broadcast();
  final StreamController<String> _gptResponseController = StreamController<String>.broadcast();
  final StreamController<String> _mailController = StreamController<String>.broadcast();
  
  Stream<String> get connectionStatus => _connectionStatusController.stream;
  Stream<String> get messages => _messageController.stream;
  Stream<String> get gptResponses => _gptResponseController.stream;
  Stream<String> get mails => _mailController.stream;
  
  bool get isConnected => _connectedDevice != null;
  String get deviceName => _connectedDevice?.platformName ?? 'No Device';
  bool get isGptRequestPending => _pendingGptRequest;

  // Track pending requests to route responses correctly
  bool _pendingGptRequest = false;
  bool _pendingMailRequest = false;
  
  // Deduplication
  String _lastReceivedMessage = '';
  DateTime _lastReceivedTime = DateTime.now();

  // ESP32 Service and Characteristic UUIDs (Nordic UART Service)
  final String serviceUUID = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
  final String rxCharacteristicUUID = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; // Phone → ESP (Write)
  final String txCharacteristicUUID = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"; // ESP → Phone (Notify)

  Future<List<BluetoothDevice>> scanDevices() async {
    try {
      _connectionStatusController.add('Scanning...');
      
      List<BluetoothDevice> foundDevices = [];
      
      // Start scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      
      // Listen to scan results
      final subscription = FlutterBluePlus.scanResults.listen((results) {
        for (ScanResult result in results) {
          if (result.device.platformName.isNotEmpty && !foundDevices.contains(result.device)) {
            foundDevices.add(result.device);
          }
        }
      });
      
      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 10));
      
      await FlutterBluePlus.stopScan();
      await subscription.cancel();
      
      _connectionStatusController.add('Scan complete');
      return foundDevices;
    } catch (e) {
      _connectionStatusController.add('Error: $e');
      return [];
    }
  }

  Future<void> scanAndConnect() async {
    try {
      _connectionStatusController.add('Scanning...');
      
      // Start scanning
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));
      
      // Listen to scan results
      FlutterBluePlus.scanResults.listen((results) async {
        for (ScanResult result in results) {
          // Look for ESP32 device name from your firmware
          if (result.device.platformName.contains('ESP32_BLE_CHAT') || 
              result.device.platformName.contains('ESP32')) {
            await FlutterBluePlus.stopScan();
            await _connectToDevice(result.device);
            break;
          }
        }
      });
    } catch (e) {
      _connectionStatusController.add('Error: $e');
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    await _connectToDevice(device);
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      _connectionStatusController.add('Connecting...');
      await device.connect();
      _connectedDevice = device;
      _connectionStatusController.add('Connected');
      
      // Discover services
      List<BluetoothService> services = await device.discoverServices();
      for (var service in services) {
        if (service.uuid.toString().toLowerCase() == serviceUUID.toLowerCase()) {
          for (var characteristic in service.characteristics) {
            // RX Characteristic (Phone → ESP32) - for writing
            if (characteristic.uuid.toString().toLowerCase() == rxCharacteristicUUID.toLowerCase()) {
              _rxCharacteristic = characteristic;
            }
            
            // TX Characteristic (ESP32 → Phone) - for notifications
            if (characteristic.uuid.toString().toLowerCase() == txCharacteristicUUID.toLowerCase()) {
              _txCharacteristic = characteristic;
              
              // Subscribe to notifications from ESP32
              await characteristic.setNotifyValue(true);
              
              // Use onValueReceived to avoid duplicate notifications
              characteristic.onValueReceived.listen((value) {
                if (value.isNotEmpty) {
                  String message = String.fromCharCodes(value);
                  
                  // Deduplication: ignore if same message received within 2 seconds
                  final now = DateTime.now();
                  if (message == _lastReceivedMessage && 
                      now.difference(_lastReceivedTime).inSeconds < 2) {
                    print('Duplicate message ignored: $message');
                    return;
                  }
                  
                  _lastReceivedMessage = message;
                  _lastReceivedTime = now;
                  
                  print('BLE Received: $message');
                  
                  // Check message type and route accordingly
                  if (message.startsWith('GPT_RESPONSE:')) {
                    // ESP32 added prefix
                    if (_pendingGptRequest) {
                      String response = message.substring(13);
                      // Remove AAEND prefix if present
                      if (response.startsWith('AAEND')) {
                        response = response.substring(5);
                      }
                      _gptResponseController.add(response);
                      _pendingGptRequest = false;
                    } else {
                      // Request was cancelled, ignore the response
                      print('GPT response ignored (request was cancelled)');
                    }
                  } else if (message.startsWith('AAEND')) {
                    // GPT response with AAEND prefix but without GPT_RESPONSE prefix
                    if (_pendingGptRequest) {
                      final response = message.substring(5);
                      _gptResponseController.add(response);
                      _pendingGptRequest = false;
                    } else {
                      // Request was cancelled, ignore the response
                      print('GPT response ignored (request was cancelled)');
                    }
                  } else if (message.startsWith('MAIL:')) {
                    final mailContent = message.substring(5);
                    _mailController.add(mailContent);
                    _pendingMailRequest = false;
                  } else if (message.startsWith('MS')) {
                    // Regular message from LoRa network with MS prefix
                    final actualMessage = message.substring(2);
                    _messageController.add(actualMessage);
                  } else if (_pendingGptRequest) {
                    // ESP32 sent response without prefix, but we're waiting for GPT
                    String response = message;
                    // Remove AAEND prefix if present
                    if (response.startsWith('AAEND')) {
                      response = response.substring(5);
                    }
                    _gptResponseController.add(response);
                    _pendingGptRequest = false;
                  } else if (_pendingMailRequest) {
                    // ESP32 sent mail response without prefix
                    _mailController.add(message);
                    _pendingMailRequest = false;
                  } else {
                    // Regular message from LoRa network
                    _messageController.add(message);
                  }
                }
              });
            }
          }
        }
      }
      
      // Listen to connection state
      device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected) {
          _connectionStatusController.add('Disconnected');
          _connectedDevice = null;
          _rxCharacteristic = null;

          _txCharacteristic = null;
          _pendingGptRequest = false;
          _pendingMailRequest = false;
        }
      });
    } catch (e) {
      _connectionStatusController.add('Connection Error: $e');
    }
  }

  Future<void> sendMessage(String message) async {
    if (_rxCharacteristic != null && isConnected) {
      try {
        // Track what type of request we're sending to route response correctly
        if (message.startsWith('RITUGP')) {
          _pendingGptRequest = true;
          print('GPT request sent, waiting for response...');
          
          // Timeout after 60 seconds
          Future.delayed(const Duration(seconds: 60), () {
            if (_pendingGptRequest) {
              _pendingGptRequest = false;
              print('GPT request timeout');
            }
          });
        } else if (message.startsWith('MAILBD')) {
          _pendingMailRequest = true;
          print('Mail request sent, waiting for response...');
          
          // Timeout after 30 seconds
          Future.delayed(const Duration(seconds: 30), () {
            if (_pendingMailRequest) {
              _pendingMailRequest = false;
              print('Mail request timeout');
            }
          });
        }
        
        // Write without requesting response - ESP32 will only notify when it has actual data
        await _rxCharacteristic!.write(message.codeUnits, withoutResponse: true);
      } catch (e) {
        _messageController.add('Send Error: $e');
        print('BLE Send Error: $e');
        _pendingGptRequest = false;
        _pendingMailRequest = false;
      }
    }
  }

  Future<void> disconnect() async {
    if (_connectedDevice != null) {
      await _connectedDevice!.disconnect();
      _connectedDevice = null;
      _rxCharacteristic = null;
      _txCharacteristic = null;
      _pendingGptRequest = false;
      _pendingMailRequest = false;
      _connectionStatusController.add('Disconnected');
    }
  }

  void cancelGptRequest() {
    _pendingGptRequest = false;
    print('GPT request cancelled by user');
  }

  void dispose() {
    _connectionStatusController.close();
    _messageController.close();
    _gptResponseController.close();
    _mailController.close();
  }
}
