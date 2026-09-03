// SPDX-License-Identifier: AGPL-3.0
//
// Theme settings — mode, presets, custom HSL picker, live preview.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/theme_prefs.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/branded_app_bar.dart';

class ThemeSettingsScreen extends ConsumerStatefulWidget {
  const ThemeSettingsScreen({super.key});

  @override
  ConsumerState<ThemeSettingsScreen> createState() => _ThemeSettingsScreenState();
}

class _ThemeSettingsScreenState extends ConsumerState<ThemeSettingsScreen> {
  bool _customOpen = false;
  double _hue = 190;
  double _saturation = 0.55;
  double _lightness = 0.35;
  double _accentHue = 38;
  bool _pickAccent = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final t = ref.read(themeControllerProvider);
      if (t.presetId == 'custom') {
        setState(() {
          _customOpen = true;
          _loadFromColor(t.seed, t.accent);
        });
      }
    });
  }

  void _loadFromColor(Color seed, Color accent) {
    final hsl = HSLColor.fromColor(seed);
    _hue = hsl.hue;
    _saturation = hsl.saturation;
    _lightness = hsl.lightness;
    _accentHue = HSLColor.fromColor(accent).hue;
  }

  Color get _draftSeed {
    return clampSeedLightness(
      HSLColor.fromAHSL(1, _hue, _saturation, _lightness).toColor(),
    );
  }

  Color get _draftAccent {
    if (_pickAccent) {
      return nudgeAccentForContrast(
        HSLColor.fromAHSL(1, _accentHue, 0.72, 0.58).toColor(),
        _draftSeed,
      );
    }
    return nudgeAccentForContrast(deriveAccentFromSeed(_draftSeed), _draftSeed);
  }

  String _presetLabel(AppLocalizations l10n, String id) {
    switch (id) {
      case 'signal':
        return l10n.themePresetSignal;
      case 'saffron':
        return l10n.themePresetSaffron;
      case 'indigo':
        return l10n.themePresetIndigo;
      case 'forest':
        return l10n.themePresetForest;
      case 'plum':
        return l10n.themePresetPlum;
      case 'graphite':
        return l10n.themePresetGraphite;
      default:
        return id;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final themeState = ref.watch(themeControllerProvider);
    final ctrl = ref.read(themeControllerProvider.notifier);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: BrandedAppBar(
        title: l10n.themeSettings,
        subtitle: l10n.themeSettingsSubtitle,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(l10n.themeMode, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: [
              ButtonSegment(
                value: ThemeMode.system,
                label: Text(l10n.themeModeSystem),
                icon: const Icon(Icons.brightness_auto, size: 18),
              ),
              ButtonSegment(
                value: ThemeMode.light,
                label: Text(l10n.themeModeLight),
                icon: const Icon(Icons.light_mode, size: 18),
              ),
              ButtonSegment(
                value: ThemeMode.dark,
                label: Text(l10n.themeModeDark),
                icon: const Icon(Icons.dark_mode, size: 18),
              ),
            ],
            selected: {themeState.mode},
            onSelectionChanged: (s) => ctrl.setMode(s.first),
          ),
          const SizedBox(height: 24),
          Text(l10n.themePresets, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final p in kThemePresets)
                _PresetSwatch(
                  label: _presetLabel(l10n, p.id),
                  seed: p.seed,
                  accent: p.accent,
                  selected: themeState.presetId == p.id,
                  onTap: () => ctrl.applyPreset(p),
                ),
              _PresetSwatch(
                label: l10n.themeCustom,
                seed: themeState.presetId == 'custom'
                    ? themeState.seed
                    : _draftSeed,
                accent: themeState.presetId == 'custom'
                    ? themeState.accent
                    : _draftAccent,
                selected: themeState.presetId == 'custom' || _customOpen,
                onTap: () => setState(() => _customOpen = !_customOpen),
                dashed: true,
              ),
            ],
          ),
          if (_customOpen) ...[
            const SizedBox(height: 16),
            Text(l10n.themeCustomHint,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            _SliderRow(
              label: l10n.themeHue,
              value: _hue,
              max: 360,
              onChanged: (v) => setState(() => _hue = v),
            ),
            _SliderRow(
              label: l10n.themeSaturation,
              value: _saturation * 100,
              max: 100,
              onChanged: (v) => setState(() => _saturation = v / 100),
            ),
            _SliderRow(
              label: l10n.themeLightness,
              value: _lightness * 100,
              min: 25,
              max: 60,
              onChanged: (v) => setState(() => _lightness = v / 100),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.themePickAccent),
              value: _pickAccent,
              onChanged: (v) => setState(() => _pickAccent = v),
            ),
            if (_pickAccent)
              _SliderRow(
                label: l10n.themeAccentHue,
                value: _accentHue,
                max: 360,
                onChanged: (v) => setState(() => _accentHue = v),
              ),
            FilledButton(
              onPressed: () => ctrl.applyCustom(
                seed: _draftSeed,
                accent: _draftAccent,
              ),
              child: Text(l10n.themeApplyCustom),
            ),
          ],
          const SizedBox(height: 24),
          Text(l10n.themePreview, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 10),
          _ThemePreviewCard(
            seed: themeState.presetId == 'custom' && _customOpen
                ? _draftSeed
                : themeState.seed,
            accent: themeState.presetId == 'custom' && _customOpen
                ? _draftAccent
                : themeState.accent,
            animate: !reduceMotion,
            l10n: l10n,
          ),
          const SizedBox(height: 24),
          OutlinedButton.icon(
            onPressed: () => ctrl.resetToDefault(),
            icon: const Icon(Icons.restore),
            label: Text(l10n.themeReset),
          ),
        ],
      ),
    );
  }
}

class _PresetSwatch extends StatelessWidget {
  const _PresetSwatch({
    required this.label,
    required this.seed,
    required this.accent,
    required this.selected,
    required this.onTap,
    this.dashed = false,
  });

  final String label;
  final Color seed;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          width: 104,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Row(
                children: [
                  _Dot(color: seed, dashed: dashed),
                  const SizedBox(width: 6),
                  _Dot(color: accent),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.color, this.dashed = false});

  final Color color;
  final bool dashed;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: dashed ? null : color,
        shape: BoxShape.circle,
        border: dashed
            ? Border.all(color: color, width: 2, strokeAlign: BorderSide.strokeAlignInside)
            : null,
      ),
      child: dashed
          ? Center(
              child: Icon(Icons.add, size: 16, color: color),
            )
          : null,
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 100,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label ${value.round()}'),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          onChanged: onChanged,
        ),
      ],
    );
  }
}

class _ThemePreviewCard extends StatelessWidget {
  const _ThemePreviewCard({
    required this.seed,
    required this.accent,
    required this.animate,
    required this.l10n,
  });

  final Color seed;
  final Color accent;
  final bool animate;
  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final light = buildTalkTheme(
      seed: seed,
      accent: accent,
      brightness: Brightness.light,
    );
    final cs = light.colorScheme;

    final card = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cs.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: cs.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 18,
                backgroundColor: cs.primaryContainer,
                child: Icon(Icons.person, color: cs.onPrimaryContainer, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      height: 10,
                      width: 120,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 8,
                      width: 180,
                      decoration: BoxDecoration(
                        color: cs.onSurface.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Material(
            color: cs.tertiary,
            borderRadius: BorderRadius.circular(20),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.mic, color: cs.onTertiary),
                  const SizedBox(width: 8),
                  Text(
                    l10n.themePreviewAiCta,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: cs.onTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    if (!animate) return card;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.94, end: 1),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, scale, child) {
        return Opacity(
          opacity: 0.4 + (scale - 0.94) / 0.06 * 0.6,
          child: Transform.scale(scale: scale, child: child),
        );
      },
      child: card,
    );
  }
}
