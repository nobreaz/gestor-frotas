import 'package:flutter/services.dart';

/// Filtros de digitação dos campos: o teclado só aceita o que o campo
/// permite. O formato final é conferido de novo ao salvar (frota_core) e
/// pela API.
abstract final class AppFormatters {
  static const _letters = 'A-Za-zÀ-ÖØ-öø-ÿ';

  /// Nomes, cargo, setor e cor.
  static final letters = [
    FilteringTextInputFormatter.allow(RegExp("[$_letters '.\\-]")),
    LengthLimitingTextInputFormatter(80),
  ];

  /// Destino: letras e `, / ( )`.
  static final place = [
    FilteringTextInputFormatter.allow(RegExp("[$_letters '.,/()\\-]")),
    LengthLimitingTextInputFormatter(120),
  ];

  /// Modelo do veículo: letras, números, ponto e hífen.
  static final vehicleModel = [
    FilteringTextInputFormatter.allow(RegExp('[${_letters}0-9 .\\-]')),
    LengthLimitingTextInputFormatter(60),
  ];

  /// Texto livre (motivo, observações, justificativa): só limita o tamanho.
  static List<TextInputFormatter> freeText([int max = 300]) => [
    LengthLimitingTextInputFormatter(max),
  ];

  /// Só números, com no máximo [max] dígitos.
  static List<TextInputFormatter> digits(int max) => [
    FilteringTextInputFormatter.digitsOnly,
    LengthLimitingTextInputFormatter(max),
  ];

  /// Chassi: 17 letras/números em maiúsculas, sem I, O e Q.
  static final chassis = [
    FilteringTextInputFormatter.allow(RegExp('[A-HJ-NPR-Za-hj-npr-z0-9]')),
    _UpperCaseFormatter(),
    LengthLimitingTextInputFormatter(17),
  ];

  static final plate = [PlateInputFormatter()];

  static final phone = [PhoneInputFormatter()];
}

class _UpperCaseFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) => newValue.copyWith(text: newValue.text.toUpperCase());
}

/// Valor com o cursor no fim (os campos mascarados são curtos).
TextEditingValue _atEnd(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

/// Placa: ABC-1234 ou ABC-1D23. Maiúsculas e hífen automáticos; cada
/// posição só aceita o tipo certo (3 letras, número, letra ou número,
/// 2 números).
class PlateInputFormatter extends TextInputFormatter {
  static final _letter = RegExp('[A-Z]');
  static final _digit = RegExp('[0-9]');
  static final _alnum = RegExp('[A-Z0-9]');

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final chars = newValue.text.toUpperCase().replaceAll(
      RegExp('[^A-Z0-9]'),
      '',
    );
    final out = StringBuffer();
    for (final c in chars.split('')) {
      final pos = out.length;
      if (pos >= 7) break;
      final pattern = pos < 3
          ? _letter
          : pos == 4
          ? _alnum
          : _digit;
      if (pattern.hasMatch(c)) out.write(c);
    }
    final raw = out.toString();
    return _atEnd(
      raw.length > 3 ? '${raw.substring(0, 3)}-${raw.substring(3)}' : raw,
    );
  }
}

/// Telefone: (22) 99999-0000 ou (22) 2222-2222. Até 5 dígitos fica sem
/// máscara, para aceitar só o ramal.
class PhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    var digits = newValue.text.replaceAll(RegExp('[^0-9]'), '');
    if (digits.length > 11) digits = digits.substring(0, 11);

    // Apagando um símbolo da máscara: apaga o dígito antes dele.
    final oldDigits = oldValue.text.replaceAll(RegExp('[^0-9]'), '');
    if (newValue.text.length < oldValue.text.length &&
        digits == oldDigits &&
        digits.isNotEmpty) {
      digits = digits.substring(0, digits.length - 1);
    }

    return _atEnd(formatPhone(digits));
  }

  static String formatPhone(String digits) {
    if (digits.length <= 5) return digits;
    final ddd = digits.substring(0, 2);
    final rest = digits.substring(2);
    if (rest.length <= 4) return '($ddd) $rest';
    final split = digits.length == 11 ? 5 : 4;
    if (rest.length <= split) return '($ddd) $rest';
    return '($ddd) ${rest.substring(0, split)}-${rest.substring(split)}';
  }
}
