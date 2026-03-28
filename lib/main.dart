import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.sleepwell.audio',
    androidNotificationChannelName: 'SleepWell Playback',
    androidNotificationOngoing: true,
  );
  runApp(const SleepWellApp());
}

class SleepWellApp extends StatefulWidget {
  const SleepWellApp({super.key, this.enableAudio = true});

  final bool enableAudio;

  @override
  State<SleepWellApp> createState() => _SleepWellAppState();
}

class _SleepWellAppState extends State<SleepWellApp> {
  late final SleepWellState _state;

  @override
  void initState() {
    super.initState();
    _state = SleepWellState(enableAudio: widget.enableAudio);
    _state.bootstrap();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SleepWell',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0B1020),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF7C88FF),
          secondary: Color(0xFF68D3FF),
          surface: Color(0xFF151C34),
        ),
        useMaterial3: true,
      ),
      home: AnimatedBuilder(
        animation: _state,
        builder: (_, __) {
          if (!_state.isOnboarded) {
            return OnboardingScreen(state: _state);
          }
          return HomeScreen(state: _state);
        },
      ),
    );
  }
}

class SleepWellState extends ChangeNotifier {
  SleepWellState({
    SleepWellApi? api,
    bool enableAudio = true,
  })  : _api = api ?? SleepWellApi(),
        _enableAudio = enableAudio;

  final SleepWellApi _api;
  final bool _enableAudio;
  final AudioPlayer _player = AudioPlayer();
  final Map<String, AudioPlayer> _mixerPlayers = <String, AudioPlayer>{};
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Timer? _sleepTimer;

  bool isBootstrapping = true;
  bool isBusy = false;
  bool apiConnected = false;
  String? lastError;
  final String deviceId = SleepWellApi.defaultDeviceId;

  bool isOnboarded = false;
  bool prefersTalking = false;
  int sleepDifficulty = 3;
  final List<String> preferredCategories = <String>[];
  final List<String> preferredSoundTypes = <String>[];
  final List<SleepSession> sessions = <SleepSession>[];
  final Map<String, double> mixer = <String, double>{
    'Rain': 0.7,
    'Wind': 0.3,
    'White Noise': 0.5,
  };
  bool isMixerPlaying = false;
  List<MixPreset> mixerPresets = <MixPreset>[];

  bool isPlaying = false;
  bool enableMixerInSleepNow = true;
  bool loop = true;
  int sleepTimerMinutes = 30;
  Duration currentPosition = Duration.zero;
  Duration currentDuration = Duration.zero;
  SleepTrack? selectedTrack;
  int? _activeSessionId;
  DateTime? _sessionStartedAt;
  SleepInsights insights = const SleepInsights(
    usageFrequencyLast7Days: 0,
    consistencyScore: 0,
    averageDurationMinutes: 0,
  );

  List<SleepTrack> tracks = <SleepTrack>[
    const SleepTrack(
      title: 'Moonlight Whispers',
      category: 'whisper',
      talking: true,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'Forest Rain Deep Sleep',
      category: 'rain',
      talking: false,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'No Talking Brown Noise',
      category: 'no_talking',
      talking: false,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'Night Spa Roleplay',
      category: 'roleplay',
      talking: true,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
  ];

  Future<void> bootstrap() async {
    isBootstrapping = true;
    notifyListeners();
    await _configureAudio();
    await fetchCatalog();
    await refreshInsights();
    await refreshMixPresets();
    isBootstrapping = false;
    notifyListeners();
  }

  Future<void> fetchCatalog() async {
    try {
      final catalog = await _api.fetchCatalog();
      if (catalog.isNotEmpty) {
        tracks = catalog;
      }
      apiConnected = true;
      lastError = null;
    } catch (_) {
      // Keep local seed tracks when API is unavailable.
      apiConnected = false;
      lastError = 'Using offline catalog';
    }
    notifyListeners();
  }

  Future<void> completeOnboarding({
    required bool talking,
    required int difficulty,
    required List<String> categories,
    required List<String> soundTypes,
  }) async {
    isBusy = true;
    prefersTalking = talking;
    sleepDifficulty = difficulty;
    preferredCategories
      ..clear()
      ..addAll(categories);
    preferredSoundTypes
      ..clear()
      ..addAll(soundTypes);
    isOnboarded = true;
    notifyListeners();

    try {
      await _api.submitOnboarding(
        deviceId: deviceId,
        talking: talking,
        difficulty: difficulty,
        categories: categories,
        soundTypes: soundTypes,
      );
      apiConnected = true;
      lastError = null;
    } catch (_) {
      apiConnected = false;
      lastError = 'Onboarding saved locally. API unavailable.';
    }
    isBusy = false;
    notifyListeners();
  }

  Future<void> startSleepNow() async {
    if (isBusy) {
      return;
    }
    isBusy = true;
    notifyListeners();

    try {
      final sequence = await _api.fetchSleepNowSequence(deviceId: deviceId);
      final picked = sequence.isEmpty ? tracks : sequence;
      selectedTrack = picked[Random().nextInt(picked.length)];
      apiConnected = true;
      lastError = null;
    } catch (_) {
      final filtered = tracks.where((t) {
        final matchesTalking = t.talking == prefersTalking;
        final matchesCategory =
            preferredCategories.isEmpty || preferredCategories.contains(t.category);
        return matchesTalking && matchesCategory;
      }).toList();
      final picked = filtered.isEmpty ? tracks : filtered;
      selectedTrack = picked[Random().nextInt(picked.length)];
      apiConnected = false;
      lastError = 'Running Sleep Now in offline mode.';
    }

    await _startSession(mode: 'sleep_now', entryPoint: 'sleep_now_button');
    await _playSelectedTrack();
    if (enableMixerInSleepNow && !isMixerPlaying) {
      await toggleMixerPlayback();
    }
    sessions.add(SleepSession(DateTime.now(), 0));
    isBusy = false;
    notifyListeners();
  }

  Future<void> playTrack(SleepTrack track) async {
    await _cancelSleepTimer();
    selectedTrack = track;
    sessions.add(SleepSession(DateTime.now(), 0));
    await _startSession(mode: 'player', entryPoint: 'player_track_tap');
    await _playSelectedTrack();
    await _logEvent('play');
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    await _fadeOutAndStop();
    if (isMixerPlaying) {
      await toggleMixerPlayback();
    }
    isPlaying = false;
    await _cancelSleepTimer();
    currentPosition = Duration.zero;
    final endedAt = DateTime.now();
    if (_activeSessionId != null) {
      try {
        await _api.endSession(
          sessionId: _activeSessionId!,
          status: 'completed',
          endedAt: endedAt,
        );
        apiConnected = true;
      } catch (_) {
        apiConnected = false;
      }
    }
    if (sessions.isNotEmpty) {
      final current = sessions.removeLast();
      final computedMinutes = _sessionStartedAt == null
          ? sleepTimerMinutes
          : max(
              1,
              endedAt.difference(_sessionStartedAt!).inMinutes,
            );
      sessions.add(current.copyWith(durationMinutes: computedMinutes));
    }
    _activeSessionId = null;
    _sessionStartedAt = null;
    await refreshInsights();
    notifyListeners();
  }

  void updateMixer(String key, double value) {
    mixer[key] = value;
    if (_enableAudio && isMixerPlaying) {
      unawaited(_mixerPlayers[key]?.setVolume(value));
    }
    notifyListeners();
  }

  Future<void> toggleMixerPlayback() async {
    if (!_enableAudio) {
      isMixerPlaying = !isMixerPlaying;
      notifyListeners();
      return;
    }

    if (isMixerPlaying) {
      for (final player in _mixerPlayers.values) {
        await player.pause();
      }
      isMixerPlaying = false;
      await _logEvent('mixer_stop');
      notifyListeners();
      return;
    }

    for (final entry in mixer.entries) {
      final channel = entry.key;
      final volume = entry.value;
      final player = _mixerPlayers[channel];
      if (player == null) {
        continue;
      }

      if (player.audioSource == null) {
        final url = _mixerChannelUrls[channel] ?? _fallbackAudioUrl;
        await player.setAudioSource(
          AudioSource.uri(
            Uri.parse(url),
            tag: MediaItem(
              id: 'mixer-$channel',
              title: '$channel ambience',
              artist: 'SleepWell Mixer',
            ),
          ),
        );
      }

      await player.setVolume(volume);
      await player.play();
    }

    isMixerPlaying = true;
    await _logEvent('mixer_start');
    notifyListeners();
  }

  Future<void> saveCurrentMixPreset() async {
    final name = 'Preset ${DateTime.now().toIso8601String().replaceFirst("T", " ").substring(0, 16)}';
    try {
      await _api.saveMixPreset(
        deviceId: deviceId,
        name: name,
        channels: mixer,
      );
      await refreshMixPresets();
      apiConnected = true;
      lastError = 'Mixer preset saved.';
    } catch (_) {
      apiConnected = false;
      lastError = 'Could not save preset to API.';
      notifyListeners();
    }
  }

  Future<void> refreshMixPresets() async {
    try {
      mixerPresets = await _api.fetchMixPresets(deviceId: deviceId);
      apiConnected = true;
    } catch (_) {
      apiConnected = false;
    }
    notifyListeners();
  }

  Future<void> applyMixPreset(MixPreset preset) async {
    for (final entry in preset.channels.entries) {
      mixer[entry.key] = entry.value.clamp(0.0, 1.0).toDouble();
      if (_enableAudio && isMixerPlaying && _mixerPlayers[entry.key] != null) {
        await _mixerPlayers[entry.key]!.setVolume(mixer[entry.key]!);
      }
    }
    await _logEvent('mixer_preset_apply');
    notifyListeners();
  }

  Future<void> setSleepTimerMinutes(int minutes) async {
    sleepTimerMinutes = minutes;
    if (isPlaying) {
      await _scheduleSleepTimer();
    }
    await _logEvent('timer_set');
    notifyListeners();
  }

  Future<void> setLoopEnabled(bool enabled) async {
    loop = enabled;
    if (_enableAudio) {
      await _player.setLoopMode(enabled ? LoopMode.one : LoopMode.off);
    }
    await _logEvent(enabled ? 'repeat_on' : 'repeat_off');
    notifyListeners();
  }

  void setSleepNowMixerEnabled(bool enabled) {
    enableMixerInSleepNow = enabled;
    notifyListeners();
  }

  Future<void> togglePlayPause() async {
    if (!_enableAudio) {
      return;
    }
    if (_player.playing) {
      await _player.pause();
      isPlaying = false;
      await _logEvent('pause');
    } else {
      await _player.play();
      isPlaying = true;
      await _logEvent('resume');
      await _scheduleSleepTimer();
    }
    notifyListeners();
  }

  Future<void> refreshInsights() async {
    try {
      insights = await _api.fetchInsights(deviceId: deviceId);
      apiConnected = true;
      lastError = null;
    } catch (_) {
      final localUsage = sessions.length;
      final localConsistency = min(100, (localUsage / 7 * 100).round());
      final localAvg = sessions.isEmpty
          ? 0
          : sessions.map((s) => s.durationMinutes).reduce((a, b) => a + b) ~/
              sessions.length;
      insights = SleepInsights(
        usageFrequencyLast7Days: localUsage,
        consistencyScore: localConsistency,
        averageDurationMinutes: localAvg,
      );
      apiConnected = false;
      lastError = 'Insights are currently local.';
    }
    notifyListeners();
  }

  Future<void> _startSession({
    required String mode,
    required String entryPoint,
  }) async {
    _sessionStartedAt = DateTime.now();
    try {
      _activeSessionId = await _api.startSession(
        deviceId: deviceId,
        mode: mode,
        entryPoint: entryPoint,
      );
      apiConnected = true;
    } catch (_) {
      _activeSessionId = null;
      apiConnected = false;
    }
  }

  Future<void> _logEvent(String eventType) async {
    if (_activeSessionId == null) {
      return;
    }
    try {
      await _api.addSessionEvent(
        sessionId: _activeSessionId!,
        eventType: eventType,
        trackId: selectedTrack?.id,
      );
      apiConnected = true;
    } catch (_) {
      apiConnected = false;
    }
  }

  Future<void> _configureAudio() async {
    if (!_enableAudio) {
      return;
    }
    await _player.setLoopMode(loop ? LoopMode.one : LoopMode.off);
    for (final entry in mixer.entries) {
      final player = AudioPlayer();
      await player.setLoopMode(LoopMode.one);
      await player.setVolume(entry.value);
      _mixerPlayers[entry.key] = player;
    }
    _positionSubscription ??= _player.positionStream.listen((position) {
      currentPosition = position;
      notifyListeners();
    });
    _playerStateSubscription ??= _player.playerStateStream.listen((state) {
      isPlaying = state.playing;
      final duration = _player.duration;
      if (duration != null) {
        currentDuration = duration;
      }
      notifyListeners();
    });
  }

  Future<void> _playSelectedTrack() async {
    if (!_enableAudio || selectedTrack == null) {
      isPlaying = true;
      return;
    }

    final rawUrl = selectedTrack!.streamUrl?.trim();
    final primaryUrl = _normalizeMediaUrl(
      rawUrl?.isNotEmpty == true ? rawUrl! : _fallbackAudioUrl,
      apiBaseUrl: SleepWellApi.baseUrl,
    );

    Future<void> playFromUrl(String url) async {
      await _player.setAudioSource(
        AudioSource.uri(
          Uri.parse(url),
          tag: MediaItem(
            id: '${selectedTrack!.id ?? selectedTrack!.title}-$url',
            title: selectedTrack!.title,
            artist: 'SleepWell',
          ),
        ),
      );
      await _player.play();
    }

    try {
      await playFromUrl(primaryUrl);
      currentDuration = _player.duration ?? Duration.zero;
      isPlaying = true;
      await _scheduleSleepTimer();
    } catch (_) {
      if (primaryUrl == _fallbackAudioUrl) {
        isPlaying = false;
        lastError = 'Playback failed. Check your internet connection.';
        notifyListeners();
        return;
      }
      try {
        await playFromUrl(_fallbackAudioUrl);
        currentDuration = _player.duration ?? Duration.zero;
        isPlaying = true;
        lastError = 'Track URL unavailable ($primaryUrl), fallback audio playing.';
        await _scheduleSleepTimer();
      } catch (_) {
        isPlaying = false;
        lastError = 'Playback failed. Check your internet connection.';
      }
    }
  }

  Future<void> _scheduleSleepTimer() async {
    await _cancelSleepTimer();
    _sleepTimer = Timer(Duration(minutes: sleepTimerMinutes), () async {
      await _logEvent('timer_completed');
      await stopPlayback();
    });
  }

  Future<void> _cancelSleepTimer() async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
  }

  Future<void> _fadeOutAndStop() async {
    if (!_enableAudio) {
      return;
    }
    final startVolume = _player.volume;
    const steps = 12;
    for (var i = steps; i >= 0; i--) {
      await _player.setVolume(startVolume * (i / steps));
      await Future<void>.delayed(const Duration(milliseconds: 180));
    }
    await _player.stop();
    await _player.setVolume(1.0);
  }

  @override
  void dispose() {
    _sleepTimer?.cancel();
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _player.dispose();
    for (final player in _mixerPlayers.values) {
      player.dispose();
    }
    super.dispose();
  }
}

class SleepTrack {
  const SleepTrack({
    this.id,
    required this.title,
    required this.category,
    required this.talking,
    this.streamUrl,
    this.durationSeconds = 1800,
  });

  final int? id;
  final String title;
  final String category;
  final bool talking;
  final String? streamUrl;
  final int durationSeconds;

  factory SleepTrack.fromJson(Map<String, dynamic> json) {
    return SleepTrack(
      id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}'),
      title: '${json['title'] ?? 'Untitled'}',
      category: '${json['category'] ?? 'rain'}',
      talking: json['talking'] == true || json['talking'] == 1,
      streamUrl: json['stream_url']?.toString(),
      durationSeconds: _toInt(json['duration_seconds']),
    );
  }
}

class SleepSession {
  const SleepSession(this.startedAt, this.durationMinutes);
  final DateTime startedAt;
  final int durationMinutes;

  SleepSession copyWith({DateTime? startedAt, int? durationMinutes}) {
    return SleepSession(
      startedAt ?? this.startedAt,
      durationMinutes ?? this.durationMinutes,
    );
  }
}

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.state});
  final SleepWellState state;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  bool talking = false;
  int difficulty = 3;
  final Set<String> categories = <String>{'rain'};
  final Set<String> soundTypes = <String>{'nature'};

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Welcome to SleepWell')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Talking preference'),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment<bool>(value: true, label: Text('Talking')),
              ButtonSegment<bool>(value: false, label: Text('No talking')),
            ],
            selected: {talking},
            onSelectionChanged: (value) => setState(() => talking = value.first),
          ),
          const SizedBox(height: 12),
          const Text('Sleep difficulty'),
          Slider(
            value: difficulty.toDouble(),
            min: 1,
            max: 5,
            divisions: 4,
            label: '$difficulty',
            onChanged: (v) => setState(() => difficulty = v.toInt()),
          ),
          _chipSection(
            title: 'Categories',
            source: const ['whisper', 'no_talking', 'rain', 'roleplay'],
            selected: categories,
          ),
          const SizedBox(height: 10),
          _chipSection(
            title: 'Sound types',
            source: const ['nature', 'brown_noise', 'story', 'roleplay'],
            selected: soundTypes,
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: widget.state.isBusy
                ? null
                : () async {
                    await widget.state.completeOnboarding(
                      talking: talking,
                      difficulty: difficulty,
                      categories: categories.toList(),
                      soundTypes: soundTypes.toList(),
                    );
                  },
            child: Text(
              widget.state.isBusy ? 'Saving...' : 'Start Sleeping Better',
            ),
          ),
        ],
      ),
    );
  }

  Widget _chipSection({
    required String title,
    required List<String> source,
    required Set<String> selected,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: source
              .map(
                (item) => FilterChip(
                  label: Text(item),
                  selected: selected.contains(item),
                  onSelected: (enabled) => setState(() {
                    if (enabled) {
                      selected.add(item);
                    } else {
                      selected.remove(item);
                    }
                  }),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.state});
  final SleepWellState state;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = [
      SleepNowPage(state: widget.state),
      PlayerPage(state: widget.state),
      MixerPage(state: widget.state),
      InsightsPage(state: widget.state),
    ];
    return Scaffold(
      appBar: AppBar(
        title: const Text('SleepWell'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Chip(
              label: Text(widget.state.apiConnected ? 'API Connected' : 'Offline Mode'),
              backgroundColor: widget.state.apiConnected
                  ? Colors.green.withValues(alpha: 0.2)
                  : Colors.orange.withValues(alpha: 0.2),
              side: BorderSide.none,
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          if (widget.state.lastError != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              color: Colors.orange.withValues(alpha: 0.2),
              child: Text(
                widget.state.lastError!,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          Expanded(child: pages[index]),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (i) => setState(() => index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.nights_stay), label: 'Sleep Now'),
          NavigationDestination(icon: Icon(Icons.play_circle), label: 'Player'),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Mixer'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Insights'),
        ],
      ),
    );
  }
}

class SleepNowPage extends StatelessWidget {
  const SleepNowPage({super.key, required this.state});
  final SleepWellState state;

  @override
  Widget build(BuildContext context) {
    if (state.isBootstrapping) {
      return const Center(child: CircularProgressIndicator());
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('One tap for tonight', style: TextStyle(fontSize: 22)),
            const SizedBox(height: 8),
            const Text(
              'Personalized sequence, fade-out enabled, low light mode.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 14),
            SwitchListTile(
              title: const Text('Include ambient mixer'),
              subtitle: const Text('Auto-layer rain/wind/white-noise with Sleep Now'),
              value: state.enableMixerInSleepNow,
              onChanged: (value) {
                state.setSleepNowMixerEnabled(value);
              },
            ),
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.bedtime),
                label: Text(state.isBusy ? 'Preparing...' : 'Sleep Now'),
                onPressed: state.isBusy
                    ? null
                    : () async {
                        await state.startSleepNow();
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Playing: ${state.selectedTrack?.title ?? ''}')),
                        );
                      },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key, required this.state});
  final SleepWellState state;

  @override
  Widget build(BuildContext context) {
    final duration = state.currentDuration.inMilliseconds <= 0
        ? const Duration(seconds: 1)
        : state.currentDuration;
    final positionMillis = min(
      state.currentPosition.inMilliseconds,
      duration.inMilliseconds,
    ).toDouble();

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Smart ASMR Player', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            title: Text(state.selectedTrack?.title ?? 'No track selected'),
            subtitle: Text(
              '${_formatDuration(state.currentPosition)} / ${_formatDuration(duration)}',
            ),
            trailing: IconButton(
              icon: Icon(state.isPlaying ? Icons.pause_circle : Icons.play_circle),
              onPressed: state.selectedTrack == null
                  ? null
                  : () async {
                      await state.togglePlayPause();
                    },
            ),
          ),
        ),
        Slider(
          value: positionMillis,
          min: 0,
          max: duration.inMilliseconds.toDouble(),
          onChanged: (_) {},
        ),
        const SizedBox(height: 8),
        ...state.tracks.map(
          (track) => Card(
            child: ListTile(
              title: Text(track.title),
              subtitle: Text('${track.category} • ${track.talking ? 'talking' : 'no talking'}'),
              trailing: IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: () async {
                  await state.playTrack(track);
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('Loop playback'),
          value: state.loop,
          onChanged: (value) async {
            await state.setLoopEnabled(value);
          },
        ),
        ListTile(
          title: Text('Sleep timer (${state.sleepTimerMinutes} min)'),
          subtitle: Slider(
            value: state.sleepTimerMinutes.toDouble(),
            min: 10,
            max: 90,
            divisions: 8,
            onChanged: (v) async {
              await state.setSleepTimerMinutes(v.toInt());
            },
          ),
        ),
        FilledButton.tonal(
          onPressed: state.isPlaying
              ? () async {
                  await state.stopPlayback();
                }
              : null,
          child: const Text('Stop with fade-out'),
        ),
      ],
    );
  }
}

class MixerPage extends StatelessWidget {
  const MixerPage({super.key, required this.state});
  final SleepWellState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Sound Mixer', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: () async {
            await state.toggleMixerPlayback();
          },
          icon: Icon(state.isMixerPlaying ? Icons.stop : Icons.graphic_eq),
          label: Text(state.isMixerPlaying ? 'Stop Mixer' : 'Start Mixer'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: FilledButton.tonal(
                onPressed: () async {
                  await state.saveCurrentMixPreset();
                },
                child: const Text('Save Preset'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonal(
                onPressed: () async {
                  await state.refreshMixPresets();
                },
                child: const Text('Refresh Presets'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...state.mixer.entries.map(
          (entry) => ListTile(
            title: Text(entry.key),
            subtitle: Slider(
              value: entry.value,
              onChanged: (v) => state.updateMixer(entry.key, v),
            ),
          ),
        ),
        const SizedBox(height: 8),
        const Text('Saved Presets'),
        const SizedBox(height: 6),
        if (state.mixerPresets.isEmpty)
          const Text(
            'No presets yet. Save your current mix first.',
            style: TextStyle(fontSize: 12, color: Colors.white70),
          )
        else
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: state.mixerPresets
                .map(
                  (preset) => ActionChip(
                    label: Text(preset.name),
                    onPressed: () async {
                      await state.applyMixPreset(preset);
                    },
                  ),
                )
                .toList(),
          ),
      ],
    );
  }
}

class InsightsPage extends StatelessWidget {
  const InsightsPage({super.key, required this.state});
  final SleepWellState state;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Basic Sleep Tracking', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            title: const Text('Usage frequency (7 days)'),
            trailing: Text('${state.insights.usageFrequencyLast7Days} sessions'),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Sleep consistency score'),
            trailing: Text('${state.insights.consistencyScore}/100'),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Average duration'),
            trailing: Text('${state.insights.averageDurationMinutes} min'),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton.tonal(
          onPressed: () async {
            await state.refreshInsights();
          },
          child: const Text('Refresh Insights'),
        ),
      ],
    );
  }
}

class SleepInsights {
  const SleepInsights({
    required this.usageFrequencyLast7Days,
    required this.consistencyScore,
    required this.averageDurationMinutes,
  });

  final int usageFrequencyLast7Days;
  final int consistencyScore;
  final int averageDurationMinutes;

  factory SleepInsights.fromJson(Map<String, dynamic> json) {
    return SleepInsights(
      usageFrequencyLast7Days: _toInt(json['usage_frequency_last_7_days']),
      consistencyScore: _toInt(json['consistency_score']),
      averageDurationMinutes: _toInt(json['average_duration_minutes']),
    );
  }
}

class MixPreset {
  const MixPreset({
    required this.id,
    required this.name,
    required this.channels,
  });

  final int id;
  final String name;
  final Map<String, double> channels;

  factory MixPreset.fromJson(Map<String, dynamic> json) {
    final rawChannels = (json['channels'] is Map<String, dynamic>)
        ? json['channels'] as Map<String, dynamic>
        : <String, dynamic>{};

    final channels = <String, double>{};
    for (final entry in rawChannels.entries) {
      channels[entry.key] = _toDouble(entry.value);
    }

    return MixPreset(
      id: _toInt(json['id']),
      name: '${json['name'] ?? 'Preset'}',
      channels: channels,
    );
  }
}

const String _fallbackAudioUrl = 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';
const Map<String, String> _mixerChannelUrls = <String, String>{
  'Rain': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
  'Wind': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
  'White Noise': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3',
};

class SleepWellApi {
  static const String baseUrl = String.fromEnvironment(
    'SLEEPWELL_API_BASE_URL',
    defaultValue: 'https://cariloker.info/api/v1/sleepwell',
  );

  static String get defaultDeviceId {
    final host = Platform.localHostname.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return 'sleepwell-${Platform.operatingSystem.toLowerCase()}-$host';
  }

  Future<List<SleepTrack>> fetchCatalog() async {
    final json = await _request('GET', '/catalog');
    final tracksRaw = (json['tracks'] as List<dynamic>? ?? <dynamic>[]);
    return tracksRaw
        .whereType<Map<String, dynamic>>()
        .map(SleepTrack.fromJson)
        .toList();
  }

  Future<void> submitOnboarding({
    required String deviceId,
    required bool talking,
    required int difficulty,
    required List<String> categories,
    required List<String> soundTypes,
  }) async {
    await _request(
      'POST',
      '/onboarding',
      body: {
        'device_id': deviceId,
        'timezone': DateTime.now().timeZoneName,
        'sleep_difficulty': difficulty,
        'prefers_talking': talking,
        'preferred_categories': categories,
        'preferred_sound_types': soundTypes,
      },
    );
  }

  Future<List<SleepTrack>> fetchSleepNowSequence({
    required String deviceId,
  }) async {
    final json = await _request(
      'POST',
      '/sleep-now',
      body: {'device_id': deviceId},
    );
    final sequenceRaw = (json['sleep_now_sequence'] as List<dynamic>? ?? <dynamic>[]);
    return sequenceRaw
        .whereType<Map<String, dynamic>>()
        .map(SleepTrack.fromJson)
        .toList();
  }

  Future<int?> startSession({
    required String deviceId,
    required String mode,
    required String entryPoint,
  }) async {
    final json = await _request(
      'POST',
      '/sessions/start',
      body: {
        'device_id': deviceId,
        'mode': mode,
        'entry_point': entryPoint,
        'device_local_date': DateTime.now().toIso8601String().split('T').first,
      },
    );
    return _nullableInt(json['session_id']);
  }

  Future<void> addSessionEvent({
    required int sessionId,
    required String eventType,
    int? trackId,
  }) async {
    await _request(
      'POST',
      '/sessions/$sessionId/event',
      body: {
        'event_type': eventType,
        'track_id': trackId,
        'position_seconds': 0,
        'metadata': {'source': 'flutter_mvp'},
      },
    );
  }

  Future<void> endSession({
    required int sessionId,
    required String status,
    required DateTime endedAt,
  }) async {
    await _request(
      'POST',
      '/sessions/$sessionId/end',
      body: {
        'status': status,
        'ended_at': endedAt.toIso8601String(),
      },
    );
  }

  Future<SleepInsights> fetchInsights({
    required String deviceId,
  }) async {
    final json = await _request('GET', '/insights/$deviceId');
    return SleepInsights.fromJson(json);
  }

  Future<List<MixPreset>> fetchMixPresets({
    required String deviceId,
  }) async {
    final json = await _request('GET', '/mix-presets/$deviceId');
    final presetsRaw = (json['presets'] as List<dynamic>? ?? <dynamic>[]);
    return presetsRaw
        .whereType<Map<String, dynamic>>()
        .map(MixPreset.fromJson)
        .toList();
  }

  Future<void> saveMixPreset({
    required String deviceId,
    required String name,
    required Map<String, double> channels,
  }) async {
    await _request(
      'POST',
      '/mix-presets',
      body: {
        'device_id': deviceId,
        'name': name,
        'channels': channels,
      },
    );
  }

  Future<Map<String, dynamic>> _request(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final client = HttpClient();
    final uri = Uri.parse('$baseUrl$path');
    final request = await client.openUrl(method, uri).timeout(
          const Duration(seconds: 10),
        );
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (body != null) {
      request.write(jsonEncode(body));
    }
    final response = await request.close().timeout(const Duration(seconds: 10));
    final raw = await response.transform(utf8.decoder).join();
    client.close();

    if (response.statusCode >= 400) {
      throw HttpException('API request failed (${response.statusCode})', uri: uri);
    }

    if (raw.isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }
}

String _normalizeMediaUrl(String input, {required String apiBaseUrl}) {
  final value = input.trim();
  final apiUri = Uri.parse(apiBaseUrl);

  Uri uri;
  if (value.startsWith('http://') || value.startsWith('https://')) {
    uri = Uri.parse(value);
  } else if (value.startsWith('/')) {
    uri = apiUri.resolve(value);
  } else {
    uri = apiUri.resolve('/$value');
  }

  final host = uri.host.toLowerCase();
  final apiHost = apiUri.host.toLowerCase();
  final isLocalHost = host == 'localhost' || host == '127.0.0.1';
  final isApiLocal = apiHost == 'localhost' || apiHost == '127.0.0.1';

  if (isLocalHost && !isApiLocal) {
    return uri
        .replace(
          scheme: apiUri.scheme,
          host: apiUri.host,
          port: apiUri.hasPort ? apiUri.port : null,
        )
        .toString();
  }

  if (Platform.isAndroid && isLocalHost) {
    return uri.replace(host: '10.0.2.2').toString();
  }
  return uri.toString();
}

int _toInt(dynamic value) {
  if (value is int) {
    return value;
  }
  return int.tryParse('$value') ?? 0;
}

double _toDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is int) {
    return value.toDouble();
  }
  return double.tryParse('$value') ?? 0.0;
}

int? _nullableInt(dynamic value) {
  if (value == null) {
    return null;
  }
  return _toInt(value);
}

String _formatDuration(Duration duration) {
  final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
  final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  final hours = duration.inHours;
  if (hours > 0) {
    return '${hours.toString().padLeft(2, '0')}:$minutes:$seconds';
  }
  return '$minutes:$seconds';
}
