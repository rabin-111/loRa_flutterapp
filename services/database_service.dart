

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DatabaseService {
  static Database? _db;

  static Future<void> init() async {
    final dbPath = await getDatabasesPath();
    final path = join(dbPath, 'loranet.db');

    _db = await openDatabase(
      path,
      version: 1,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE messages (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            text          TEXT    NOT NULL,
            is_sent       INTEGER NOT NULL,
            status        TEXT    NOT NULL DEFAULT 'pending',
            is_emergency  INTEGER NOT NULL DEFAULT 0,
            retry_count   INTEGER NOT NULL DEFAULT 0,
            timestamp     INTEGER NOT NULL
          )
        ''');

        await db.execute('''
          CREATE TABLE settings (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
          )
        ''');
      },
    );
  }

  // ── MESSAGES ──────────────────────────────────────────────────────────────

  /// Save a new message — returns the inserted row ID
  static Future<int> saveMessage({
    required String text,
    required bool isSent,
    String status = 'pending',
    bool isEmergency = false,
  }) async {
    return await _db!.insert('messages', {
      'text': text,
      'is_sent': isSent ? 1 : 0,
      'status': status,
      'is_emergency': isEmergency ? 1 : 0,
      'retry_count': 0,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// Update the status of a message by its id
  static Future<void> updateMessageStatus(int id, String status) async {
    await _db!.update(
      'messages',
      {'status': status},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// Increment retry count and mark as failed
  static Future<void> incrementRetry(int id) async {
    await _db!.rawUpdate(
      'UPDATE messages SET retry_count = retry_count + 1, status = ? WHERE id = ?',
      ['failed', id],
    );
  }

  /// Load all messages ordered by time
  static Future<List<Map<String, dynamic>>> loadMessages() async {
    final rows = await _db!.query('messages', orderBy: 'timestamp ASC');
    return rows.map((row) => {
      'id': row['id'] as int,
      'text': row['text'] as String,
      'isSent': (row['is_sent'] as int) == 1,
      'time': DateTime.fromMillisecondsSinceEpoch(row['timestamp'] as int),
      'status': row['status'] as String,
      'isEmergency': (row['is_emergency'] as int) == 1,
      'retryCount': row['retry_count'] as int,
    }).toList();
  }

  /// Get all failed/pending outgoing messages for retry
  static Future<List<Map<String, dynamic>>> getFailedMessages() async {
    final rows = await _db!.query(
      'messages',
      where: "status IN ('pending', 'failed') AND is_sent = 1",
      orderBy: 'timestamp ASC',
    );
    return rows.map((row) => {
      'id': row['id'] as int,
      'text': row['text'] as String,
      'isEmergency': (row['is_emergency'] as int) == 1,
      'retryCount': row['retry_count'] as int,
    }).toList();
  }

  // ── USER SETTINGS ─────────────────────────────────────────────────────────

  static Future<void> _saveSetting(String key, String value) async {
    await _db!.insert(
      'settings',
      {'key': key, 'value': value},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<String?> _loadSetting(String key) async {
    final rows = await _db!.query('settings', where: 'key = ?', whereArgs: [key]);
    if (rows.isEmpty) return null;
    return rows.first['value'] as String;
  }

  static Future<void> saveUserId(String id) async => _saveSetting('user_id', id);
  static Future<String?> getUserId() async => _loadSetting('user_id');

  static Future<void> saveUserName(String name) async => _saveSetting('user_name', name);
  static Future<String?> getUserName() async => _loadSetting('user_name');
}