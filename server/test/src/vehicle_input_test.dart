import 'package:frota_server/src/api_exception.dart';
import 'package:frota_server/src/vehicle_input.dart';
import 'package:test/test.dart';

void main() {
  final body = {
    'plate': 'ABC1D23',
    'chassis': '9BWZZZ377VT004251',
    'model': 'Gol',
    'color': 'Branco',
    'year': 2022,
    'seats': 5,
    'mileage': 1000,
    'licensingExpiry': '2027-03-31',
    'insuranceExpiry': '2027-06-10',
  };

  test('km da próxima revisão é opcional no cadastro', () {
    expect(parseNewVehicle(body).nextServiceMileage, isNull);
    expect(
      parseNewVehicle({...body, 'nextServiceMileage': 10000})
          .nextServiceMileage,
      10000,
    );
  });

  test('placa: ABC-1234 ou Mercosul, gravada com hífen', () {
    expect(parseNewVehicle({...body, 'plate': 'abc1234'}).plate, 'ABC-1234');
    expect(parseVehicleUpdate({'plate': 'abc-1d23'}), {'placa': 'ABC-1D23'});
    for (final bad in ['AB1234', 'ABCD123', 'ABC12345', '1BC1234']) {
      expect(
        () => parseVehicleUpdate({'plate': bad}),
        throwsA(
          isA<ApiException>().having((e) => e.fields?.keys, 'campos', [
            'plate',
          ]),
        ),
        reason: bad,
      );
    }
  });

  test('chassi com 17 caracteres e cor só com letras', () {
    expect(
      () => parseNewVehicle({...body, 'chassis': '9BW123', 'color': 'Azul 2'}),
      throwsA(
        isA<ApiException>().having(
          (e) => e.fields?.keys.toSet(),
          'campos',
          {'chassis', 'color'},
        ),
      ),
    );
  });

  test('PATCH com null apaga a revisão; texto é recusado', () {
    expect(parseVehicleUpdate({'nextServiceMileage': null}), {
      'proxima_revisao_km': null,
    });
    expect(
      () => parseVehicleUpdate({'nextServiceMileage': 'muito'}),
      throwsA(isA<ApiException>()),
    );
  });
}
