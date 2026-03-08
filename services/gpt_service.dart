///
/// Filename: c:\projects\lora_net\lora_net_app\lib\services\gpt_service.dart
/// Path: c:\projects\lora_net\lora_net_app\lib\services
/// Created Date: Monday, February 9th 2026, 2:31:44 pm
/// Author: Prashant Bhandari
/// Last Modified: Friday, February 14th 2026, 10:45:00 am
/// Modified By: Prashant Bhandari
/// 
/// Copyright (c) 2026 Electrophobia Tech
library;





import 'ble_service.dart';

class GptService {
  final BleService _bleService = BleService();

  Future<void> askQuestion(String question) async {
    // Send GPT question to ESP32 via BLE with GRITU prefix
    // ESP32 will handle the OpenAI API call and send response back
    final message = 'RITUGP$question';
    await _bleService.sendMessage(message);
  }
}
