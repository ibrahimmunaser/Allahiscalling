import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/salah_prayer.dart';
import '../state/app_controller.dart';
import '../utils/app_strings.dart';

/// Asks "Did you complete [Prayer]?" after the user chooses Pray Now.
///
/// - Yes: saves the completion locally, cancels the pending missed-prayer
///   follow-up, and shows a gentle confirmation.
/// - Not Yet: closes quietly; the follow-up reminder stays scheduled so the
///   user is reminded again while the prayer window is still open.
Future<void> showPrayerCompletionPrompt(
    BuildContext context, SalahPrayer prayer) async {
  final controller = context.read<AppController>();
  final completed = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(AppStrings.didYouComplete(prayer.displayName)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text(AppStrings.completionNotYet),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text(AppStrings.completionYes),
        ),
      ],
    ),
  );

  if (completed == true) {
    await controller.markPrayerCompleted(prayer);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text(AppStrings.mayAllahAccept)),
      );
    }
  }
}
