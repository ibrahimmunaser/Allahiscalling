import 'package:intl/intl.dart';

final DateFormat _timeFormat = DateFormat('h:mm a');
final DateFormat _dateTimeFormat = DateFormat('EEE, MMM d • h:mm a');
final DateFormat _dateFormat = DateFormat('EEE, MMM d');

String formatTime(DateTime time) => _timeFormat.format(time);

String formatDateTime(DateTime time) => _dateTimeFormat.format(time);

String formatDate(DateTime time) => _dateFormat.format(time);

/// "2h 14m" style countdown; shows seconds under a minute.
String formatCountdown(Duration duration) {
  if (duration.isNegative) return 'now';
  final hours = duration.inHours;
  final minutes = duration.inMinutes % 60;
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${duration.inSeconds}s';
}
