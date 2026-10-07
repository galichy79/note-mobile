// Доверенные (сопряжённые) устройства — trust-store в peers.json.
// Формат идентичен десктопу (qtnotes/sync/peers.py): список объектов
// {device_id, name, cert_pem, paired_at}.

import 'dart:convert';
import 'dart:io';

import '../storage/models.dart' show nowIso;

class Peer {
  final String deviceId;
  final String name;
  final String certPem;
  final String pairedAt;
  Peer(this.deviceId, this.name, this.certPem, this.pairedAt);

  Map<String, dynamic> toJson() => {
        'device_id': deviceId,
        'name': name,
        'cert_pem': certPem,
        'paired_at': pairedAt,
      };

  factory Peer.fromJson(Map<String, dynamic> d) => Peer(
        d['device_id'] as String,
        (d['name'] ?? '') as String,
        (d['cert_pem'] ?? '') as String,
        (d['paired_at'] ?? '') as String,
      );
}

class PeerStore {
  final File file;
  PeerStore(this.file);

  Future<List<Peer>> list() async {
    try {
      if (!await file.exists()) return [];
      final data = jsonDecode(await file.readAsString());
      if (data is! List) return [];
      return data.map((e) => Peer.fromJson((e as Map).cast<String, dynamic>())).toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _save(List<Peer> peers) async {
    await file.parent.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(peers.map((p) => p.toJson()).toList()));
    await tmp.rename(file.path);
  }

  Future<Peer?> get(String deviceId) async {
    for (final p in await list()) {
      if (p.deviceId == deviceId) return p;
    }
    return null;
  }

  Future<bool> isTrusted(String deviceId) async => (await get(deviceId)) != null;

  Future<Peer> add(String deviceId, String name, String certPem) async {
    final peers = (await list()).where((p) => p.deviceId != deviceId).toList();
    final peer = Peer(deviceId, name, certPem, nowIso());
    peers.add(peer);
    await _save(peers);
    return peer;
  }

  Future<void> remove(String deviceId) async {
    await _save((await list()).where((p) => p.deviceId != deviceId).toList());
  }
}

/// Адрес пира для прямого подключения: `{'host': String, 'port': int}`.
///
/// Пиры зовут это регулярно (живая сессия, mDNS), поэтому возвращаем **null**, когда
/// писать нечего: адрес непригоден или уже совпадает с сохранённым.
///
/// [port] = 0 означает «пир не сообщил свой порт» (старая версия на той стороне) —
/// тогда держим уже сохранённый: хост мог смениться, а порт прослушивания у пира
/// стабильный. Без порта адрес бесполезен, и запись не создаём.
Map<String, dynamic>? mergePeerAddr(
    Map<String, dynamic>? current, String host, int port) {
  if (host.isEmpty) return null;
  final known = (current?['port'] as num?)?.toInt() ?? 0;
  final effective = port > 0 ? port : known;
  if (effective <= 0) return null;
  if (current != null && current['host'] == host && known == effective) {
    return null; // не изменился — файл не переписываем
  }
  return {'host': host, 'port': effective};
}
