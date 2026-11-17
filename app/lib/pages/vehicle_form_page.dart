import 'package:flutter/material.dart';
import 'package:frota_core/frota_core.dart'
    show
        formatDate,
        isOnlyLetters,
        isValidChassis,
        isValidPlate,
        isValidVehicleModel,
        normalizePlate;
import 'package:project/core/components/app_button_variant.dart';
import 'package:project/core/components/input_text_field.dart';
import 'package:project/core/controllers/request_controller.dart';
import 'package:project/core/controllers/vehicle_controller.dart';
import 'package:project/core/models/request_model.dart';
import 'package:project/core/models/vehicle_model.dart';
import 'package:project/core/services/api_client.dart';
import 'package:project/core/theme/app_colors.dart';
import 'package:project/core/theme/app_text_styles.dart';
import 'package:project/core/utils/input_formatters.dart';

/// Formulário de cadastro e edição de veículo.
/// Se [vehicle] for nulo, funciona como CADASTRO; caso contrário, EDIÇÃO.
class VehicleFormPage extends StatefulWidget {
  final VehicleModel? vehicle;

  const VehicleFormPage({super.key, this.vehicle});

  @override
  State<VehicleFormPage> createState() => _VehicleFormPageState();
}

class _VehicleFormPageState extends State<VehicleFormPage> {
  late String plate;
  late String chassis;
  late String model;
  late String color;
  late String year;
  late String seats;
  late String mileage;
  late String nextService;
  late VehicleType type;
  late VehicleStatus status;
  DateTime? licensingExpiry;
  DateTime? insuranceExpiry;

  bool _saving = false;
  Map<String, String> _errors = {};

  bool get isEditing => widget.vehicle != null;

  @override
  void initState() {
    super.initState();
    final v = widget.vehicle;
    plate = v == null ? '' : normalizePlate(v.plate);
    chassis = v?.chassis ?? '';
    model = v?.model ?? '';
    color = v?.color ?? '';
    year = v?.year.toString() ?? '';
    seats = v?.seats.toString() ?? '';
    mileage = v?.mileage.toString() ?? '';
    nextService = v?.nextServiceMileage?.toString() ?? '';
    type = v?.type ?? VehicleType.passeio;
    status = v?.status ?? VehicleStatus.disponivel;
    licensingExpiry = v?.licensingExpiry;
    insuranceExpiry = v?.insuranceExpiry;
  }

  String _pad(int v) => v.toString().padLeft(2, '0');

  String _fmtDate(DateTime? d) =>
      d == null ? '—' : '${_pad(d.day)}/${_pad(d.month)}';

  String _fmtFullDate(DateTime? d) =>
      d == null ? '' : '${_pad(d.day)}/${_pad(d.month)}/${d.year}';

  void _showMessage(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  /// Confirma a devolução das reservas afetadas para Pendente.
  Future<bool> _confirmRelease(
    List<RequestModel> bookings, {
    required bool becomesUnavailable,
  }) async {
    final reason = becomesUnavailable
        ? 'Com o status "${status.label}", estas reservas ficam sem veículo:'
        : 'Com menos lugares, estas reservas ficam sem veículo:';

    final result = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reservas afetadas'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reason, style: const TextStyle(fontSize: 13)),
              const SizedBox(height: 10),
              for (final r in bookings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.event,
                        size: 16,
                        color: AppColors.iconMuted,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '#${r.id} · ${r.destination} · '
                          '${_fmtDate(r.departure)} · '
                          '${r.passengers} passageiro(s)',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 6),
              const Text(
                'Elas voltarão para aprovação. Deseja continuar?',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Continuar',
              style: TextStyle(color: AppColors.rejected),
            ),
          ),
        ],
      ),
    );

    return result == true;
  }

  /// Confere o formato de cada campo. Devolve os erros por campo (mesmas
  /// chaves que a API usa em `campos`).
  Map<String, String> _validate() {
    final e = <String, String>{};
    final maxYear = DateTime.now().year + 1;

    if (plate.trim().isEmpty) {
      e['plate'] = 'Informe a placa.';
    } else if (!isValidPlate(plate)) {
      e['plate'] = 'Use o formato ABC-1234 ou ABC-1D23.';
    }
    if (model.trim().isEmpty) {
      e['model'] = 'Informe o modelo.';
    } else if (!isValidVehicleModel(model)) {
      e['model'] = 'Modelo inválido.';
    }
    if (chassis.trim().isEmpty) {
      e['chassis'] = 'Informe o chassi.';
    } else if (!isValidChassis(chassis)) {
      e['chassis'] = 'O chassi tem 17 caracteres.';
    }
    if (color.trim().isEmpty) {
      e['color'] = 'Informe a cor.';
    } else if (!isOnlyLetters(color)) {
      e['color'] = 'Use apenas letras.';
    }

    final y = int.tryParse(year);
    if (y == null) {
      e['year'] = 'Informe o ano.';
    } else if (y < 1950 || y > maxYear) {
      e['year'] = 'Informe um ano entre 1950 e $maxYear.';
    }
    final n = int.tryParse(seats);
    if (n == null) {
      e['seats'] = 'Informe a quantidade de lugares.';
    } else if (n < 1 || n > 99) {
      e['seats'] = 'Informe entre 1 e 99 lugares.';
    }
    if (int.tryParse(mileage) == null) {
      e['mileage'] = 'Informe a quilometragem.';
    }
    if (licensingExpiry == null) e['licensingExpiry'] = 'Selecione a data.';
    if (insuranceExpiry == null) e['insuranceExpiry'] = 'Selecione a data.';
    return e;
  }

  Future<void> _save() async {
    if (_saving) return;
    final errors = _validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      _showMessage('Verifique os campos destacados.');
      return;
    }

    final parsedYear = int.parse(year);
    final parsedSeats = int.parse(seats);
    final parsedMileage = int.parse(mileage);
    final parsedNextService = int.tryParse(nextService); // vazio apaga

    final data = <String, dynamic>{
      'plate': normalizePlate(plate),
      'chassis': chassis.trim(),
      'model': model.trim(),
      'color': color.trim(),
      'year': parsedYear,
      'seats': parsedSeats,
      'mileage': parsedMileage,
      'nextServiceMileage': parsedNextService,
      'type': type.name,
      'licensingExpiry': formatDate(licensingExpiry!),
      'insuranceExpiry': formatDate(insuranceExpiry!),
    };

    if (isEditing) {
      final vehicle = widget.vehicle!;
      final bookings = RequestController.instance.activeBookingsOf(vehicle.id);

      final becomesUnavailable =
          status != vehicle.status &&
          (status == VehicleStatus.emManutencao ||
              status == VehicleStatus.inativo);

      // Carro em viagem: não pode ir para manutenção/inativo agora.
      final inUse =
          vehicle.status == VehicleStatus.emUso ||
          bookings.any((r) => r.status == RequestStatus.emUso);
      if (status != vehicle.status && inUse) {
        _showMessage('O veículo está em uso. Registre a devolução primeiro.');
        return;
      }

      // Reservas aprovadas que o veículo deixará de atender.
      final approved = bookings.where(
        (r) => r.status == RequestStatus.aprovada,
      );
      final toRelease = becomesUnavailable
          ? approved.toList()
          : approved.where((r) => r.passengers > parsedSeats).toList();

      if (toRelease.isNotEmpty) {
        final confirmed = await _confirmRelease(
          toRelease,
          becomesUnavailable: becomesUnavailable,
        );
        if (!confirmed || !mounted) return;
      }

      // "Em uso" só muda pela retirada/devolução: o status só vai se mudou.
      if (status != vehicle.status) data['status'] = status.name;
    }

    setState(() => _saving = true);
    try {
      if (isEditing) {
        // Quem libera as reservas e avisa os solicitantes é o servidor.
        final released = await VehicleController.instance.updateVehicle(
          widget.vehicle!.id,
          data,
        );
        if (!mounted) return;
        _showMessage(
          released == 0
              ? 'Veículo atualizado.'
              : 'Veículo atualizado. $released reserva(s) voltaram para '
                    'aprovação.',
        );
      } else {
        await VehicleController.instance.addVehicle({
          ...data,
          'status': status.name,
        });
        if (!mounted) return;
        _showMessage('Veículo cadastrado.');
      }
      Navigator.of(context).pop();
    } on ApiError catch (e) {
      if (!mounted) return;
      setState(() => _errors = e.fields);
      _showMessage(e.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          isEditing ? 'Editar Veículo' : 'Cadastrar Veículo',
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(height: 20),
              InputTextField(
                label: 'Placa',
                hint: 'ABC-1D23',
                inputText: plate,
                inputFormatters: AppFormatters.plate,
                errorText: _errors['plate'],
                onChanged: (text) => plate = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Modelo',
                hint: 'Ex.: Toyota Corolla',
                inputText: model,
                inputFormatters: AppFormatters.vehicleModel,
                textCapitalization: TextCapitalization.words,
                errorText: _errors['model'],
                onChanged: (text) => model = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Chassi',
                hint: '17 letras e números',
                inputText: chassis,
                inputFormatters: AppFormatters.chassis,
                errorText: _errors['chassis'],
                onChanged: (text) => chassis = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Cor',
                hint: 'Ex.: Prata',
                inputText: color,
                inputFormatters: AppFormatters.letters,
                textCapitalization: TextCapitalization.words,
                errorText: _errors['color'],
                onChanged: (text) => color = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Ano',
                type: InputFieldType.number,
                hint: 'Ex.: 2022',
                inputText: year,
                inputFormatters: AppFormatters.digits(4),
                errorText: _errors['year'],
                onChanged: (text) => year = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Quantidade de lugares',
                type: InputFieldType.number,
                hint: 'Ex.: 5',
                inputText: seats,
                inputFormatters: AppFormatters.digits(2),
                errorText: _errors['seats'],
                onChanged: (text) => seats = text,
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Quilometragem',
                type: InputFieldType.number,
                hint: 'Ex.: 42500',
                inputText: mileage,
                inputFormatters: AppFormatters.digits(7),
                errorText: _errors['mileage'],
                onChanged: (text) => mileage = text,
              ),
              const SizedBox(height: 16),
              // Alerta nos Relatórios quando faltarem até 1.000 km.
              InputTextField(
                label: 'Km da próxima revisão (opcional)',
                type: InputFieldType.number,
                hint: 'Ex.: 50000',
                inputText: nextService,
                inputFormatters: AppFormatters.digits(7),
                errorText: _errors['nextServiceMileage'],
                onChanged: (text) => nextService = text,
              ),
              const SizedBox(height: 16),
              // Datas passadas são aceitas: o documento pode já estar vencido.
              InputTextField(
                label: 'Vencimento do licenciamento/IPVA',
                type: InputFieldType.date,
                hint: 'Selecione a data',
                inputText: _fmtFullDate(licensingExpiry),
                firstDate: DateTime(2000),
                errorText: _errors['licensingExpiry'],
                onChanged: (_) {},
                onDateSelected: (date) =>
                    setState(() => licensingExpiry = date),
              ),
              const SizedBox(height: 16),
              InputTextField(
                label: 'Vencimento do seguro',
                type: InputFieldType.date,
                hint: 'Selecione a data',
                inputText: _fmtFullDate(insuranceExpiry),
                firstDate: DateTime(2000),
                errorText: _errors['insuranceExpiry'],
                onChanged: (_) {},
                onDateSelected: (date) =>
                    setState(() => insuranceExpiry = date),
              ),
              const SizedBox(height: 20),
              _dropdown<VehicleType>(
                label: 'Tipo / categoria',
                value: type,
                items: VehicleType.values,
                labelBuilder: (t) => t.label,
                onChanged: (v) => setState(() => type = v),
              ),
              const SizedBox(height: 20),
              _dropdown<VehicleStatus>(
                label: 'Status operacional',
                value: status,
                // "Em uso" vem da retirada; só aparece se já for o status atual.
                items: [
                  for (final s in VehicleStatus.values)
                    if (s != VehicleStatus.emUso ||
                        widget.vehicle?.status == VehicleStatus.emUso)
                      s,
                ],
                labelBuilder: (s) => s.label,
                onChanged: (v) => setState(() => status = v),
              ),
              const SizedBox(height: 40),
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

  /// Campo de seleção com o mesmo visual dos InputTextField.
  Widget _dropdown<T>({
    required String label,
    required T value,
    required List<T> items,
    required String Function(T) labelBuilder,
    required ValueChanged<T> onChanged,
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
              items: items
                  .map(
                    (item) => DropdownMenuItem<T>(
                      value: item,
                      child: Text(
                        labelBuilder(item),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  )
                  .toList(),
              onChanged: (v) {
                if (v != null) onChanged(v);
              },
            ),
          ),
        ),
      ],
    );
  }
}
