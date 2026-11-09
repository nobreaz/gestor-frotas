import 'package:frota_server/src/api_exception.dart';
import 'package:mocktail/mocktail.dart';
import 'package:test/test.dart';

import '../../routes/me/dispositivos.dart' as route;
import '../helpers.dart';

void main() {
  late MockDispositivosRepository devices;
  final ana = user(id: 3);

  setUp(() {
    devices = MockDispositivosRepository();
    when(
      () => devices.register(any(), any(), platform: any(named: 'platform')),
    ).thenAnswer((_) async {});
    when(() => devices.unregister(any(), any())).thenAnswer((_) async {});
  });

  Future<int> call(String method, Map<String, Object?> body) async {
    final response = await route.onRequest(
      contextFor(
        jsonRequest(method, '/me/dispositivos', body),
        me: ana,
        devices: devices,
      ),
    );
    return response.statusCode;
  }

  test('POST registra o token do usuário logado → 204', () async {
    expect(await call('POST', {'token': ' abc '}), 204);
    // ignore: avoid_redundant_argument_values
    verify(() => devices.register(3, 'abc', platform: 'android')).called(1);
  });

  test('DELETE remove o token do usuário logado → 204', () async {
    expect(await call('DELETE', {'token': 'abc'}), 204);
    verify(() => devices.unregister(3, 'abc')).called(1);
  });

  test('sem token → 400; outro método → 405', () {
    expect(
      () => call('POST', {'platform': 'android'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 400)),
    );
    expect(
      () => call('PATCH', {'token': 'abc'}),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 's', 405)),
    );
  });
}
