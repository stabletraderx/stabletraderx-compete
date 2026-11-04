import 'package:flutter/material.dart';

import '../api/api_client.dart';
import '../config.dart';
import '../main.dart';

/// Settings: report an issue (insert-only `reports` table via RLS), and delete
/// account (the `delete-account` edge function, preserve-on-delete).
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({
    super.key,
    required this.api,
    required this.username,
    required this.onLoggedOut,
  });

  final ApiClient api;
  final String username;
  final VoidCallback onLoggedOut;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _busy = false;

  String get _me => widget.api.userAddress ?? '';

  Future<void> _reportIssue() async {
    final ctrl = TextEditingController();
    final msg = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Report an issue'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLines: 4,
          maxLength: 500,
          decoration: const InputDecoration(hintText: 'What went wrong?'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Submit'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (msg == null || msg.isEmpty) return;

    setState(() => _busy = true);
    try {
      await widget.api.restPost('/reports', {
        'user_id': _me,
        'message': msg,
        'status': 'new',
      }, returning: false);
      _toast('Thanks — your report was sent.');
    } catch (e) {
      _toast('Could not send: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete account?'),
        content: const Text(
            'This permanently deletes your profile, picks, and credentials. '
            'Challenges you created are preserved for the other players, with '
            'your identity detached. This cannot be undone.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = true);
    try {
      await widget.api.edgePost(AppConfig.deleteAccountUrl, body: {});
      widget.onLoggedOut();
    } catch (e) {
      _toast('Delete failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: AppColors.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.line),
            ),
            child: ListTile(
              title: const Text('Signed in as'),
              subtitle: Text(widget.username),
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            leading: const Icon(Icons.flag_outlined),
            title: const Text('Report an issue'),
            subtitle: const Text('Send feedback to the team',
                style: TextStyle(color: AppColors.dim)),
            onTap: _busy ? null : _reportIssue,
          ),
          const Divider(color: AppColors.line),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined,
                color: AppColors.red),
            title: const Text('Delete account',
                style: TextStyle(color: AppColors.red)),
            subtitle: const Text('Permanent — removes your data',
                style: TextStyle(color: AppColors.dim)),
            onTap: _busy ? null : _deleteAccount,
          ),
        ],
      ),
    );
  }
}