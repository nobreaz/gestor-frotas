import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frota_core/frota_core.dart' show isValidEmail;
import 'package:project/core/components/app_button_variant.dart';
import 'package:project/core/components/auth_background.dart';
import 'package:project/core/components/auth_text_field.dart';
import 'package:project/core/components/password_requirements.dart';
import 'package:project/core/controllers/user_controller.dart';
import 'package:project/core/services/api_client.dart';
import 'package:project/core/theme/app_text_styles.dart';

/// "Esqueci minha senha", em dois passos na mesma tela:
/// 1. o usuário informa o e-mail e o Supabase envia um código;
/// 2. ele digita o código e a nova senha, e já entra no app.
///
/// Código em vez de link: funciona em qualquer aparelho (o e-mail pode ser
/// lido no computador) e não depende de o celular abrir o app pelo link.
class ResetPasswordPage extends StatefulWidget {
  const ResetPasswordPage({super.key});

  @override
  State<ResetPasswordPage> createState() => _ResetPasswordPageState();
}

class _ResetPasswordPageState extends State<ResetPasswordPage> {
  /// O Supabase só aceita um novo envio para o mesmo e-mail depois disso.
  static const _resendWait = 60;

  String email = '';
  String code = '';
  String newPassword = '';
  String confirmPassword = '';

  bool _codeSent = false;
  bool _loading = false;

  int _resendIn = 0;
  Timer? _resendTimer;

  @override
  void dispose() {
    _resendTimer?.cancel();
    super.dispose();
  }

  void _show(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    setState(() => _resendIn = _resendWait);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || _resendIn <= 1) {
        timer.cancel();
        if (mounted) setState(() => _resendIn = 0);
        return;
      }
      setState(() => _resendIn--);
    });
  }

  /// Passo 1 (e "Reenviar código").
  Future<void> _sendCode() async {
    if (_loading) return;
    if (!isValidEmail(email)) {
      _show('Informe um e-mail válido.');
      return;
    }

    setState(() => _loading = true);
    try {
      await UserController.instance.sendPasswordReset(email);
      if (!mounted) return;
      // Mesma mensagem exista ou não o e-mail: não revela quem tem cadastro.
      _show('Se o e-mail estiver cadastrado, você receberá um código.');
      setState(() => _codeSent = true);
      _startResendCountdown();
    } on ApiError catch (e) {
      _show(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Passo 2: confere o código, grava a nova senha e entra.
  Future<void> _reset() async {
    if (_loading) return;
    if (code.trim().length < 6) {
      _show('Informe o código recebido por e-mail.');
      return;
    }
    if (!PasswordRequirements.satisfied(newPassword, confirmPassword)) {
      _show('A nova senha não atende aos requisitos.');
      return;
    }

    setState(() => _loading = true);
    try {
      await UserController.instance.resetPasswordWithCode(
        email: email,
        code: code,
        newPassword: newPassword,
      );
      if (!mounted) return;
      _show('Senha redefinida.');
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
    } on ApiError catch (e) {
      _show(e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: AuthBackground(
        // No passo 2 há mais campos: a faixa azul encolhe para caber.
        topFlex: _codeSent ? 0.18 : 0.35,
        children: (context, dividerY) => [
          Positioned(
            top: dividerY + (119.10 / 2) - 20,
            left: 0,
            right: 0,
            bottom: 0,
            child: SingleChildScrollView(
              padding: const EdgeInsets.only(bottom: 24),
              child: Center(child: _codeSent ? _codeStep() : _emailStep()),
            ),
          ),
        ],
      ),
    );
  }

  Widget _emailStep() {
    return Column(
      children: [
        const Text(
          'Recuperar senha',
          textAlign: TextAlign.center,
          style: AppTextStyles.heading,
        ),
        const Text(
          'Digite seu e-mail para receber um código',
          textAlign: TextAlign.center,
          style: AppTextStyles.subtitle,
        ),
        const SizedBox(height: 20),
        AuthTextField(
          label: 'E-mail',
          icon: Icons.mail,
          keyboardType: TextInputType.emailAddress,
          onChanged: (text) => email = text,
        ),
        const SizedBox(height: 20),
        AppButton(
          label: _loading ? 'Enviando...' : 'Enviar código',
          onPressed: _sendCode,
        ),
        const SizedBox(height: 10),
        AppButton(
          variant: AppButtonVariant.cancel,
          label: 'Voltar',
          onPressed: () => Navigator.of(context).pushReplacementNamed('/'),
        ),
      ],
    );
  }

  Widget _codeStep() {
    return Column(
      children: [
        const Text(
          'Nova senha',
          textAlign: TextAlign.center,
          style: AppTextStyles.heading,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            'Digite o código enviado para ${email.trim()}',
            textAlign: TextAlign.center,
            style: AppTextStyles.subtitle,
          ),
        ),
        AuthTextField(
          label: 'Código',
          icon: Icons.pin_outlined,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(8),
          ],
          onChanged: (text) => code = text,
        ),
        AuthTextField(
          label: 'Nova senha',
          icon: Icons.lock,
          obscureable: true,
          onChanged: (text) => setState(() => newPassword = text),
        ),
        AuthTextField(
          label: 'Confirmar nova senha',
          icon: Icons.lock_outline,
          obscureable: true,
          onChanged: (text) => setState(() => confirmPassword = text),
        ),
        const SizedBox(height: 20),
        PasswordRequirements(
          password: newPassword,
          confirmation: confirmPassword,
        ),
        const SizedBox(height: 20),
        AppButton(
          label: _loading ? 'Salvando...' : 'Redefinir senha',
          onPressed: _reset,
        ),
        const SizedBox(height: 4),
        TextButton(
          onPressed: _resendIn > 0 || _loading ? null : _sendCode,
          child: Text(
            _resendIn > 0
                ? 'Reenviar código em ${_resendIn}s'
                : 'Reenviar código',
            style: AppTextStyles.link,
          ),
        ),
        AppButton(
          variant: AppButtonVariant.cancel,
          label: 'Voltar',
          onPressed: () => Navigator.of(context).pushReplacementNamed('/'),
        ),
      ],
    );
  }
}
