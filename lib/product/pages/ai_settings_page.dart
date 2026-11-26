import 'dart:async';

import 'package:flutter/material.dart';
import 'package:momentai/l10n/app_localization.dart';

import '../../core/ai/ai_models.dart';
import '../../core/ai/ai_provider.dart';
import '../../core/ai/ai_request.dart';
import '../ai_services.dart';
import '../product_theme.dart';

class AiSettingsPage extends StatefulWidget {
  const AiSettingsPage({super.key, required this.services});
  final AiServices services;
  @override
  State<AiSettingsPage> createState() => _AiSettingsPageState();
}

class _AiSettingsPageState extends State<AiSettingsPage> {
  AiCredentialCatalog _catalog = AiCredentialCatalog.empty();
  var _loading = true;
  var _busy = false;
  var _defaultsExpanded = false;
  String? _error;
  String? _notice;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await widget.services.credentials.read();
      if (mounted) setState(() => _catalog = value);
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotReadSecureStorageUnlockYour265,
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save(AiCredentialCatalog value, String notice) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await widget.services.credentials.save(value);
      if (mounted) {
        setState(() {
          _catalog = value;
          _notice = notice;
        });
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = error is AiFailure
              ? error.message
              : l10n.couldNotSaveTryAgain,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _edit([AiServiceCredentials? existing]) async {
    if (_busy) return;
    final result = await Navigator.of(context).push<AiServiceCredentials>(
      MaterialPageRoute(
        builder: (_) =>
            AiServiceEditorPage(services: widget.services, existing: existing),
      ),
    );
    if (!mounted || result == null) return;
    final nextServices = [
      for (final item in _catalog.services)
        if (item.service.id != result.service.id) item,
      result,
    ];
    final currentSummaryValid = _choiceExists(
      nextServices,
      _catalog.defaultSummaryServiceId,
      _catalog.defaultSummaryModelId,
    );
    final currentChatValid = _choiceExists(
      nextServices,
      _catalog.defaultChatServiceId,
      _catalog.defaultChatModelId,
    );
    final fallbackService = result.service.id;
    final fallbackModel = result.service.models.first.id;
    await _save(
      AiCredentialCatalog(
        services: nextServices,
        defaultSummaryServiceId: currentSummaryValid
            ? _catalog.defaultSummaryServiceId
            : fallbackService,
        defaultSummaryModelId: currentSummaryValid
            ? _catalog.defaultSummaryModelId
            : fallbackModel,
        defaultChatServiceId: currentChatValid
            ? _catalog.defaultChatServiceId
            : fallbackService,
        defaultChatModelId: currentChatValid
            ? _catalog.defaultChatModelId
            : fallbackModel,
        remoteProcessingConsentVersion: _catalog.remoteProcessingConsentVersion,
      ),
      existing == null ? l10n.modelServiceAdded : l10n.modelServiceUpdated,
    );
  }

  bool _choiceExists(
    List<AiServiceCredentials> services,
    String? serviceId,
    String? modelId,
  ) => services.any(
    (item) =>
        item.service.id == serviceId &&
        item.service.models.any((model) => model.id == modelId),
  );

  Future<void> _setDefault(AiRunKind kind, _ModelChoice choice) async {
    await _save(
      AiCredentialCatalog(
        services: _catalog.services,
        defaultSummaryServiceId: kind == AiRunKind.summary
            ? choice.serviceId
            : _catalog.defaultSummaryServiceId,
        defaultSummaryModelId: kind == AiRunKind.summary
            ? choice.model.id
            : _catalog.defaultSummaryModelId,
        defaultChatServiceId: kind == AiRunKind.chat
            ? choice.serviceId
            : _catalog.defaultChatServiceId,
        defaultChatModelId: kind == AiRunKind.chat
            ? choice.model.id
            : _catalog.defaultChatModelId,
        remoteProcessingConsentVersion: _catalog.remoteProcessingConsentVersion,
      ),
      kind == AiRunKind.summary
          ? l10n.defaultSummaryModelUpdated
          : l10n.defaultChatModelUpdated,
    );
  }

  Future<void> _deleteService(AiServiceCredentials target) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.delete((target.service.name).toString())),
        content: Text(l10n.deleteTheServiceSettingsAndApiKey),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            key: const Key('ai-confirm-delete-service'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.deleteService),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;
    final services = _catalog.services
        .where((item) => item.service.id != target.service.id)
        .toList();
    final first = services.firstOrNull;
    await _save(
      AiCredentialCatalog(
        services: services,
        defaultSummaryServiceId: first?.service.id,
        defaultSummaryModelId: first?.service.models.first.id,
        defaultChatServiceId: first?.service.id,
        defaultChatModelId: first?.service.models.first.id,
        remoteProcessingConsentVersion: _catalog.remoteProcessingConsentVersion,
      ),
      l10n.modelServiceAndLocalCredentialsDeleted,
    );
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final choices = [
      for (final item in _catalog.services)
        for (final model in item.service.models)
          _ModelChoice(item.service.id, item.service.name, model),
    ];
    String defaultName(String? serviceId, String? modelId) =>
        choices
            .where(
              (choice) =>
                  choice.serviceId == serviceId && choice.model.id == modelId,
            )
            .map((choice) => choice.model.name)
            .firstOrNull ??
        l10n.notSet;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(l10n.modelServices),
        bottom: const PreferredSize(
          preferredSize: Size.fromHeight(1),
          child: Divider(height: 1),
        ),
        actions: [
          IconButton(
            key: const Key('ai-add-service'),
            onPressed: _busy ? null : _edit,
            tooltip: l10n.addModelService,
            icon: const Icon(Icons.add_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  key: const Key('ai-settings-scroll'),
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
                  children: [
                    Container(
                      padding: const EdgeInsets.all(17),
                      decoration: BoxDecoration(
                        color: ProductColors.forestSoft,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _SettingsIntroIcon(),
                          SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  l10n.connectYourAiService,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                SizedBox(height: 5),
                                Text(
                                  l10n.keysAreSavedOnlyOnThisDevice,
                                  style: TextStyle(
                                    color: ProductColors.mutedInk,
                                    height: 1.45,
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    if (_catalog.services.isEmpty)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            children: [
                              const Icon(Icons.hub_outlined, size: 34),
                              const SizedBox(height: 10),
                              Text(l10n.noModelServicesYet),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                key: const Key('ai-add-first-service'),
                                onPressed: _busy ? null : _edit,
                                icon: const Icon(Icons.add_rounded),
                                label: Text(l10n.addService),
                              ),
                            ],
                          ),
                        ),
                      )
                    else ...[
                      Container(
                        padding: const EdgeInsets.fromLTRB(15, 14, 9, 14),
                        decoration: BoxDecoration(
                          color: ProductColors.surface,
                          borderRadius: BorderRadius.circular(17),
                          border: Border.all(color: ProductColors.line),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: _DefaultModelSummary(
                                label: l10n.aiSummary,
                                model: defaultName(
                                  _catalog.defaultSummaryServiceId,
                                  _catalog.defaultSummaryModelId,
                                ),
                              ),
                            ),
                            Expanded(
                              child: _DefaultModelSummary(
                                label: l10n.aiChat,
                                model: defaultName(
                                  _catalog.defaultChatServiceId,
                                  _catalog.defaultChatModelId,
                                ),
                              ),
                            ),
                            TextButton(
                              key: const Key('ai-change-defaults'),
                              onPressed: () => setState(
                                () => _defaultsExpanded = !_defaultsExpanded,
                              ),
                              child: Text(
                                _defaultsExpanded
                                    ? l10n.collapse
                                    : l10n.changeDefault,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (_defaultsExpanded) ...[
                        const SizedBox(height: 10),
                        Container(
                          padding: const EdgeInsets.fromLTRB(14, 14, 14, 2),
                          decoration: BoxDecoration(
                            color: ProductColors.surface,
                            borderRadius: BorderRadius.circular(17),
                            border: Border.all(color: ProductColors.line),
                          ),
                          child: Column(
                            children: [
                              _defaultDropdown(
                                label: l10n.aiSummary,
                                choices: choices,
                                selectedServiceId:
                                    _catalog.defaultSummaryServiceId,
                                selectedModelId: _catalog.defaultSummaryModelId,
                                onChanged: (choice) =>
                                    _setDefault(AiRunKind.summary, choice),
                              ),
                              const SizedBox(height: 12),
                              _defaultDropdown(
                                label: l10n.aiChat,
                                choices: choices,
                                selectedServiceId:
                                    _catalog.defaultChatServiceId,
                                selectedModelId: _catalog.defaultChatModelId,
                                onChanged: (choice) =>
                                    _setDefault(AiRunKind.chat, choice),
                              ),
                              const SizedBox(height: 12),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 22),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              l10n.connected,
                              style: TextStyle(
                                color: ProductColors.mutedInk,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          Text(
                            l10n.services(
                              (_catalog.services.length).toString(),
                            ),
                            style: const TextStyle(
                              color: ProductColors.mutedInk,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      for (final item in _catalog.services)
                        _ServiceCard(
                          credentials: item,
                          summaryDefault:
                              item.service.id ==
                              _catalog.defaultSummaryServiceId,
                          chatDefault:
                              item.service.id == _catalog.defaultChatServiceId,
                          onEdit: () => _edit(item),
                          onDelete: () => _deleteService(item),
                        ),
                      const SizedBox(height: 16),
                      OutlinedButton.icon(
                        onPressed: _busy ? null : _edit,
                        icon: const Icon(Icons.add_rounded),
                        label: Text(l10n.addModelService),
                      ),
                    ],
                    if (_busy) ...[
                      const SizedBox(height: 16),
                      const LinearProgressIndicator(),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _error!,
                          key: const Key('ai-settings-error'),
                          style: const TextStyle(
                            color: ProductColors.vermilion,
                          ),
                        ),
                      ),
                    if (_notice != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(
                          _notice!,
                          key: const Key('ai-settings-notice'),
                          style: const TextStyle(color: ProductColors.forest),
                        ),
                      ),
                    const SizedBox(height: 24),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 18,
                          color: ProductColors.mutedInk,
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.apiKeysUseSystemSecureStorageAnd,
                            style: TextStyle(
                              color: ProductColors.mutedInk,
                              height: 1.45,
                              fontSize: 11,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _defaultDropdown({
    required String label,
    required List<_ModelChoice> choices,
    required String? selectedServiceId,
    required String? selectedModelId,
    required ValueChanged<_ModelChoice> onChanged,
  }) {
    final selected = choices.firstWhere(
      (choice) =>
          choice.serviceId == selectedServiceId &&
          choice.model.id == selectedModelId,
      orElse: () => choices.first,
    );
    return DropdownButtonFormField<_ModelChoice>(
      key: ValueKey('$label-${selected.serviceId}-${selected.model.id}'),
      initialValue: selected,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: choices
          .map(
            (choice) => DropdownMenuItem(
              value: choice,
              child: Text(
                '${choice.serviceName} · ${choice.model.name}',
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(),
      onChanged: _busy ? null : (value) => onChanged(value!),
    );
  }
}

class _SettingsIntroIcon extends StatelessWidget {
  const _SettingsIntroIcon();

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        color: ProductColors.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Icon(
        Icons.bolt_rounded,
        color: ProductColors.forest,
        size: 22,
      ),
    );
  }
}

class _DefaultModelSummary extends StatelessWidget {
  const _DefaultModelSummary({required this.label, required this.model});

  final String label;
  final String model;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(color: ProductColors.mutedInk, fontSize: 10),
        ),
        const SizedBox(height: 4),
        Text(
          model,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
        ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.credentials,
    required this.summaryDefault,
    required this.chatDefault,
    required this.onEdit,
    required this.onDelete,
  });
  final AiServiceCredentials credentials;
  final bool summaryDefault;
  final bool chatDefault;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  Future<void> _showActions(BuildContext context) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: Text(l10n.editModelService),
                onTap: () => Navigator.pop(context, 'edit'),
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline_rounded,
                  color: ProductColors.vermilion,
                ),
                title: Text(
                  l10n.deleteModelService,
                  style: TextStyle(color: ProductColors.vermilion),
                ),
                onTap: () => Navigator.pop(context, 'delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == 'edit') {
      onEdit();
    } else if (action == 'delete') {
      onDelete();
    }
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final service = credentials.service;
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    final markColor = service.apiKind == AiApiKind.anthropic
        ? const Color(0xFFB96E45)
        : const Color(0xFF202622);
    final role = switch ((summaryDefault, chatDefault)) {
      (true, true) => l10n.defaultForSummariesAndChat,
      (true, false) => l10n.defaultForSummaries,
      (false, true) => l10n.defaultForChat,
      _ => '',
    };
    return Card(
      margin: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        key: Key('ai-service-${service.id}'),
        onTap: onEdit,
        onLongPress: () => _showActions(context),
        borderRadius: BorderRadius.circular(18),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: markColor,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Center(
                  child: Text(
                    service.name.trim().isEmpty
                        ? 'AI'
                        : service.name.trim().characters.first.toUpperCase(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      service.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            color: Color(0xFF49A16E),
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          l10n.connectedModels(
                            (service.models.length).toString(),
                          ),
                          style: const TextStyle(
                            color: ProductColors.mutedInk,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (role.isNotEmpty && !largeText)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: ProductColors.forestSoft,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    role,
                    style: const TextStyle(
                      color: ProductColors.forest,
                      fontSize: 9,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(width: 6),
              const Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: ProductColors.mutedInk,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AiServiceEditorPage extends StatefulWidget {
  const AiServiceEditorPage({super.key, required this.services, this.existing});
  final AiServices services;
  final AiServiceCredentials? existing;
  @override
  State<AiServiceEditorPage> createState() => _AiServiceEditorPageState();
}

class _AiServiceEditorPageState extends State<AiServiceEditorPage>
    with WidgetsBindingObserver {
  late final TextEditingController _name;
  late final TextEditingController _url;
  final _key = TextEditingController();
  late AiApiKind _kind;
  late List<AiModelProfile> _models;
  var _busy = false;
  String? _error;
  String? _notice;
  AiCancellation? _cancellation;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final existing = widget.existing;
    _name = TextEditingController(text: existing?.service.name ?? '');
    _url = TextEditingController(text: existing?.service.baseUrl ?? '');
    _kind = existing?.service.apiKind ?? AiApiKind.openAiCompatible;
    _models = [...?existing?.service.models];
  }

  AiServiceCredentials _draft() {
    if (_models.isEmpty) throw AiFailure(l10n.addAtLeastOneModel);
    final existing = widget.existing;
    final normalizedUrl = _url.text.trim().replaceAll(RegExp(r'/+$'), '');
    final destinationChanged =
        existing != null &&
        (existing.service.baseUrl != normalizedUrl ||
            existing.service.apiKind != _kind);
    var key = _key.text.trim();
    if (key.isEmpty && existing != null && !destinationChanged) {
      key = existing.apiKey;
    }
    if (destinationChanged && key.isEmpty) {
      throw AiFailure(l10n.theServiceAddressOrProtocolChangedEnter);
    }
    final service = AiServiceProfile(
      id: existing?.service.id ?? newAiId(),
      name: _name.text,
      apiKind: _kind,
      baseUrl: normalizedUrl,
      models: _models,
      revision: existing == null
          ? 1
          : existing.service.revision + (destinationChanged ? 1 : 0),
    );
    return AiServiceCredentials(service, key);
  }

  Future<void> _addOrEditModel([AiModelProfile? model]) async {
    final result = await Navigator.of(context).push<AiModelProfile>(
      MaterialPageRoute(
        builder: (_) => AiModelEditorPage(apiKind: _kind, existing: model),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _models = [
        for (final item in _models)
          if (item.id != result.id) item,
        result,
      ];
    });
  }

  Future<void> _test() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    final cancellation = AiCancellation();
    _cancellation = cancellation;
    try {
      final value = _draft();
      final model = value.service.models.first;
      final selected = AiCredentials(
        AiConfiguration.fromProfiles(value.service, model),
        value.apiKey,
      );
      var finished = false;
      await for (final event in widget.services.provider.generate(selected, [
        AiMessage('user', l10n.replyOnlyWithOk),
      ], cancellation)) {
        finished = finished || event.finished;
      }
      cancellation.check();
      if (!finished) throw AiFailure(l10n.theTestResponseDidNotFinish);
      _notice = l10n.connectionTestPassedOnlyAFixedTest;
    } catch (error) {
      _error = error is AiFailure
          ? error.message
          : l10n.connectionTestFailedCheckYourSettings;
    } finally {
      _cancellation = null;
      if (mounted) setState(() => _busy = false);
    }
  }

  void _finish() {
    try {
      Navigator.pop(context, _draft());
    } catch (error) {
      setState(
        () => _error = error is AiFailure
            ? error.message
            : l10n.invalidConfigurationCheckYourInput,
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _cancellation?.cancel();
    }
  }

  @override
  void dispose() {
    _cancellation?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _name.dispose();
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final largeText = MediaQuery.textScalerOf(context).scale(1) >= 1.5;
    return Scaffold(
      appBar: AppBar(
        centerTitle: true,
        title: Text(widget.existing?.service.name ?? l10n.addModelService),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('ai-service-editor-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(20, 12, 20, keyboard + 120),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(5, 10, 5, 18),
                child: Row(
                  children: [
                    Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: _kind == AiApiKind.anthropic
                            ? const Color(0xFFB96E45)
                            : const Color(0xFF202622),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Center(
                        child: Text(
                          _name.text.trim().isEmpty
                              ? 'AI'
                              : _name.text
                                    .trim()
                                    .characters
                                    .first
                                    .toUpperCase(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 13),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _name.text.trim().isEmpty
                                ? l10n.newModelService
                                : _name.text.trim(),
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.existing == null
                                ? l10n.enterConnectionDetailsToTestTheService
                                : l10n.savedOnThisDeviceYouCanTest,
                            style: const TextStyle(
                              color: ProductColors.mutedInk,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _EditorSectionHeading(
                        title: l10n.connectionDetails,
                        subtitle: l10n.usedToAccessTheModelService,
                        icon: Icons.key_rounded,
                      ),
                      const SizedBox(height: 15),
                      _textField(
                        _name,
                        l10n.serviceName,
                        l10n.forExampleOpenaiClaudeOrYourCompany,
                        'ai-service-name',
                      ),
                      DropdownButtonFormField<AiApiKind>(
                        key: const Key('ai-api-kind'),
                        initialValue: _kind,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l10n.apiProtocol,
                          border: OutlineInputBorder(),
                        ),
                        items: AiApiKind.values
                            .map(
                              (kind) => DropdownMenuItem(
                                value: kind,
                                child: Text(kind.label),
                              ),
                            )
                            .toList(),
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _kind = value!),
                      ),
                      const SizedBox(height: 16),
                      _textField(
                        _url,
                        l10n.httpsApiAddress,
                        _kind == AiApiKind.anthropic
                            ? l10n.forExampleHttpsApiAnthropicCom
                            : l10n.forExampleHttpsApiOpenaiComV,
                        'ai-base-url',
                      ),
                      TextField(
                        key: const Key('ai-api-key'),
                        controller: _key,
                        enabled: !_busy,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        enableIMEPersonalizedLearning: false,
                        maxLength: 8192,
                        decoration: InputDecoration(
                          labelText: 'API Key',
                          counterText: '',
                          helperText: widget.existing == null
                              ? l10n.savedOnlyInDeviceSecureStorage
                              : l10n.alreadySavedLeaveBlankToKeepIt,
                          helperMaxLines: 2,
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(15),
                  child: Column(
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: _EditorSectionHeading(
                              title: l10n.availableModels,
                              subtitle: l10n
                                  .chooseSeparateDefaultsForSummariesAndChat,
                              icon: Icons.memory_rounded,
                            ),
                          ),
                          TextButton.icon(
                            key: const Key('ai-add-model'),
                            onPressed: _busy ? null : _addOrEditModel,
                            icon: const Icon(Icons.add_rounded),
                            label: Text(l10n.addModel),
                          ),
                        ],
                      ),
                      if (_models.isEmpty)
                        Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Text(l10n.addAtLeastOneTextModelFor),
                        )
                      else
                        for (
                          var index = 0;
                          index < _models.length;
                          index++
                        ) ...[
                          ListTile(
                            key: Key('ai-model-${_models[index].id}'),
                            contentPadding: EdgeInsets.zero,
                            title: Text(_models[index].name),
                            subtitle: Text(_models[index].modelId),
                            onTap: _busy
                                ? null
                                : () => _addOrEditModel(_models[index]),
                            trailing: IconButton(
                              tooltip: l10n.deleteModel,
                              onPressed: _busy
                                  ? null
                                  : () => setState(
                                      () => _models.removeWhere(
                                        (item) => item.id == _models[index].id,
                                      ),
                                    ),
                              icon: const Icon(Icons.delete_outline_rounded),
                            ),
                          ),
                          if (index != _models.length - 1)
                            const Divider(height: 1),
                        ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.testConnectionSendsTheFixedMessageReply,
                style: TextStyle(color: ProductColors.mutedInk),
              ),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: LinearProgressIndicator(),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.fromLTRB(20, 10, 20, keyboard + 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    key: const Key('ai-editor-action-error'),
                    style: const TextStyle(color: ProductColors.vermilion),
                  ),
                ),
              if (_notice != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _notice!,
                    style: const TextStyle(color: ProductColors.forest),
                  ),
                ),
              if (largeText) ...[
                OutlinedButton(
                  key: const Key('ai-test-connection'),
                  onPressed: _busy ? null : _test,
                  child: Text(l10n.testConnection),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  key: const Key('ai-save-settings'),
                  onPressed: _busy ? null : _finish,
                  child: Text(l10n.saveService),
                ),
                if (_cancellation != null)
                  TextButton.icon(
                    onPressed: _cancellation!.cancel,
                    icon: const Icon(Icons.stop_circle_outlined),
                    label: Text(l10n.stopTest),
                  ),
              ] else
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        key: const Key('ai-test-connection'),
                        onPressed: _busy ? null : _test,
                        child: Text(l10n.testConnection),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        key: const Key('ai-save-settings'),
                        onPressed: _busy ? null : _finish,
                        child: Text(l10n.saveService),
                      ),
                    ),
                    if (_cancellation != null) ...[
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: l10n.stopTest,
                        onPressed: _cancellation!.cancel,
                        icon: const Icon(Icons.stop_circle_outlined),
                      ),
                    ],
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _textField(
    TextEditingController controller,
    String label,
    String helper,
    String key,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: Key(key),
      controller: controller,
      enabled: !_busy,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    ),
  );
}

class _EditorSectionHeading extends StatelessWidget {
  const _EditorSectionHeading({
    required this.title,
    required this.subtitle,
    required this.icon,
  });

  final String title;
  final String subtitle;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: ProductColors.mutedInk,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
        Icon(icon, color: ProductColors.mutedInk, size: 20),
      ],
    );
  }
}

class AiModelEditorPage extends StatefulWidget {
  const AiModelEditorPage({super.key, required this.apiKind, this.existing});
  final AiApiKind apiKind;
  final AiModelProfile? existing;
  @override
  State<AiModelEditorPage> createState() => _AiModelEditorPageState();
}

class _AiModelEditorPageState extends State<AiModelEditorPage> {
  late final TextEditingController _name;
  late final TextEditingController _modelId;
  late final TextEditingController _outputLimit;
  late String _parameter;
  late bool _usage;
  String? _error;

  @override
  void initState() {
    super.initState();
    final model = widget.existing;
    _name = TextEditingController(text: model?.name ?? '');
    _modelId = TextEditingController(text: model?.modelId ?? '');
    _outputLimit = TextEditingController(
      text:
          model?.outputTokenLimit?.toString() ??
          (widget.apiKind == AiApiKind.anthropic ? '8192' : ''),
    );
    _parameter = model?.tokenLimitParameter ?? 'max_tokens';
    _usage = model?.includeUsage ?? false;
  }

  void _save() {
    try {
      final outputValue = _outputLimit.text.trim();
      Navigator.pop(
        context,
        AiModelProfile(
          id: widget.existing?.id ?? newAiId(),
          name: _name.text,
          modelId: _modelId.text,
          outputTokenLimit: outputValue.isEmpty
              ? null
              : int.tryParse(outputValue) ?? 0,
          tokenLimitParameter: widget.apiKind == AiApiKind.anthropic
              ? 'max_tokens'
              : _parameter,
          includeUsage: widget.apiKind == AiApiKind.openAiCompatible && _usage,
        ),
      );
    } catch (error) {
      setState(
        () => _error = error is AiFailure
            ? error.message
            : l10n.invalidModelConfiguration,
      );
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _modelId.dispose();
    _outputLimit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    context.strings; // Rebuild when the application language changes.
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? l10n.addModel : l10n.editModel),
      ),
      body: SafeArea(
        child: ListView(
          key: const Key('ai-model-editor-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: EdgeInsets.fromLTRB(20, 12, 20, keyboard + 100),
          children: [
            _field(
              _name,
              l10n.displayName,
              l10n.forExampleGptOrClaudeSonnet,
              'ai-model-name',
            ),
            _field(
              _modelId,
              l10n.modelId,
              l10n.theExactModelValueRequiredByYour,
              'ai-model',
            ),
            const SizedBox(height: 8),
            Card(
              child: ExpansionTile(
                key: const Key('ai-model-advanced'),
                tilePadding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                title: Text(
                  l10n.compatibility,
                  style: TextStyle(fontWeight: FontWeight.w800),
                ),
                subtitle: Text(l10n.outputParametersAndTokenUsageTheComplete),
                children: [
                  _advancedNumberField(
                    _outputLimit,
                    l10n.responseTokenBudget,
                    widget.apiKind == AiApiKind.anthropic
                        ? l10n.requiredForAnthropicMessagesEnterAPositive
                        : l10n.optionalLeaveBlankToOmitTheOutput,
                    'ai-output-limit',
                  ),
                  if (widget.apiKind == AiApiKind.openAiCompatible) ...[
                    DropdownButtonFormField<String>(
                      initialValue: _parameter,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: l10n.parameterForCustomBudget,
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'max_tokens',
                          child: Text('max_tokens'),
                        ),
                        DropdownMenuItem(
                          value: 'max_completion_tokens',
                          child: Text('max_completion_tokens'),
                        ),
                      ],
                      onChanged: (value) => setState(() => _parameter = value!),
                    ),
                    const SizedBox(height: 14),
                    _ResponsiveSwitchSetting(
                      controlKey: const Key('ai-include-usage'),
                      title: l10n.showTokenUsage,
                      subtitle:
                          l10n.requestsStreamOptionsIncludeUsageWhenEnabled,
                      value: _usage,
                      onChanged: (value) => setState(() => _usage = value),
                    ),
                  ] else
                    Text(
                      l10n.anthropicMessagesUsesMaxTokensAndReads,
                      style: TextStyle(color: ProductColors.mutedInk),
                    ),
                ],
              ),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  _error!,
                  style: const TextStyle(color: ProductColors.vermilion),
                ),
              ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: AnimatedPadding(
          duration: const Duration(milliseconds: 160),
          padding: EdgeInsets.fromLTRB(20, 10, 20, keyboard + 12),
          child: FilledButton(
            key: const Key('ai-save-model'),
            onPressed: _save,
            child: Text(l10n.saveModel),
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label,
    String helper,
    String key, {
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: TextField(
      key: Key(key),
      controller: controller,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      autocorrect: false,
      enableSuggestions: false,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        border: const OutlineInputBorder(),
      ),
    ),
  );

  Widget _advancedNumberField(
    TextEditingController controller,
    String title,
    String helper,
    String key,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 6),
        TextField(
          key: Key(key),
          controller: controller,
          keyboardType: TextInputType.number,
          autocorrect: false,
          enableSuggestions: false,
          decoration: InputDecoration(
            hintText: l10n.useServiceDefault,
            suffixText: 'tokens',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          helper,
          style: const TextStyle(
            color: ProductColors.mutedInk,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    ),
  );
}

class _ResponsiveSwitchSetting extends StatelessWidget {
  const _ResponsiveSwitchSetting({
    required this.controlKey,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final Key controlKey;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scaler = MediaQuery.textScalerOf(context);
      final stacked = constraints.maxWidth < 300 || scaler.scale(14) > 19;
      final copy = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 3),
          Text(
            subtitle,
            style: const TextStyle(
              color: ProductColors.mutedInk,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ],
      );
      final control = Switch.adaptive(
        key: controlKey,
        value: value,
        onChanged: onChanged,
      );
      if (stacked) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            copy,
            Align(alignment: Alignment.centerRight, child: control),
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: copy),
          const SizedBox(width: 12),
          control,
        ],
      );
    },
  );
}

class _ModelChoice {
  const _ModelChoice(this.serviceId, this.serviceName, this.model);
  final String serviceId;
  final String serviceName;
  final AiModelProfile model;

  @override
  bool operator ==(Object other) =>
      other is _ModelChoice &&
      other.serviceId == serviceId &&
      other.model.id == model.id;

  @override
  int get hashCode => Object.hash(serviceId, model.id);
}
