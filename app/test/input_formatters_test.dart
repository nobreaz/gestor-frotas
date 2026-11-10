import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:project/core/utils/input_formatters.dart';

/// Simula digitar [typed] de uma vez no campo vazio.
String _type(TextInputFormatter f, String typed) => f
    .formatEditUpdate(TextEditingValue.empty, TextEditingValue(text: typed))
    .text;

void main() {
  group('Placa', () {
    final f = PlateInputFormatter();

    test('maiúsculas e hífen automáticos', () {
      expect(_type(f, 'abc1d23'), 'ABC-1D23');
      expect(_type(f, 'abc1234'), 'ABC-1234');
      expect(_type(f, 'ab'), 'AB');
    });

    test('cada posição só aceita o tipo certo', () {
      expect(_type(f, '1abc'), 'ABC'); // número no início é ignorado
      expect(_type(f, 'abcd1'), 'ABC-1'); // 4ª letra ignorada
      expect(_type(f, 'abc1d2345'), 'ABC-1D23'); // no máximo 7
    });
  });

  group('Telefone', () {
    final f = PhoneInputFormatter();

    test('celular, fixo e ramal', () {
      expect(_type(f, '22999990000'), '(22) 99999-0000');
      expect(_type(f, '2222222222'), '(22) 2222-2222');
      expect(_type(f, '2345'), '2345');
      expect(_type(f, '(22) 9a9'), '2299'); // letras saem
    });

    test('apagar o último dígito tira o hífen', () {
      const before = TextEditingValue(text: '(22) 2222-2');
      final after = f.formatEditUpdate(
        before,
        const TextEditingValue(text: '(22) 2222-'),
      );
      expect(after.text, '(22) 2222');
    });
  });
}
