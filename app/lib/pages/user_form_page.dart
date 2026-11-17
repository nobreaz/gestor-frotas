import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:frota_core/frota_core.dart'
    show
        PasswordRules,
        formatDate,
        isOnlyLetters,
        isValidCnhNumber,
        isValidEmail,
        isValidPhone;
import 'package:project/core/components/app_button_variant.dart';
import 'package:project/core/components/input_text_field.dart';
import 'package:project/core/controllers/user_controller.dart';
import 'package:project/core/models/user_model.dart';
import 'package:project/core/services/api_client.dart';
import 'package:project/core/theme/app_colors.dart';
import 'package:project/core/theme/app_text_styles.dart';
import 'package:project/core/utils/input_formatters.dart';

/// Cadastro (RF 3.1.3) e edição de usuário, feitos pelo Aprovador.
/// Se [user] for nulo, funciona como CADASTRO; caso contrário, EDIÇÃO.
///
/// No cadastro o Aprovador define uma senha inicial (regra 6.2), que o
/// colaborador pode trocar depois em Configurações → Alterar senha.
class UserFormPage extends StatefulWidget {
  final UserModel? user;

  const UserFormPage({super.key, this.user});

  @override
  State<UserFormPage> createState() => _UserFormPageState();
}

class _UserFormPageState extends State<UserFormPage> {
  static const _cnhCategories = [
    'A',
    'B',
    'AB',
    'C',
    'D',
    'E',
    'AC',
    'AD',
    'AE',
  ];

  late String name;
  late String email;
  late String phone;
  late String role;
  late String department;
  late String cnhNumber;
  String? cnhCategory;
  DateTime? cnhExpiry;
  late UserProfile profile;
  String password = '';

  bool _saving = false;
  Map<String, String> _errors = {};

  bool get isEditing => widget.user != null;

  /// O Aprovador não pode rebaixar o próprio perfil (a API também barra).
  bool get _isSelf => widget.user?.id == UserController.instance.currentUser.id;

  @override
  void initState() {
    super.initState();
    final u = widget.user;
    name = u?.name ?? '';
    email = u?.email ?? '';
    phone = PhoneInputFormatter.formatPhone(
      (u?.phone ?? '').replaceAll(RegExp('[^0-9]'), ''),
    );
    role = u?.role ?? '';
    department = u?.department ?? '';
    cnhNumber = u?.cnhNumber ?? '';
    cnhCategory = u?.cnhCategory;
    cnhExpiry = u?.cnhExpiry;
    profile = u?.profile ?? UserProfile.padrao;
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  String _fmtDate(DateTime? d) =>
      d == null ? '' : '${_pad(d.day)}/${_pad(d.month)}/${d.year}';

  void _show(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Confere o formato de cada campo (mesmas chaves que a API usa).
  Map<String, String> _validate() {
    final e = <String, String>{};
    void letters(String key, String value, String label) {
      if (value.trim().isEmpty) {
        e[key] = 'Informe $label.';
      } else if (!isOnlyLetters(value)) {
        e[key] = 'Use apenas letras.';
      }
    }

    letters('name', name, 'o nome');
    letters('role', role, 'o cargo');
    letters('department', department, 'o setor');
    if (!isEditing && !isValidEmail(email)) e['email'] = 'E-mail inválido.';
    if (phone.isNotEmpty && !isValidPhone(phone)) {
      e['phone'] = 'Use (22) 99999-0000 ou o ramal.';
    }
    if (cnhNumber.isNotEmpty && !isValidCnhNumber(cnhNumber)) {
      e['cnhNumber'] = 'A CNH tem 11 números.';
    }
    if (!isEditing && !PasswordRules(password).isValid) {
      e['password'] = 'A senha não atende aos requisitos.';
    }
    return e;
  }

  Future<void> _save() async {
    if (_saving) return;

    final errors = _validate();
    if (errors.isNotEmpty) {
      setState(() => _errors = errors);
      _show('Verifique os campos destacados.');
      return;
    }

    final data = <String, dynamic>{
      'name': name.trim(),
      'phone': phone,
      'role': role.trim(),
      'department': department.trim(),
      'cnhNumber': cnhNumber,
      'cnhCategory': cnhCategory,
      'cnhExpiry': cnhExpiry == null ? null : formatDate(cnhExpiry!),
      'profile': profile.name,
      if (!isEditing) ...{'email': email.trim(), 'password': password},
    };

    setState(() {
      _saving = true;
      _errors = {};
    });
    try {
      if (isEditing) {
        await UserController.instance.updateUser(widget.user!.id, data);
        _show('Usuário atualizado.');
      } else {
        await UserController.instance.createUser(data);
        _show('Usuário cadastrado.');
      }
      if (mounted) Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _errors = e.fields);
      _show(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rules = PasswordRules(password);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditing ? 'Editar Usuário' : 'Cadastrar Usuário',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
        ),
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
      ),
      backgroundColor: AppColors.background,
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        // Largura total: sem isso a coluna encolhe e os campos ficam à esquerda.
        child: SizedBox(
          width: double.infinity,
          child: Column(
            children: [
              const SizedBox(height: 10),
              _field(
                'name',
                InputTextField(
                  label: 'Nome completo',
                  hint: 'Ex.: Ana Ribeiro',
                  inputText: name,
                  inputFormatters: AppFormatters.letters,
                  textCapitalization: TextCapitalization.words,
                  onChanged: (t) => name = t,
                ),
              ),
              if (isEditing)
                _readOnly('E-mail (login)', email)
              else
                _field(
                  'email',
                  InputTextField(
                    label: 'E-mail (login)',
                    hint: 'nome.sobrenome@empresa.com',
                    keyboardType: TextInputType.emailAddress,
                    inputText: email,
                    inputFormatters: [
                      FilteringTextInputFormatter.deny(RegExp(r'\s')),
                      LengthLimitingTextInputFormatter(120),
                    ],
                    onChanged: (t) => email = t,
                  ),
                ),
              _field(
                'phone',
                InputTextField(
                  label: 'Telefone / ramal (opcional)',
                  hint: 'Ex.: (22) 99999-0000',
                  keyboardType: TextInputType.phone,
                  inputText: phone,
                  inputFormatters: AppFormatters.phone,
                  onChanged: (t) => phone = t,
                ),
              ),
              _field(
                'role',
                InputTextField(
                  label: 'Cargo',
                  hint: 'Ex.: Técnica de Campo',
                  inputText: role,
                  inputFormatters: AppFormatters.letters,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (t) => role = t,
                ),
              ),
              _field(
                'department',
                InputTextField(
                  label: 'Setor',
                  hint: 'Ex.: Operações',
                  inputText: department,
                  inputFormatters: AppFormatters.letters,
                  textCapitalization: TextCapitalization.sentences,
                  onChanged: (t) => department = t,
                ),
              ),
              _field(
                'cnhNumber',
                InputTextField(
                  label: 'Nº da CNH',
                  type: InputFieldType.number,
                  hint: '11 números (obrigatória para o perfil Padrão)',
                  inputText: cnhNumber,
                  inputFormatters: AppFormatters.digits(11),
                  onChanged: (t) => cnhNumber = t,
                ),
              ),
              const SizedBox(height: 10),
              _dropdown<String?>(
                label: 'Categoria da CNH',
                value: cnhCategory,
                items: [null, ..._cnhCategories],
                labelBuilder: (c) => c ?? 'Não informada',
                onChanged: (v) => setState(() => cnhCategory = v),
              ),
              _field(
                'cnhExpiry',
                InputTextField(
                  label: 'Validade da CNH',
                  type: InputFieldType.date,
                  hint: 'Selecione a data',
                  inputText: _fmtDate(cnhExpiry),
                  firstDate: DateTime(2000),
                  onChanged: (_) {},
                  onDateSelected: (d) => setState(() => cnhExpiry = d),
                ),
              ),
              const SizedBox(height: 10),
              _dropdown<UserProfile>(
                label: 'Perfil de acesso',
                value: profile,
                items: UserProfile.values,
                labelBuilder: (p) => p.label,
                enabled: !_isSelf,
                onChanged: (v) => setState(() => profile = v),
              ),
              if (_isSelf)
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: _hint('Você não pode alterar o próprio perfil.'),
                ),
              if (!isEditing) ...[
                _field(
                  'password',
                  InputTextField(
                    label: 'Senha inicial',
                    type: InputFieldType.password,
                    inputText: password,
                    onChanged: (t) => setState(() => password = t),
                  ),
                ),
                SizedBox(
                  width: MediaQuery.of(context).size.width * 0.8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _rule(
                        'Mínimo de ${PasswordRules.minLength} caracteres',
                        rules.hasMinLength,
                      ),
                      _rule('Pelo menos 1 número', rules.hasNumber),
                      _rule(
                        'Pelo menos 1 caractere especial',
                        rules.hasSpecial,
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 32),
              AppButton(
                label: _saving
                    ? 'Salvando...'
                    : (isEditing ? 'Salvar alterações' : 'Cadastrar'),
                onPressed: _save,
              ),
              const SizedBox(height: 10),
              AppButton(
                variant: AppButtonVariant.cancel,
                label: 'Cancelar',
                onPressed: () => Navigator.of(context).pop(),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  /// Campo + mensagem de erro (quando houver).
  Widget _field(String key, Widget field) {
    final error = _errors[key];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        field,
        // Mesma largura do campo, para não deslocar a coluna.
        if (error != null)
          Container(
            width: MediaQuery.of(context).size.width * 0.8,
            padding: const EdgeInsets.only(left: 8, top: 4),
            child: Text(
              error,
              style: const TextStyle(
                color: AppColors.rejected,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
      ],
    );
  }

  Widget _readOnly(String label, String value) {
    return SizedBox(
      width: MediaQuery.of(context).size.width * 0.8,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 10),
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: Text(label, style: AppTextStyles.actionLabel),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textMuted,
              ),
            ),
          ),
          _hint('O e-mail é o login e não pode ser alterado.'),
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Text(
        text,
        style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
      ),
    );
  }

  Widget _rule(String text, bool ok) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, top: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle : Icons.radio_button_unchecked,
            size: 14,
            color: ok ? AppColors.approved : AppColors.iconMuted,
          ),
          const SizedBox(width: 6),
          Text(text, style: const TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  /// Campo de seleção com o mesmo visual dos InputTextField.
  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onChanged,
    bool enabled = true,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Text(label, style: AppTextStyles.actionLabel),
        ),
        Container(
          width: MediaQuery.of(context).size.width * 0.8,
          margin: const EdgeInsets.only(top: 8),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: ShapeDecoration(
            color: AppColors.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            shadows: const [
              BoxShadow(
                color: AppColors.shadow,
                blurRadius: 4,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<T>(
              value: value,
              isExpanded: true,
              items: [
                for (final item in items)
                  DropdownMenuItem<T>(
                    value: item,
                    child: Text(
                      labelBuilder(item),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
              onChanged: enabled ? (v) => onChanged(v as T) : null,
            ),
          ),
        ),
      ],
    );
  }
}
