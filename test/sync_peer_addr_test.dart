// Адрес пира для прямого подключения: движок отдаёт адрес из живой сессии
// (IP, каким он виден нам, + порт прослушивания из hello), а правило слияния
// решает, что записать в peer_addrs.json.
//
// Повод: телефон раздаёт интернет, ПК — его клиент. mDNS из точки доступа у
// телефона не работает, и остаётся единственный путь — сохранённый адрес. Если IP
// ПК сменился (переподключение к точке доступа), адрес нужно освежить из уже
// установленного соединения — иначе синк встанет до нового сопряжения по QR.

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/engine.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';
import 'package:qtnotes_mobile/sync/peers.dart';
import 'package:qtnotes_mobile/sync/store.dart';

SyncStore _store(Directory root, Identity id) {
  final vault = Vault(root);
  final oplog = OpLog(File('${root.path}/sync.json'), localId: id.deviceId);
  return SyncStore(oplog, ApplyEngine(vault), vault);
}

Future<bool> _waitUntil(bool Function() pred, Duration timeout) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    if (pred()) return true;
    await Future.delayed(const Duration(milliseconds: 50));
  }
  return pred();
}

class _Rec {
  final String deviceId;
  final String host;
  final int port;
  _Rec(this.deviceId, this.host, this.port);
}

void main() {
  group('mergePeerAddr', () {
    test('новая запись — host и порт из hello', () {
      expect(mergePeerAddr(null, '192.168.43.5', 8765),
          {'host': '192.168.43.5', 'port': 8765});
    });

    test('IP сменился, пир порт не сообщил — держим сохранённый порт', () {
      expect(
          mergePeerAddr({'host': '192.168.43.5', 'port': 8765}, '192.168.43.9', 0),
          {'host': '192.168.43.9', 'port': 8765});
    });

    test('пир сообщил новый порт — обновляем и порт', () {
      expect(
          mergePeerAddr({'host': '192.168.43.5', 'port': 8765}, '192.168.43.5', 9000),
          {'host': '192.168.43.5', 'port': 9000});
    });

    test('адрес не изменился — null, файл не переписываем', () {
      expect(
          mergePeerAddr({'host': '192.168.43.5', 'port': 8765}, '192.168.43.5', 8765),
          isNull);
      expect(
          mergePeerAddr({'host': '192.168.43.5', 'port': 8765}, '192.168.43.5', 0),
          isNull);
    });

    test('порт неизвестен и запоминать нечего — null', () {
      expect(mergePeerAddr(null, '192.168.43.5', 0), isNull);
      expect(mergePeerAddr(null, '', 8765), isNull);
    });
  });

  test('обе стороны узнают адрес пира из установленной сессии', () async {
    final dirA = await Directory.systemTemp.createTemp('qtn_addr_a_');
    final dirB = await Directory.systemTemp.createTemp('qtn_addr_b_');
    final idA = await ensureIdentity(Directory('${dirA.path}/device'), 'A');
    final idB = await ensureIdentity(Directory('${dirB.path}/device'), 'B');

    final recA = <_Rec>[];
    final recB = <_Rec>[];
    final engA = SyncEngine(idA, _store(dirA, idA),
        getPeers: () async => [Peer(idB.deviceId, 'B', idB.certPem, 'now')],
        onPeerAddr: (d, h, p) => recA.add(_Rec(d, h, p)));
    final engB = SyncEngine(idB, _store(dirB, idB),
        getPeers: () async => [Peer(idA.deviceId, 'A', idA.certPem, 'now')],
        onPeerAddr: (d, h, p) => recB.add(_Rec(d, h, p)));

    await engA.serve(host: '127.0.0.1', port: 0);
    await engB.serve(host: '127.0.0.1', port: 0);
    await engA.connect('127.0.0.1', engB.port!, idB.deviceId);

    // A дозвонился сам — про B он и так знал; а вот B узнаёт адрес A, хотя сам
    // к нему не подключался. Это и есть починка устаревшего адреса.
    expect(await _waitUntil(() => recA.isNotEmpty, const Duration(seconds: 10)), isTrue,
        reason: 'инициатор не узнал адрес пира');
    expect(await _waitUntil(() => recB.isNotEmpty, const Duration(seconds: 10)), isTrue,
        reason: 'принимающая сторона не узнала адрес пира');

    final aAboutB = recA.first;
    expect(aAboutB.deviceId, idB.deviceId);
    expect(aAboutB.host, '127.0.0.1');
    expect(aAboutB.port, engB.port, reason: 'порт должен быть из hello, не исходный');

    final bAboutA = recB.first;
    expect(bAboutA.deviceId, idA.deviceId);
    expect(bAboutA.host, '127.0.0.1');
    expect(bAboutA.port, engA.port, reason: 'порт прослушивания пира, не эфемерный');

    await engA.stop();
    await engB.stop();
    await dirA.delete(recursive: true);
    await dirB.delete(recursive: true);
  });
}
