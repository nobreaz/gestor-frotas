import 'package:flutter/material.dart';
import 'package:project/core/models/request_model.dart';
import 'package:project/core/theme/app_colors.dart';

/// Card do aprovador: exibe os detalhes completos da solicitação
/// e as ações de aprovar / recusar.
class PendingRequestCard extends StatelessWidget {
  final RequestModel request;
  final VoidCallback onApprove;
  final VoidCallback onReject;

  const PendingRequestCard({
    super.key,
    required this.request,
    required this.onApprove,
    required this.onReject,
  });

  String _pad(int v) => v.toString().padLeft(2, '0');

  String _fmtDateTime(DateTime? d) => d == null
      ? '—'
      : '${_pad(d.day)}/${_pad(d.month)}/${d.year} ${_pad(d.hour)}:${_pad(d.minute)}';

  String _fmtDate(DateTime? d) =>
      d == null ? '—' : '${_pad(d.day)}/${_pad(d.month)}/${d.year}';

  /// Ex.: "10/10/2026 · Manhã (até 12h)".
  String _fmtReturn() {
    final period = request.returnPeriod;
    final date = _fmtDate(request.returnDate);
    if (period == null) return date;
    return '$date · ${period.label} (${period.description})';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: ShapeDecoration(
        color: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        shadows: const [
          BoxShadow(
            color: AppColors.shadow,
            blurRadius: 4,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cabeçalho: solicitante + número
          Row(
            children: [
              const CircleAvatar(
                radius: 20,
                backgroundColor: AppColors.background,
                child: Icon(Icons.person, color: AppColors.primary, size: 22),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      request.requester,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Text(
                      'Solicitante',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '#${request.id}',
                style: const TextStyle(
                  fontSize: 11,
                  color: AppColors.textMuted,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const Divider(height: 22),

          if (request.needsReallocation) ...[
            _urgentBanner(),
            const SizedBox(height: 12),
          ],

          Text(
            'Viagem a ${request.destination}',
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),

          _detail('Motivo', request.reason),
          const SizedBox(height: 6),
          _detail('Passageiros', '${request.passengers}'),
          const SizedBox(height: 6),
          _detail('Saída', _fmtDateTime(request.departure)),
          const SizedBox(height: 6),
          _detail('Retorno', _fmtReturn()),

          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text(
                    'Aprovar',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.approved,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close, size: 18),
                  label: const Text(
                    'Recusar',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.rejected,
                    side: const BorderSide(color: AppColors.rejected),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Retirada falhou: o solicitante está esperando outro veículo.
  Widget _urgentBanner() {
    final reason = request.pickupFailureReason;
    final notes = request.pickupFailureNotes;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.rejected.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.rejected.withValues(alpha: 0.5)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.car_crash_outlined,
            size: 18,
            color: AppColors.rejected,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'URGENTE · Retirada não realizada',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: AppColors.rejected,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    ?reason?.label,
                    ?notes,
                  ].join(' · ').ifEmpty('Motivo não informado'),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Aloque outro veículo (o anterior não aparece na lista).',
                  style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppColors.textMuted,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}

extension on String {
  String ifEmpty(String fallback) => isEmpty ? fallback : this;
}
