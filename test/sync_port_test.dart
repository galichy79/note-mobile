// Порт движка синхронизации: закрепляется за устройством и переиспользуется между
// запусками, а если прежний занят — движок берёт другой, а не падает.
//
// Зачем: по этому порту десктоп дозванивается и перебирает подсеть, когда mDNS не
// работает (телефон раздаёт интернет). Со случайным портом на каждом запуске
// сохранённый у десктопа адрес устаревал бы после каждого перезапуска приложения.

import 'dart:io';

import 'package:test/test.dart';
import 'package:qtnotes_mobile/storage/vault.dart';
import 'package:qtnotes_mobile/sync/apply.dart';
import 'package:qtnotes_mobile/sync/engine.dart';
import 'package:qtnotes_mobile/sync/identity.dart';
import 'package:qtnotes_mobile/sync/oplog.dart';
import 'package:qtnotes_mobile/sync/store.dart';

Future<SyncEngine> _engine(Directory root, String name) async {
  final id = await ensureIdentity(Directory('${root.path}/device'), name);
  final vault = Vault(root);
  final oplog = OpLog(File('${root.path}/sync.json'), localId: id.deviceId);
  return SyncEngine(id, SyncStore(oplog, ApplyEngine(vault), vault),
      getPeers: () async => []);
}

void main() {
  test('движок слушает заданный порт, а занятый — не ломает старт', () async {
    final dir = await Directory.systemTemp.createTemp('qtn_port_');

    // 1) порт по умолчанию (любой свободный) — движок его сообщает
    final first = await _engine(dir, 'A');
    await first.serve(host: '127.0.0.1', port: 0);
    final picked = first.port;
    expect(picked, isNotNull);
    expect(picked, greaterThan(0));
    await first.stop();

    // 2) тот же порт переиспользуется — это и делает адрес у пира стабильным
    final second = await _engine(dir, 'A');
    await second.serve(host: '127.0.0.1', port: picked!);
    expect(second.port, picked, reason: 'заданный порт не переиспользован');
    await second.stop();

    // 3) порт занят чужой программой — движок встаёт на другом, а не падает
    final blocker = await ServerSocket.bind('127.0.0.1', 0);
    final third = await _engine(dir, 'A');
    await third.serve(host: '127.0.0.1', port: blocker.port);
    expect(third.port, isNotNull, reason: 'движок не поднялся на занятом порту');
    expect(third.port, isNot(blocker.port), reason: 'занятый порт не должен быть занят дважды');
    await third.stop();
    await blocker.close();

    await dir.delete(recursive: true);
  });
}
