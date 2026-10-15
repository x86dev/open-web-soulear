import 'package:flutter/material.dart';

import '../src/app_controller.dart';

class DeviceTab extends StatefulWidget {
  const DeviceTab({super.key, required this.controller});
  final AppController controller;

  @override
  State<DeviceTab> createState() => _DeviceTabState();
}

class _DeviceTabState extends State<DeviceTab> {
  late final _ip = TextEditingController(text: widget.controller.cameraIp);

  @override
  void initState() {
    super.initState();
    // Follow IP changes from the controller (e.g. a driver's default IP after
    // switching the driver). Do not fight the user while they are typing.
    widget.controller.addListener(_syncIp);
  }

  void _syncIp() {
    final ip = widget.controller.cameraIp;
    if (_ip.text != ip) _ip.text = ip;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncIp);
    _ip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(padding: const EdgeInsets.all(16), children: [
      ValueListenableBuilder(
        valueListenable: widget.controller.status,
        builder: (context, s, _) {
          if (s.details.isEmpty) return Text('Keine Geräteangaben – Kamera nicht verbunden.', style: text.bodyMedium);
          return Wrap(spacing: 24, runSpacing: 12, children: [
            if (s.details.isNotEmpty)
              SizedBox(
                width: 140,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Treiber', style: text.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  Text(widget.controller.driver == 'auto' ? 'auto' : widget.controller.driver, style: text.bodyMedium),
                ]),
              ),
            for (final e in s.details.entries)
              SizedBox(
                width: 140,
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(e.key, style: text.labelSmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  Text(e.value, style: text.bodyMedium),
                ]),
              ),
          ]);
        },
      ),
      const SizedBox(height: 24),
      Text('KAMERA-TYP', style: text.labelSmall),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: widget.controller.driver,
        isExpanded: true,
        decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
        onChanged: (v) { if (v != null) widget.controller.setDriver(v); },
        items: const [
          DropdownMenuItem(value: 'auto', child: Text('Automatisch (Soulear / AIR-Look)')),
          DropdownMenuItem(value: 'soulear', child: Text('Soulear / Suear')),
          DropdownMenuItem(value: 'airlook', child: Text('AIR-Look')),
        ],
      ),
      const SizedBox(height: 24),
      Text('VERBINDUNG', style: text.labelSmall),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: TextField(
            controller: _ip,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Kamera-IP', border: OutlineInputBorder(), isDense: true),
            onSubmitted: widget.controller.setCameraIp,
          ),
        ),
        const SizedBox(width: 8),
        FilledButton.tonal(onPressed: () => widget.controller.setCameraIp(_ip.text), child: const Text('Verbinden')),
      ]),
      const SizedBox(height: 8),
      Text(
          'Handy vorher mit dem WLAN der Kamera verbinden. Standard-IP für '
          'diesen Kamera-Typ: ${AppController.defaultIpFor(widget.controller.driver)}',
          style: text.bodySmall),
    ]);
  }
}
