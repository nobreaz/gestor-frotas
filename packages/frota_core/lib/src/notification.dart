/// Tipos de notificação.
/// - Ao solicitante: sent, approved, rejected, canceled, reverted, atRisk.
/// - Aos Aprovadores: pickupFailed e atRisk.
enum NotificationType {
  sent,
  approved,
  rejected,
  canceled,
  reverted,
  pickupFailed,
  atRisk,
}

extension NotificationTypeX on NotificationType {
  String get title {
    switch (this) {
      case NotificationType.sent:
        return 'Solicitação enviada';
      case NotificationType.approved:
        return 'Solicitação aprovada';
      case NotificationType.rejected:
        return 'Solicitação recusada';
      case NotificationType.canceled:
        return 'Solicitação cancelada';
      case NotificationType.reverted:
        return 'Voltou para aprovação';
      case NotificationType.pickupFailed:
        return 'Retirada não realizada';
      case NotificationType.atRisk:
        return 'Reserva em risco';
    }
  }
}

/// Notificação exibida dentro do app.
class AppNotification {
  final int id;
  final int userId; // destinatário
  final int requestId;
  final NotificationType type;
  final String destination;
  final String message;
  final DateTime createdAt;
  bool read;

  AppNotification({
    required this.id,
    required this.userId,
    required this.requestId,
    required this.type,
    required this.destination,
    required this.message,
    required this.createdAt,
    this.read = false,
  });

  /// Formato JSON trocado entre a API e o app (`createdAt` em ISO 8601 UTC).
  factory AppNotification.fromJson(Map<String, dynamic> json) =>
      AppNotification(
        id: json['id'] as int,
        userId: json['userId'] as int,
        requestId: json['requestId'] as int,
        type: NotificationType.values.byName(json['type'] as String),
        destination: json['destination'] as String,
        message: json['message'] as String,
        createdAt: DateTime.parse(json['createdAt'] as String).toLocal(),
        read: json['read'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
    'id': id,
    'userId': userId,
    'requestId': requestId,
    'type': type.name,
    'destination': destination,
    'message': message,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'read': read,
  };
}
