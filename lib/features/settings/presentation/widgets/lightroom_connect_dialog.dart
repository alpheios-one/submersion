import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:submersion/core/services/cloud_storage/cloud_storage_provider.dart';
import 'package:submersion/core/services/lightroom/adobe_ims_auth_manager.dart';
import 'package:submersion/core/services/logger_service.dart';
import 'package:submersion/l10n/l10n_extension.dart';
import 'package:submersion/shared/utils/browser_launch.dart';

/// The paste-the-redirected-URL OAuth dialog: opens the Adobe IMS
/// authorize page in the system browser and exchanges the pasted URL (or
/// raw code). Pops `true` on success.
///
/// Copy link is always offered, not just after a failed launch: on Linux a
/// stale GIO scheme handler makes the launch report success and show nothing
/// (Debian 13), so there is no error state to hang the escape hatch off.
///
/// [openUri] is injectable for widget tests; production uses [openInBrowser].
class LightroomConnectDialog extends StatefulWidget {
  const LightroomConnectDialog({
    required this.authManager,
    required this.clientId,
    this.clientSecret,
    this.redirectUri,
    this.openUri,
    super.key,
  });

  final AdobeImsAuthManager authManager;
  final String clientId;
  final String? clientSecret;

  /// Per-credential redirect URI for BYO Native App credentials (which use an
  /// Adobe-generated custom scheme). Null falls back to the bundled web
  /// callback in [AdobeImsAuthManager.beginAuthorization].
  final String? redirectUri;
  final Future<bool> Function(Uri uri)? openUri;

  @override
  State<LightroomConnectDialog> createState() => _LightroomConnectDialogState();
}

class _LightroomConnectDialogState extends State<LightroomConnectDialog> {
  static final _log = LoggerService.forClass(LightroomConnectDialog);

  final _codeController = TextEditingController();
  Uri? _authorizeUri;
  String? _errorText;
  bool _linkCopied = false;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    // beginAuthorization generates the PKCE verifier; the same URI (and
    // verifier) is reused by "Reopen browser" so the pasted code always
    // matches the pending verifier.
    WidgetsBinding.instance.addPostFrameCallback((_) => _openBrowser());
  }

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  /// The pending authorize URI, generated on first use.
  ///
  /// The same URI is reused by Reopen browser and Copy link: a second
  /// [AdobeImsAuthManager.beginAuthorization] would replace the pending PKCE
  /// verifier, and the code from the page already open would then fail the
  /// exchange. Returns null after reporting an auth error inline.
  Uri? _pendingAuthorizeUri() {
    try {
      return _authorizeUri ??= widget.authManager.beginAuthorization(
        clientId: widget.clientId,
        clientSecret: widget.clientSecret,
        redirectUri: widget.redirectUri,
      );
    } on CloudStorageException catch (e) {
      if (mounted) setState(() => _errorText = e.displayMessage);
      return null;
    }
  }

  Future<void> _openBrowser() async {
    final uri = _pendingAuthorizeUri();
    if (uri == null) return;

    bool opened;
    try {
      opened = await (widget.openUri ?? openInBrowser)(uri);
    } catch (e) {
      // Off Linux, url_launcher reports "no handler" by throwing a raw
      // PlatformException. Its toString() named no action a diver could
      // take, so the failure reads the same either way and the detail goes
      // to the log.
      _log.warning('Could not open the Adobe authorize page: $e');
      opened = false;
    }
    // The dialog is barrier-dismissible; the open can outlive this State.
    if (!mounted) return;
    // launchUrl reports failure by returning false, not only by throwing.
    // A successful (re)open clears any stale error.
    setState(
      () => _errorText = opened
          ? null
          : context.l10n.settings_cloudSync_dropbox_connect_browserFailed,
    );
  }

  /// Copies the authorize URL so the user can open it by hand.
  Future<void> _copyLink() async {
    final uri = _pendingAuthorizeUri();
    if (uri == null) return;
    await Clipboard.setData(ClipboardData(text: uri.toString()));
    if (!mounted) return;
    setState(() {
      _linkCopied = true;
      // The user now has the link, so the launch failure is spent advice.
      _errorText = null;
    });
  }

  Future<void> _connect() async {
    final l10n = context.l10n;
    final input = _codeController.text.trim();
    if (input.isEmpty) {
      setState(() => _errorText = l10n.settings_lightroom_connect_emptyCode);
      return;
    }
    setState(() {
      _connecting = true;
      _errorText = null;
    });
    try {
      await widget.authManager.completeAuthorization(input);
      if (mounted) Navigator.of(context).pop(true);
    } on CloudStorageException catch (e) {
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _errorText = l10n.settings_lightroom_connect_failed(e.displayMessage);
      });
    } catch (e) {
      // The final store save can throw a raw PlatformException from the
      // keychain; without this catch the dialog wedges with _connecting
      // stuck true.
      if (!mounted) return;
      setState(() {
        _connecting = false;
        _errorText = l10n.settings_lightroom_connect_failed(e.toString());
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      // Scrollable so the copy-link row cannot push the code field off a
      // short window; the actions stay pinned below it.
      scrollable: true,
      title: Text(l10n.settings_lightroom_connect_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.settings_lightroom_connect_instructions),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              onPressed: _connecting ? null : _copyLink,
              icon: const Icon(Icons.link, size: 18),
              label: Text(l10n.settings_cloudSync_dropbox_connect_copyLink),
            ),
          ),
          if (_linkCopied)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                l10n.settings_cloudSync_dropbox_connect_linkCopied,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          TextField(
            controller: _codeController,
            autofocus: true,
            enabled: !_connecting,
            decoration: InputDecoration(
              labelText: l10n.settings_lightroom_connect_codeLabel,
              errorText: _errorText,
              errorMaxLines: 3,
            ),
            onSubmitted: (_) => _connect(),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _connecting ? null : _openBrowser,
          child: Text(l10n.settings_lightroom_connect_reopenBrowser),
        ),
        TextButton(
          onPressed: _connecting
              ? null
              : () => Navigator.of(context).pop(false),
          child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
        ),
        FilledButton(
          onPressed: _connecting ? null : _connect,
          child: _connecting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.settings_lightroom_connect_submit),
        ),
      ],
    );
  }
}
