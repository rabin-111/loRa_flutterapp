///
/// Filename: main.dart
/// Author: Prashant Bhandari
/// Copyright (c) 2026 Electrophobia Tech
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'services/ble_service.dart';
import 'services/database_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await DatabaseService.init();
  runApp(const LoraNetApp());
}

class LoraNetApp extends StatelessWidget {
  const LoraNetApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'LoraNet',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4FC3F7),
          brightness: Brightness.light,
          primary: const Color(0xFF4FC3F7),
          secondary: const Color(0xFF29B6F6),
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F9FC),
        cardColor: Colors.white,
        appBarTheme: const AppBarTheme(
          elevation: 0,
          backgroundColor: Color(0xFF4FC3F7),
          foregroundColor: Colors.white,
        ),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final BleService _bleService = BleService();

  String _connectionStatus = 'Disconnected';
  final List<Map<String, dynamic>> _messages = [];
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _messageScrollController = ScrollController();

  int _selectedIndex = 0;
  String _userId = '';
  String _userName = 'User';
  bool _isEmergency = false; // toggle for emergency mode

  // Max BLE chunk size — ESP32 BLE MTU is usually 512 bytes
  // We use 200 chars per chunk to be safe with any encoding
  static const int _chunkSize = 200;

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _setupListeners();
    _loadSavedMessages();
    _loadUserProfile();
  }

  Future<void> _loadUserProfile() async {
    final savedName = await DatabaseService.getUserName();
    if (savedName != null && savedName.isNotEmpty) {
      setState(() => _userName = savedName);
    }
    final savedId = await DatabaseService.getUserId();
    if (savedId != null && savedId.isNotEmpty) {
      setState(() => _userId = savedId);
    } else {
      final now = DateTime.now().millisecondsSinceEpoch;
      final newId = 'LN-${now.toRadixString(16).toUpperCase().substring(5)}';
      await DatabaseService.saveUserId(newId);
      setState(() => _userId = newId);
    }
  }

  Future<void> _loadSavedMessages() async {
    final saved = await DatabaseService.loadMessages();
    setState(() => _messages.addAll(saved));
  }

  Future<void> _requestPermissions() async {
    await Permission.bluetoothScan.request();
    await Permission.bluetoothConnect.request();
    await Permission.location.request();
  }

  void _setupListeners() {
    _bleService.connectionStatus.listen((status) {
      setState(() => _connectionStatus = status);
      // Auto-retry failed messages when BLE reconnects
      if (status.contains('Connected')) {
        Future.delayed(const Duration(milliseconds: 500), _retryFailedMessages);
      }
    });

    _bleService.messages.listen((message) async {
      // Check if this is an ACK for a sent message (format: ACK:id)
      if (message.startsWith('ACK:')) {
        final idStr = message.substring(4);
        final id = int.tryParse(idStr);
        if (id != null) {
          await DatabaseService.updateMessageStatus(id, 'delivered');
          setState(() {
            final index = _messages.indexWhere((m) => m['id'] == id);
            if (index != -1) _messages[index]['status'] = 'delivered';
          });
        }
        return;
      }

      // Regular incoming message
      final isEmergency = message.startsWith('EMERGENCY:');
      final displayText = isEmergency ? message.substring(10) : message;

      final id = await DatabaseService.saveMessage(
        text: displayText,
        isSent: false,
        status: 'received',
        isEmergency: isEmergency,
      );

      setState(() {
        _messages.add({
          'id': id,
          'text': displayText,
          'isSent': false,
          'time': DateTime.now(),
          'status': 'received',
          'isEmergency': isEmergency,
          'retryCount': 0,
        });
      });
      _scrollToBottom(_messageScrollController);
    });
  }

  // ── CHUNK LARGE MESSAGES ──────────────────────────────────────────────────

  /// Split a long message into chunks and send each one
  /// Prefix: CHUNK_START / CHUNK / CHUNK_END so ESP32 can reassemble
  List<String> _chunkMessage(String text) {
    if (text.length <= _chunkSize) return [text];

    final chunks = <String>[];
    for (int i = 0; i < text.length; i += _chunkSize) {
      final end = (i + _chunkSize < text.length) ? i + _chunkSize : text.length;
      chunks.add(text.substring(i, end));
    }
    return chunks;
  }

  Future<void> _sendChunked(String text, bool isEmergency) async {
    final prefix = isEmergency ? 'EMERGENCY:' : '';
    final chunks = _chunkMessage(text);

    if (chunks.length == 1) {
      await _bleService.sendMessage('$prefix${chunks[0]}');
    } else {
      // Multi-chunk: tell ESP32 how many chunks are coming
      await _bleService.sendMessage('CHUNK_START:${chunks.length}');
      for (int i = 0; i < chunks.length; i++) {
        await _bleService.sendMessage('CHUNK:$prefix${chunks[i]}');
        // Small delay between chunks to avoid BLE overflow
        await Future.delayed(const Duration(milliseconds: 50));
      }
      await _bleService.sendMessage('CHUNK_END');
    }
  }

  // ── RETRY LOGIC ───────────────────────────────────────────────────────────

  Future<void> _retryFailedMessages() async {
    final failed = await DatabaseService.getFailedMessages();
    if (failed.isEmpty) return;

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Retrying ${failed.length} unsent message(s)...'),
          backgroundColor: const Color(0xFF4FC3F7),
          duration: const Duration(seconds: 3),
        ),
      );
    }

    for (final msg in failed) {
      final id = msg['id'] as int;
      final text = msg['text'] as String;
      final isEmergency = msg['isEmergency'] as bool;

      try {
        await _sendChunked(text, isEmergency);
        await DatabaseService.updateMessageStatus(id, 'sent');
        setState(() {
          final index = _messages.indexWhere((m) => m['id'] == id);
          if (index != -1) _messages[index]['status'] = 'sent';
        });
      } catch (e) {
        await DatabaseService.incrementRetry(id);
        setState(() {
          final index = _messages.indexWhere((m) => m['id'] == id);
          if (index != -1) {
            _messages[index]['status'] = 'failed';
            _messages[index]['retryCount'] = (msg['retryCount'] as int) + 1;
          }
        });
      }
    }
  }

  /// Manually retry a single message (called on long press)
  Future<void> _retrySingleMessage(Map<String, dynamic> msg) async {
    if (!_bleService.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Not connected to ESP32. Please connect first.'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    final id = msg['id'] as int;
    final text = msg['text'] as String;
    final isEmergency = msg['isEmergency'] as bool? ?? false;

    setState(() {
      final index = _messages.indexWhere((m) => m['id'] == id);
      if (index != -1) _messages[index]['status'] = 'pending';
    });

    try {
      await _sendChunked(text, isEmergency);
      await DatabaseService.updateMessageStatus(id, 'sent');
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) _messages[index]['status'] = 'sent';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Message sent!'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      await DatabaseService.incrementRetry(id);
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) _messages[index]['status'] = 'failed';
      });
    }
  }

  void _scrollToBottom(ScrollController controller) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (controller.hasClients) {
        controller.animateTo(
          controller.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _connectToBle() async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: Card(
          child: Padding(
            padding: EdgeInsets.all(20.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Scanning for devices...'),
              ],
            ),
          ),
        ),
      ),
    );

    final devices = await _bleService.scanDevices();
    if (mounted) Navigator.of(context).pop();

    if (devices.isEmpty) {
      if (mounted) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('No Devices Found'),
            content: const Text('No Bluetooth devices found. Make sure your ESP32 is on.'),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK')),
            ],
          ),
        );
      }
      return;
    }

    if (mounted) {
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Select Device'),
          content: SizedBox(
            width: double.maxFinite,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: devices.length,
              itemBuilder: (context, index) {
                final device = devices[index];
                return ListTile(
                  leading: const Icon(Icons.bluetooth, color: Color(0xFF4FC3F7)),
                  title: Text(
                    device.platformName.isEmpty ? 'Unknown Device' : device.platformName,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(device.remoteId.toString(),
                      style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                  onTap: () async {
                    Navigator.of(context).pop();
                    await _bleService.connectToDevice(device);
                  },
                );
              },
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
          ],
        ),
      );
    }
  }

  void _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();

    final emergency = _isEmergency;

    // Save as pending first — so message is never lost
    final id = await DatabaseService.saveMessage(
      text: text,
      isSent: true,
      status: 'pending',
      isEmergency: emergency,
    );

    // Show in UI immediately as pending
    setState(() {
      _messages.add({
        'id': id,
        'text': text,
        'isSent': true,
        'time': DateTime.now(),
        'status': 'pending',
        'isEmergency': emergency,
        'retryCount': 0,
      });
      // Reset emergency toggle after sending
      _isEmergency = false;
    });
    _scrollToBottom(_messageScrollController);

    if (!_bleService.isConnected) {
      // Not connected — keep as pending, will retry on reconnect
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Saved! Will send when ESP32 reconnects.'),
          backgroundColor: Colors.orange,
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }

    try {
      await _sendChunked(text, emergency);
      await DatabaseService.updateMessageStatus(id, 'sent');
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) _messages[index]['status'] = 'sent';
      });
    } catch (e) {
      await DatabaseService.updateMessageStatus(id, 'failed');
      setState(() {
        final index = _messages.indexWhere((m) => m['id'] == id);
        if (index != -1) _messages[index]['status'] = 'failed';
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to send. Long press to retry.'),
            backgroundColor: Colors.red,
            duration: Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _editName() {
    final controller = TextEditingController(text: _userName);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Edit Name'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: 'Enter your name'),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                setState(() => _userName = controller.text);
                DatabaseService.saveUserName(controller.text);
              }
              Navigator.pop(context);
            },
            style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4FC3F7), foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  // ── STATUS ICON ───────────────────────────────────────────────────────────
  // Shows the correct tick/icon based on message status
  Widget _buildStatusIcon(String status) {
    switch (status) {
      case 'pending':
        return const Icon(Icons.access_time, size: 14, color: Colors.white70);
      case 'sent':
        return const Icon(Icons.done, size: 14, color: Colors.white70);
      case 'delivered':
      // Blue double tick like WhatsApp/Messenger
        return const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.done, size: 14, color: Colors.lightBlueAccent),
            SizedBox(width: -6),
            Icon(Icons.done, size: 14, color: Colors.lightBlueAccent),
          ],
        );
      case 'failed':
        return const Icon(Icons.error_outline, size: 14, color: Colors.redAccent);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.router, size: 20),
            ),
            const SizedBox(width: 12),
            const Text('LoraNet', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 20)),
          ],
        ),
        actions: [
          Container(
            margin: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(0.15),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(0.3), width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _connectionStatus.contains('Connected')
                      ? Icons.bluetooth_connected
                      : Icons.bluetooth_disabled,
                  size: 16,
                  color: _connectionStatus.contains('Connected') ? Colors.greenAccent : Colors.white70,
                ),
                const SizedBox(width: 6),
                Text(
                  _bleService.isConnected ? _bleService.deviceName : 'Disconnected',
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
          if (!_bleService.isConnected)
            Container(
              margin: const EdgeInsets.only(right: 8),
              decoration: BoxDecoration(color: Colors.white.withOpacity(0.2), shape: BoxShape.circle),
              child: IconButton(
                icon: const Icon(Icons.refresh, size: 20),
                onPressed: _connectToBle,
                tooltip: 'Connect to ESP32',
              ),
            ),
        ],
      ),
      body: SafeArea(
        child: _selectedIndex == 0 ? _buildMessagingTab() : _buildProfileTab(),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2))],
        ),
        child: SafeArea(
          child: BottomNavigationBar(
            currentIndex: _selectedIndex,
            selectedFontSize: 12,
            unselectedFontSize: 11,
            type: BottomNavigationBarType.fixed,
            elevation: 0,
            backgroundColor: Colors.transparent,
            selectedItemColor: const Color(0xFF4FC3F7),
            unselectedItemColor: Colors.grey[400],
            onTap: (index) => setState(() => _selectedIndex = index),
            items: const [
              BottomNavigationBarItem(
                icon: Padding(padding: EdgeInsets.only(bottom: 4), child: Icon(Icons.message_outlined, size: 24)),
                activeIcon: Padding(padding: EdgeInsets.only(bottom: 4), child: Icon(Icons.message, size: 24)),
                label: 'Messages',
              ),
              BottomNavigationBarItem(
                icon: Padding(padding: EdgeInsets.only(bottom: 4), child: Icon(Icons.person_outline, size: 24)),
                activeIcon: Padding(padding: EdgeInsets.only(bottom: 4), child: Icon(Icons.person, size: 24)),
                label: 'Profile',
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── MESSAGING TAB ──────────────────────────────────────────────────────────
  Widget _buildMessagingTab() {
    if (!_bleService.isConnected) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.all(32),
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: [
                    const Color(0xFF4FC3F7).withOpacity(0.2),
                    const Color(0xFF29B6F6).withOpacity(0.1),
                  ]),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.bluetooth_disabled, size: 72, color: Color(0xFF4FC3F7)),
              ),
              const SizedBox(height: 32),
              const Text('Not Connected to ESP32',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Color(0xFF263238))),
              const SizedBox(height: 12),
              Text('Connect to start messaging via LoRa network',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, color: Colors.grey[600])),
              const SizedBox(height: 40),
              ElevatedButton.icon(
                onPressed: _connectToBle,
                icon: const Icon(Icons.bluetooth_searching, size: 22),
                label: const Text('Scan & Connect',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF4FC3F7),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 18),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
                  elevation: 2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        // Message list
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [const Color(0xFFE3F2FD), const Color(0xFFF5F9FC)],
              ),
            ),
            child: _messages.isEmpty
                ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.chat_bubble_outline, size: 64, color: Colors.grey[300]),
                  const SizedBox(height: 16),
                  Text('No messages yet', style: TextStyle(color: Colors.grey[500], fontSize: 16)),
                  const SizedBox(height: 8),
                  Text('Send your first message!', style: TextStyle(color: Colors.grey[400], fontSize: 14)),
                ],
              ),
            )
                : ListView.builder(
              controller: _messageScrollController,
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length,
              itemBuilder: (context, index) {
                final message = _messages[index];
                final isSent = message['isSent'] as bool;
                final text = message['text'] as String;
                final time = message['time'] as DateTime;
                final status = message['status'] as String;
                final isEmergency = message['isEmergency'] as bool? ?? false;
                final retryCount = message['retryCount'] as int? ?? 0;

                // Emergency = red bubble, normal sent = blue, received = white
                Color bubbleColor;
                if (isEmergency) {
                  bubbleColor = const Color(0xFFD32F2F);
                } else if (isSent) {
                  bubbleColor = const Color(0xFF4FC3F7);
                } else {
                  bubbleColor = Colors.white;
                }

                return GestureDetector(
                  // Long press on failed message shows retry option
                  onLongPress: (status == 'failed' && isSent)
                      ? () {
                    showModalBottomSheet(
                      context: context,
                      shape: const RoundedRectangleBorder(
                        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
                      ),
                      builder: (context) => Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 40, height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey[300],
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                            const SizedBox(height: 20),
                            const Text('Message Failed',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            const SizedBox(height: 8),
                            Text('Tried $retryCount time(s). What do you want to do?',
                                style: TextStyle(color: Colors.grey[600])),
                            const SizedBox(height: 24),
                            Row(
                              children: [
                                Expanded(
                                  child: OutlinedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(context);
                                    },
                                    icon: const Icon(Icons.close, color: Colors.red),
                                    label: const Text('Dismiss', style: TextStyle(color: Colors.red)),
                                    style: OutlinedButton.styleFrom(
                                      side: const BorderSide(color: Colors.red),
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: ElevatedButton.icon(
                                    onPressed: () {
                                      Navigator.pop(context);
                                      _retrySingleMessage(message);
                                    },
                                    icon: const Icon(Icons.refresh),
                                    label: const Text('Retry Now'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: const Color(0xFF4FC3F7),
                                      foregroundColor: Colors.white,
                                      padding: const EdgeInsets.symmetric(vertical: 14),
                                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                          ],
                        ),
                      ),
                    );
                  }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      mainAxisAlignment: isSent ? MainAxisAlignment.end : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (!isSent)
                          Container(
                            margin: const EdgeInsets.only(right: 8, bottom: 2),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isEmergency ? const Color(0xFFD32F2F) : const Color(0xFF4FC3F7),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isEmergency ? Icons.warning : Icons.router,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        Flexible(
                          child: Column(
                            crossAxisAlignment: isSent ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                            children: [
                              // Emergency label
                              if (isEmergency)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      const Icon(Icons.warning, size: 14, color: Color(0xFFD32F2F)),
                                      const SizedBox(width: 4),
                                      Text('EMERGENCY',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w800,
                                            color: const Color(0xFFD32F2F),
                                            letterSpacing: 1,
                                          )),
                                    ],
                                  ),
                                ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                                constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.72),
                                decoration: BoxDecoration(
                                  color: bubbleColor,
                                  borderRadius: BorderRadius.only(
                                    topLeft: Radius.circular(isSent ? 20 : 6),
                                    topRight: Radius.circular(isSent ? 6 : 20),
                                    bottomLeft: const Radius.circular(20),
                                    bottomRight: const Radius.circular(20),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: isEmergency
                                          ? Colors.red.withOpacity(0.3)
                                          : Colors.black.withOpacity(0.06),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                  border: isEmergency
                                      ? Border.all(color: const Color(0xFFD32F2F), width: 1.5)
                                      : null,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      text,
                                      style: TextStyle(
                                        fontSize: 15,
                                        height: 1.4,
                                        color: (isSent || isEmergency) ? Colors.white : const Color(0xFF263238),
                                      ),
                                    ),
                                    const SizedBox(height: 6),
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: (isSent || isEmergency)
                                                ? Colors.white.withOpacity(0.7)
                                                : Colors.grey[500],
                                          ),
                                        ),
                                        if (isSent) ...[
                                          const SizedBox(width: 4),
                                          _buildStatusIcon(status),
                                        ],
                                      ],
                                    ),
                                    // Show retry count if failed more than once
                                    if (status == 'failed' && retryCount > 0)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          'Failed · $retryCount retries · Long press to retry',
                                          style: TextStyle(
                                            fontSize: 10,
                                            color: Colors.white.withOpacity(0.8),
                                            fontStyle: FontStyle.italic,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (isSent)
                          Container(
                            margin: const EdgeInsets.only(left: 8, bottom: 2),
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: isEmergency ? const Color(0xFFD32F2F) : const Color(0xFF29B6F6),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              isEmergency ? Icons.warning : Icons.person,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // Emergency toggle + input bar
        Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.05), blurRadius: 10, offset: const Offset(0, -2))],
          ),
          child: Column(
            children: [
              // Emergency toggle row
              Row(
                children: [
                  GestureDetector(
                    onTap: () => setState(() => _isEmergency = !_isEmergency),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: _isEmergency ? const Color(0xFFD32F2F) : Colors.grey[100],
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: _isEmergency ? const Color(0xFFD32F2F) : Colors.grey[300]!,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.warning,
                            size: 16,
                            color: _isEmergency ? Colors.white : Colors.grey[500],
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _isEmergency ? 'EMERGENCY ON' : 'Emergency',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: _isEmergency ? Colors.white : Colors.grey[500],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (_isEmergency)
                    Text(
                      'Message will be sent in red',
                      style: TextStyle(fontSize: 11, color: Colors.red[400], fontStyle: FontStyle.italic),
                    ),
                ],
              ),
              const SizedBox(height: 8),

              // Text input row
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      decoration: BoxDecoration(
                        color: _isEmergency ? Colors.red[50] : const Color(0xFFF5F9FC),
                        borderRadius: BorderRadius.circular(25),
                        border: _isEmergency
                            ? Border.all(color: const Color(0xFFD32F2F), width: 1.5)
                            : null,
                      ),
                      child: TextField(
                        controller: _messageController,
                        maxLines: null, // allows multiline / 1000+ chars
                        maxLength: 5000, // allow up to 5000 characters
                        decoration: InputDecoration(
                          hintText: _isEmergency ? 'Type emergency message...' : 'Type a message...',
                          hintStyle: TextStyle(
                            color: _isEmergency ? Colors.red[300] : Colors.grey[400],
                          ),
                          filled: false,
                          border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(25), borderSide: BorderSide.none),
                          contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          counterText: '', // hide character counter
                        ),
                        style: TextStyle(
                          fontSize: 15,
                          color: _isEmergency ? const Color(0xFFD32F2F) : null,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: _isEmergency
                            ? [const Color(0xFFD32F2F), const Color(0xFFB71C1C)]
                            : [const Color(0xFF4FC3F7), const Color(0xFF29B6F6)],
                      ),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: (_isEmergency ? Colors.red : const Color(0xFF4FC3F7)).withOpacity(0.4),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: IconButton(
                      onPressed: _sendMessage,
                      icon: Icon(
                        _isEmergency ? Icons.warning : Icons.send,
                        color: Colors.white,
                        size: 22,
                      ),
                      padding: const EdgeInsets.all(12),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  // ── PROFILE TAB ────────────────────────────────────────────────────────────
  Widget _buildProfileTab() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        children: [
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF4FC3F7), Color(0xFF0288D1)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: const Color(0xFF4FC3F7).withOpacity(0.4), blurRadius: 20, offset: const Offset(0, 8))],
            ),
            child: const Icon(Icons.person, size: 64, color: Colors.white),
          ),
          const SizedBox(height: 24),
          Text(_userName,
              style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700, color: Color(0xFF263238))),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: _editName,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.edit, size: 14, color: Colors.grey[500]),
                const SizedBox(width: 4),
                Text('Edit name', style: TextStyle(fontSize: 13, color: Colors.grey[500])),
              ],
            ),
          ),
          const SizedBox(height: 36),

          // Unique ID card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: const Color(0xFF4FC3F7).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.fingerprint, color: Color(0xFF4FC3F7), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text('Your Unique ID',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF263238))),
                  ],
                ),
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF5F9FC),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF4FC3F7).withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        _userId.isEmpty ? 'Loading...' : _userId,
                        style: const TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800, color: Color(0xFF0288D1), letterSpacing: 2),
                      ),
                      GestureDetector(
                        onTap: () {
                          if (_userId.isNotEmpty) {
                            Clipboard.setData(ClipboardData(text: _userId));
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text('ID copied to clipboard!'),
                                duration: Duration(seconds: 2),
                                backgroundColor: Color(0xFF4FC3F7),
                              ),
                            );
                          }
                        },
                        child: const Icon(Icons.copy, color: Color(0xFF4FC3F7), size: 22),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Share this ID with others so they can message you on the LoRa network.',
                  style: TextStyle(fontSize: 13, color: Colors.grey[500], height: 1.5),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Stats card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                          color: const Color(0xFF4FC3F7).withOpacity(0.1),
                          borderRadius: BorderRadius.circular(10)),
                      child: const Icon(Icons.bar_chart, color: Color(0xFF4FC3F7), size: 22),
                    ),
                    const SizedBox(width: 12),
                    const Text('Message Stats',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF263238))),
                  ],
                ),
                const SizedBox(height: 20),
                Row(
                  children: [
                    Expanded(child: _statBox('Sent', '${_messages.where((m) => m['isSent'] == true).length}', Icons.arrow_upward)),
                    const SizedBox(width: 12),
                    Expanded(child: _statBox('Received', '${_messages.where((m) => m['isSent'] == false).length}', Icons.arrow_downward)),
                    const SizedBox(width: 12),
                    Expanded(child: _statBox('Failed', '${_messages.where((m) => m['status'] == 'failed').length}', Icons.error_outline, color: Colors.red)),
                  ],
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // Connection status card
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(20),
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.06), blurRadius: 16, offset: const Offset(0, 4))],
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: (_bleService.isConnected ? Colors.green : Colors.red).withOpacity(0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(
                    _bleService.isConnected ? Icons.bluetooth_connected : Icons.bluetooth_disabled,
                    color: _bleService.isConnected ? Colors.green : Colors.red,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ESP32 Status',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Color(0xFF263238))),
                    const SizedBox(height: 4),
                    Text(
                      _bleService.isConnected ? 'Connected to ${_bleService.deviceName}' : 'Not connected',
                      style: TextStyle(fontSize: 13, color: Colors.grey[500]),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 30),
        ],
      ),
    );
  }

  Widget _statBox(String label, String value, IconData icon, {Color? color}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: const Color(0xFFF5F9FC), borderRadius: BorderRadius.circular(14)),
      child: Column(
        children: [
          Icon(icon, color: color ?? const Color(0xFF4FC3F7), size: 20),
          const SizedBox(height: 8),
          Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: color ?? const Color(0xFF263238))),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey[500])),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _messageController.dispose();
    _messageScrollController.dispose();
    _bleService.dispose();
    super.dispose();
  }
}