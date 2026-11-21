import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A dialog is a separate navigator overlay route, so it needs its own
/// selection scope rather than inheriting the page's scope.
Future<T?> showSelectableDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) => showDialog<T>(
  context: context,
  builder: (context) => SelectionArea(child: builder(context)),
);

/// Select values within a table without sending selection updates to an
/// offscreen nested scroll view elsewhere on the dashboard.
class SelectableHorizontalScrollView extends StatelessWidget {
  const SelectableHorizontalScrollView({required this.child, super.key});
  final Widget child;

  @override
  Widget build(BuildContext context) => SelectionContainer.disabled(
    child: SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: SelectionArea(child: child),
    ),
  );
}

Future<void> copyAppText(BuildContext context, String text) async {
  try {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard.'),
        duration: Duration(seconds: 2),
      ),
    );
  } catch (error) {
    if (!context.mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: SelectableText('Could not copy to clipboard: $error')),
    );
  }
}

class CopyErrorButton extends StatelessWidget {
  const CopyErrorButton(this.message, {super.key});
  final String message;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: 'Copy error',
    visualDensity: VisualDensity.compact,
    icon: const Icon(Icons.copy_outlined, size: 18),
    onPressed: () => copyAppText(context, message),
  );
}

/// Errors remain independently selectable, including in dialogs or views that
/// are embedded outside the main app's global selection area.
class CopyableError extends StatelessWidget {
  const CopyableError(this.message, {this.style, super.key});
  final String message;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: SelectableText(
          message,
          style: style ?? TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ),
      CopyErrorButton(message),
    ],
  );
}

SnackBar copyableErrorSnackBar(BuildContext context, String message) =>
    SnackBar(
      content: SelectionArea(child: Text(message)),
      duration: const Duration(seconds: 12),
      action: SnackBarAction(
        label: 'Copy error',
        onPressed: () => copyAppText(context, message),
      ),
    );
