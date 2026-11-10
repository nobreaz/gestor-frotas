/// Regra 6.2: mínimo de 6 caracteres, 1 número e 1 caractere especial.
/// Usada na tela de troca de senha (app) e no cadastro de usuário (API).
class PasswordRules {
  const PasswordRules(this.password);

  final String password;

  static const minLength = 6;

  bool get hasMinLength => password.length >= minLength;
  bool get hasNumber => RegExp('[0-9]').hasMatch(password);
  bool get hasSpecial => RegExp(r'[^A-Za-z0-9\s]').hasMatch(password);

  bool get isValid => hasMinLength && hasNumber && hasSpecial;
}

/// Formato básico de e-mail (algo@algo.algo). Quem confirma que ele
/// existe de verdade é o Supabase Auth.
bool isValidEmail(String email) =>
    RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email.trim());

// ---------------------------------------------------------------------------
// Formatos dos campos digitados. O app usa para validar antes de enviar e a
// API confere de novo (o app pode estar desatualizado).
// ---------------------------------------------------------------------------

/// Letras (com acento), espaço e `' . -`. Para nomes, cargo, setor, cor.
final _onlyLetters = RegExp(r"^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ '.\-]*$");

/// Destino: letras e os separadores de endereço `, / ( )`.
final _place = RegExp(r"^[A-Za-zÀ-ÖØ-öø-ÿ][A-Za-zÀ-ÖØ-öø-ÿ '.,/()\-]*$");

/// Modelo de veículo: letras, números e `. -` (ex.: "Fiat Argo 1.0").
final _vehicleModel = RegExp(
  r'^[A-Za-zÀ-ÖØ-öø-ÿ0-9][A-Za-zÀ-ÖØ-öø-ÿ0-9 .\-]*$',
);

bool isOnlyLetters(String value) => _onlyLetters.hasMatch(value.trim());

bool isValidPlace(String value) => _place.hasMatch(value.trim());

bool isValidVehicleModel(String value) => _vehicleModel.hasMatch(value.trim());

/// Placa antiga (ABC-1234) ou Mercosul (ABC-1D23), com ou sem hífen.
bool isValidPlate(String value) =>
    RegExp(r'^[A-Z]{3}-?[0-9][A-Z0-9][0-9]{2}$')
        .hasMatch(value.replaceAll(RegExp(r'\s'), '').toUpperCase());

/// Placa no formato guardado e exibido: maiúsculas e com hífen (ABC-1D23).
String normalizePlate(String value) {
  final raw = value.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  return raw.length > 3 ? '${raw.substring(0, 3)}-${raw.substring(3)}' : raw;
}

/// Chassi (VIN): 17 letras/números, sem I, O e Q.
bool isValidChassis(String value) =>
    RegExp(r'^[A-HJ-NPR-Z0-9]{17}$').hasMatch(value.trim().toUpperCase());

/// Número da CNH (registro): 11 dígitos.
bool isValidCnhNumber(String value) =>
    RegExp(r'^[0-9]{11}$').hasMatch(value.trim());

/// Telefone com DDD, fixo ou celular: (22) 2222-2222 ou (22) 99999-0000.
/// Também aceita só o ramal (3 a 5 dígitos).
bool isValidPhone(String value) {
  final digits = value.replaceAll(RegExp('[^0-9]'), '');
  if (digits != value.replaceAll(RegExp(r'[\s()\-]'), '')) return false;
  return (digits.length >= 3 && digits.length <= 5) ||
      digits.length == 10 ||
      digits.length == 11;
}
