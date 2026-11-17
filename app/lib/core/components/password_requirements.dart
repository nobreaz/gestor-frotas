import 'package:flutter/material.dart';
import 'package:frota_core/frota_core.dart' show PasswordRules;
import 'package:project/core/theme/app_colors.dart';

/// Requisitos da senha (regra 6.2, a mesma da API) com ✓ conforme o usuário
/// digita. Usado em "Alterar senha" e em "Esqueci minha senha".
class PasswordRequirements extends StatelessWidget {
  const PasswordRequirements({
    super.key,
    required this.password,
    required this.confirmation,
  });

  final String password;
  final String confirmation;

  /// A senha atende à regra 6.2 e a confirmação é igual.
  static bool satisfied(String password, String confirmation) =>
      PasswordRules(password).isValid && password == confirmation;

  @override
  Widget build(BuildContext context) {
    final rules = PasswordRules(password);
    final matches = password.isNotEmpty && password == confirmation;

    return Container(
      width: MediaQuery.of(context).size.width * 0.8,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'A nova senha precisa ter:',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: AppColors.textMuted,
            ),
          ),
          const SizedBox(height: 6),
          _rule(rules.hasMinLength, 'No mínimo 6 caracteres'),
          _rule(rules.hasNumber, 'Pelo menos 1 número'),
          _rule(
            rules.hasSpecial,
            'Pelo menos 1 caractere especial (ex.: @ # !)',
          ),
          _rule(matches, 'Confirmação igual à nova senha'),
        ],
      ),
    );
  }

  Widget _rule(bool ok, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 16,
            color: ok ? AppColors.approved : AppColors.iconMuted,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: ok ? Colors.black87 : AppColors.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
