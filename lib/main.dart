import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import 'features/common/ad_banner_slot.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  tzdata.initializeTimeZones();
  await JustAudioBackground.init(
    androidNotificationChannelId: 'com.sleepwell.audio',
    androidNotificationChannelName: 'SleepWell Playback',
    androidNotificationOngoing: true,
  );
  await MobileAds.instance.initialize();
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
        textTheme: ThemeData.dark().textTheme.apply(
              bodyColor: Colors.white,
              displayColor: Colors.white,
            ),
        chipTheme: ChipThemeData(
          side: const BorderSide(color: Colors.white24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          backgroundColor: Colors.white.withValues(alpha: 0.06),
        ),
        navigationBarTheme: NavigationBarThemeData(
          backgroundColor: const Color(0xFF0A0E1A).withValues(alpha: 0.96),
          indicatorColor: const Color(0xFF2D3278),
          labelTextStyle: WidgetStateProperty.resolveWith<TextStyle?>(
            (states) {
              final selected = states.contains(WidgetState.selected);
              return TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: selected ? Colors.white : Colors.white60,
              );
            },
          ),
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

// Frozen baseline tokens (final UI pass) for consistent spacing/radius.
class _UiBaseline {
  static const double pageHorizontal = 16;
  static const double pageTop = 12;
  static const double pageBottomInset = 180;
  static const double sectionGap = 18;

  static const double radiusSm = 10;
  static const double radiusMd = 16;
  static const double radiusLg = 20;
  static const double radiusXl = 28;

  static const double titleSize = 17;
  static const double tabSize = 15;
  static const double chipHeight = 42;

  static const double cardRailHeight = 198;
  static const double cardRailWidth = 170;
  static const double promotedHeight = 200;

  static const double nowPlayingMainButton = 84;
  static const double nowPlayingMainIcon = 46;

  static const double savedTitleSize = 34;
  static const double savedSectionTitleSize = 37;
  static const double savedTabHeight = 44;
  static const double savedTabFontSize = 16.5;
  static const double savedThumbSize = 70;
  static const double savedRowTitleSize = 17;
  static const double savedRowSubtitleSize = 14.5;
  static const double savedMiniPlayerBottomGap = 92;

  static const double profileTitleSize = 36;
  static const double profileHeroTitleSize = 40;
  static const double profileNameSize = 22;
  static const double profileAvatarSize = 92;
  static const double profileCardRadius = 18;
  static const double profileListRadius = 20;
  static const double profileRowTitleSize = 16;
  static const double profileActionPillHeight = 34;
  static const double profileActionPillHorizontal = 14;

  static const double settingsTitleSize = 34;
  static const double settingsCardRadius = 22;
  static const double settingsRowVertical = 16;
  static const double settingsToggleScale = 0.86;
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
  SharedPreferences? _prefs;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Timer? _sleepTimer;
  Timer? _bedtimeTicker;
  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();

  bool isBootstrapping = true;
  bool isBusy = false;
  bool apiConnected = false;
  String? lastError;
  String deviceId = SleepWellApi.defaultDeviceId;
  String? authToken;
  AppUserProfile? currentUser;
  final List<SavedContentItem> savedCloudItems = <SavedContentItem>[];
  final List<Map<String, dynamic>> _queuedEvents = <Map<String, dynamic>>[];
  List<AdPlacementConfig> adPlacements = <AdPlacementConfig>[];
  DateTime? lastSyncAt;
  String syncStatus = 'idle';
  int syncFailureCount = 0;
  DateTime? _lastScheduleMissedAt;

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
  List<HomeSectionContent> homeSections = <HomeSectionContent>[];
  final List<String> sleepGoals = <String>[
    'Fall Asleep Faster',
    'Sleep All Night',
    'Relax & Unwind',
    'Reduce Anxiety',
  ];
  String selectedSleepGoal = 'Fall Asleep Faster';

  bool isPlaying = false;
  bool isScreenDimmed = false;
  bool enableMixerInSleepNow = true;
  bool loop = true;
  bool bedtimeRoutineEnabled = false;
  TimeOfDay bedtimeTime = const TimeOfDay(hour: 22, minute: 30);
  DateTime? _lastBedtimeTriggerAt;
  int sleepTimerMinutes = 30;
  Duration currentPosition = Duration.zero;
  Duration currentDuration = Duration.zero;
  double mainPlayerVolume = 1.0;
  SleepTrack? selectedTrack;
  int? _activeSessionId;
  DateTime? _sessionStartedAt;
  SleepInsights insights = const SleepInsights(
    usageFrequencyLast7Days: 0,
    consistencyScore: 0,
    averageDurationMinutes: 0,
  );
  List<OnboardingStepContent> onboardingScreens = <OnboardingStepContent>[];

  bool get isAuthenticated => authToken != null && currentUser != null;

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
    _prefs = await SharedPreferences.getInstance();
    _restoreLocalState();
    await _initNotifications();
    await _configureAudio();
    await fetchOnboardingContent();
    await fetchCatalog();
    await fetchHomeFeed();
    await fetchAdPlacements();
    if (authToken != null) {
      _api.setAuthToken(authToken);
      await hydrateProfile();
      await refreshCloudSavedItems();
    }
    await refreshInsights();
    await refreshMixPresets();
    if (_queuedEvents.isNotEmpty) {
      await _flushQueuedEvents();
    }
    _startBedtimeTicker();
    if (bedtimeRoutineEnabled) {
      await _scheduleBedtimeNotification();
    }
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

  Future<void> fetchOnboardingContent() async {
    try {
      final data = await _api.fetchOnboardingContent();
      onboardingScreens = data.isEmpty ? _fallbackOnboardingScreens : data;
      apiConnected = true;
    } catch (_) {
      onboardingScreens = _fallbackOnboardingScreens;
      apiConnected = false;
      lastError = 'Using offline onboarding flow.';
    }
    notifyListeners();
  }

  Future<void> fetchHomeFeed() async {
    try {
      final data = await _api.fetchHomeFeed(
        goal: selectedSleepGoal,
        timeSegment: _timeSegmentFor(DateTime.now()),
        deviceId: deviceId,
      );
      homeSections = data.isEmpty ? _fallbackHomeSections : data;
      apiConnected = true;
    } catch (_) {
      homeSections = _fallbackHomeSections;
      apiConnected = false;
      lastError = 'Using offline home feed.';
    }
    notifyListeners();
  }

  String _timeSegmentFor(DateTime now) {
    final hour = now.hour;
    if (hour >= 5 && hour < 12) {
      return 'morning';
    }
    if (hour >= 12 && hour < 18) {
      return 'afternoon';
    }
    if (hour >= 18 && hour < 22) {
      return 'evening';
    }
    return 'night';
  }

  Future<void> completeOnboarding({
    required bool talking,
    required int difficulty,
    required List<String> categories,
    required List<String> soundTypes,
    Map<String, dynamic> answers = const <String, dynamic>{},
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
      if (answers.isNotEmpty) {
        await _api.submitOnboardingResponses(
          deviceId: deviceId,
          answers: answers,
        );
      }
      apiConnected = true;
      lastError = null;
    } catch (_) {
      apiConnected = false;
      lastError = 'Onboarding saved locally. API unavailable.';
    }
    await _persistLocalState();
    isBusy = false;
    notifyListeners();
  }

  Future<void> startSleepNow({String entryPoint = 'sleep_now_button'}) async {
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

    await _startSession(mode: 'sleep_now', entryPoint: entryPoint);
    if (_isWithinBedtimeAdherenceWindow(DateTime.now())) {
      await _logEvent('schedule_adherence_hit');
    }
    await _playSelectedTrack();
    isScreenDimmed = true;
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
    isScreenDimmed = false;
    sessions.add(SleepSession(DateTime.now(), 0));
    await _startSession(mode: 'player', entryPoint: 'player_track_tap');
    await _playSelectedTrack();
    await _logEvent('play');
    if (isAuthenticated) {
      unawaited(
        upsertSavedItem(
          itemType: 'recently_played',
          itemRef: '${track.id ?? track.title}',
          title: track.title,
          subtitle: '${track.category} • ${track.talking ? 'Talking' : 'No talking'}',
        ),
      );
    }
    notifyListeners();
  }

  Future<void> stopPlayback() async {
    await _fadeOutAndStop();
    if (isMixerPlaying) {
      await toggleMixerPlayback();
    }
    isPlaying = false;
    isScreenDimmed = false;
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
    unawaited(_persistLocalState());
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
      mixerPresets = isAuthenticated
          ? await _api.fetchMixPresetsForUser()
          : await _api.fetchMixPresets(deviceId: deviceId);
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
    await _persistLocalState();
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

  Future<void> seekTo(Duration position) async {
    if (!_enableAudio) {
      return;
    }
    await _player.seek(position);
  }

  Future<void> setMainPlayerVolume(double value) async {
    mainPlayerVolume = value.clamp(0.0, 1.0);
    if (_enableAudio) {
      await _player.setVolume(mainPlayerVolume);
    }
    notifyListeners();
  }

  void setSleepNowMixerEnabled(bool enabled) {
    enableMixerInSleepNow = enabled;
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setSelectedSleepGoal(String goal) {
    selectedSleepGoal = goal;
    unawaited(_persistLocalState());
    notifyListeners();
  }

  HomeSectionContent? sectionByKey(String key) {
    for (final section in homeSections) {
      if (section.sectionKey == key) {
        return section;
      }
    }
    return null;
  }

  void setBedtimeRoutineEnabled(bool enabled) {
    bedtimeRoutineEnabled = enabled;
    if (enabled) {
      lastError = 'Bedtime routine set for ${_formatTimeOfDay(bedtimeTime)}.';
      unawaited(_scheduleBedtimeNotification());
    } else {
      unawaited(_cancelBedtimeNotification());
    }
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setBedtimeTime(TimeOfDay value) {
    bedtimeTime = value;
    lastError = 'Bedtime updated to ${_formatTimeOfDay(value)}.';
    if (bedtimeRoutineEnabled) {
      unawaited(_scheduleBedtimeNotification());
    }
    unawaited(_persistLocalState());
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
      insights = isAuthenticated
          ? await _api.fetchInsightsForUser()
          : await _api.fetchInsights(deviceId: deviceId);
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
    syncStatus = 'syncing';
    try {
      await _api.addSessionEvent(
        sessionId: _activeSessionId!,
        eventType: eventType,
        trackId: selectedTrack?.id,
      );
      apiConnected = true;
      syncStatus = 'ok';
      syncFailureCount = 0;
      lastSyncAt = DateTime.now();
      if (_queuedEvents.isNotEmpty) {
        await _flushQueuedEvents();
      }
    } catch (_) {
      apiConnected = false;
      syncStatus = 'offline_queue';
      syncFailureCount += 1;
      _enqueueEvent(
        sessionId: _activeSessionId!,
        eventType: eventType,
        trackId: selectedTrack?.id,
      );
      unawaited(_persistLocalState());
    }
  }

  void _restoreLocalState() {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }

    deviceId = prefs.getString('device_id') ?? SleepWellApi.defaultDeviceId;
    isOnboarded = prefs.getBool('is_onboarded') ?? false;
    prefersTalking = prefs.getBool('prefers_talking') ?? false;
    sleepDifficulty = prefs.getInt('sleep_difficulty') ?? 3;
    enableMixerInSleepNow = prefs.getBool('enable_mixer_in_sleep_now') ?? true;
    bedtimeRoutineEnabled = prefs.getBool('bedtime_routine_enabled') ?? false;
    final bedtimeHour = prefs.getInt('bedtime_hour') ?? bedtimeTime.hour;
    final bedtimeMinute = prefs.getInt('bedtime_minute') ?? bedtimeTime.minute;
    bedtimeTime = TimeOfDay(hour: bedtimeHour, minute: bedtimeMinute);
    selectedSleepGoal = prefs.getString('selected_sleep_goal') ?? selectedSleepGoal;
    authToken = prefs.getString('auth_token');
    final userRaw = prefs.getString('auth_user');
    if (userRaw != null && userRaw.isNotEmpty) {
      final decoded = jsonDecode(userRaw);
      if (decoded is Map<String, dynamic>) {
        currentUser = AppUserProfile.fromJson(decoded);
      }
    }
    final queuedRaw = prefs.getString('queued_events');
    if (queuedRaw != null && queuedRaw.isNotEmpty) {
      final decoded = jsonDecode(queuedRaw);
      if (decoded is List) {
        _queuedEvents
          ..clear()
          ..addAll(decoded.whereType<Map<String, dynamic>>());
      }
    }
    final lastSyncRaw = prefs.getString('last_sync_at');
    if (lastSyncRaw != null && lastSyncRaw.isNotEmpty) {
      lastSyncAt = DateTime.tryParse(lastSyncRaw);
    }
    syncStatus = prefs.getString('sync_status') ?? syncStatus;
    syncFailureCount = prefs.getInt('sync_failure_count') ?? syncFailureCount;

    preferredCategories
      ..clear()
      ..addAll(prefs.getStringList('preferred_categories') ?? const <String>[]);
    preferredSoundTypes
      ..clear()
      ..addAll(prefs.getStringList('preferred_sound_types') ?? const <String>[]);

    final mixerRaw = prefs.getString('mixer_state');
    if (mixerRaw != null && mixerRaw.isNotEmpty) {
      final decoded = jsonDecode(mixerRaw);
      if (decoded is Map<String, dynamic>) {
        for (final entry in decoded.entries) {
          mixer[entry.key] = _toDouble(entry.value).clamp(0.0, 1.0);
        }
      }
    }

    unawaited(_persistLocalState());
  }

  Future<void> _persistLocalState() async {
    final prefs = _prefs;
    if (prefs == null) {
      return;
    }

    await prefs.setString('device_id', deviceId);
    await prefs.setBool('is_onboarded', isOnboarded);
    await prefs.setBool('prefers_talking', prefersTalking);
    await prefs.setInt('sleep_difficulty', sleepDifficulty);
    await prefs.setStringList('preferred_categories', preferredCategories);
    await prefs.setStringList('preferred_sound_types', preferredSoundTypes);
    await prefs.setBool('enable_mixer_in_sleep_now', enableMixerInSleepNow);
    await prefs.setBool('bedtime_routine_enabled', bedtimeRoutineEnabled);
    await prefs.setInt('bedtime_hour', bedtimeTime.hour);
    await prefs.setInt('bedtime_minute', bedtimeTime.minute);
    await prefs.setString('selected_sleep_goal', selectedSleepGoal);
    await prefs.setString('mixer_state', jsonEncode(mixer));
    if (authToken != null) {
      await prefs.setString('auth_token', authToken!);
    } else {
      await prefs.remove('auth_token');
    }
    if (currentUser != null) {
      await prefs.setString('auth_user', jsonEncode(currentUser!.toJson()));
    } else {
      await prefs.remove('auth_user');
    }
    await prefs.setString('queued_events', jsonEncode(_queuedEvents));
    await prefs.setString('sync_status', syncStatus);
    await prefs.setInt('sync_failure_count', syncFailureCount);
    if (lastSyncAt != null) {
      await prefs.setString('last_sync_at', lastSyncAt!.toIso8601String());
    } else {
      await prefs.remove('last_sync_at');
    }
  }

  Future<void> registerWithEmail({
    required String name,
    required String email,
    required String password,
  }) async {
    final result = await _api.register(
      name: name,
      email: email,
      password: password,
      deviceId: deviceId,
    );
    authToken = result.token;
    currentUser = result.user;
    _api.setAuthToken(authToken);
    await _syncAnonymousStateToCloud();
    await _persistLocalState();
    await refreshMixPresets();
    await refreshInsights();
    await refreshCloudSavedItems();
    notifyListeners();
  }

  Future<void> loginWithEmail({
    required String email,
    required String password,
  }) async {
    final result = await _api.login(
      email: email,
      password: password,
      deviceId: deviceId,
    );
    authToken = result.token;
    currentUser = result.user;
    _api.setAuthToken(authToken);
    await _syncAnonymousStateToCloud();
    await _persistLocalState();
    await refreshMixPresets();
    await refreshInsights();
    await refreshCloudSavedItems();
    notifyListeners();
  }

  Future<void> hydrateProfile() async {
    if (authToken == null) {
      return;
    }
    try {
      currentUser = await _api.fetchMe();
      apiConnected = true;
    } catch (_) {
      apiConnected = false;
    }
    notifyListeners();
  }

  Future<void> logoutAccount() async {
    try {
      await _api.logout();
    } catch (_) {
      // no-op; local logout still applies
    }
    authToken = null;
    currentUser = null;
    _api.setAuthToken(null);
    await _persistLocalState();
    notifyListeners();
  }

  Future<void> refreshCloudSavedItems() async {
    if (!isAuthenticated) {
      return;
    }
    try {
      savedCloudItems
        ..clear()
        ..addAll(await _api.fetchSavedItems());
      apiConnected = true;
    } catch (_) {
      apiConnected = false;
    }
    notifyListeners();
  }

  Future<void> upsertSavedItem({
    required String itemType,
    required String itemRef,
    required String title,
    String? subtitle,
    Map<String, dynamic> meta = const <String, dynamic>{},
    bool refreshAfter = true,
  }) async {
    if (!isAuthenticated) {
      return;
    }
    DateTime? guardTime;
    for (final item in savedCloudItems) {
      if (item.itemType == itemType && item.itemRef == itemRef) {
        guardTime = item.updatedAt;
        break;
      }
    }
    await _api.upsertSavedItem(
      itemType: itemType,
      itemRef: itemRef,
      title: title,
      subtitle: subtitle,
      meta: meta,
      ifUnmodifiedSince: guardTime,
    );
    if (refreshAfter) {
      await refreshCloudSavedItems();
    }
  }

  Future<void> fetchAdPlacements() async {
    try {
      adPlacements = await _api.fetchAdPlacements();
    } catch (_) {
      adPlacements = const <AdPlacementConfig>[];
    }
    notifyListeners();
  }

  Future<List<SleepTrack>> searchTracks(String query) async {
    return _api.searchTracks(
      query,
      deviceId: deviceId,
      goal: selectedSleepGoal,
      timeSegment: _timeSegmentFor(DateTime.now()),
    );
  }

  bool adEnabled(String screen, String slotKey) {
    for (final placement in adPlacements) {
      if (placement.screen == screen &&
          placement.slotKey == slotKey &&
          placement.enabled) {
        return true;
      }
    }
    return false;
  }

  Future<void> _flushQueuedEvents() async {
    if (_queuedEvents.isEmpty) {
      return;
    }
    syncStatus = 'syncing';
    final pending = List<Map<String, dynamic>>.from(_queuedEvents);
    _queuedEvents.clear();
    for (final event in pending) {
      final sessionId = _nullableInt(event['session_id']);
      if (sessionId == null) {
        continue;
      }
      final nextAttemptRaw = event['next_attempt_at']?.toString();
      if (nextAttemptRaw != null) {
        final nextAttempt = DateTime.tryParse(nextAttemptRaw);
        if (nextAttempt != null && DateTime.now().isBefore(nextAttempt)) {
          _queuedEvents.add(event);
          continue;
        }
      }
      try {
        await _api.addSessionEvent(
          sessionId: sessionId,
          eventType: '${event['event_type'] ?? 'event'}',
          trackId: _nullableInt(event['track_id']),
        );
        syncStatus = 'ok';
        syncFailureCount = 0;
        lastSyncAt = DateTime.now();
      } catch (_) {
        final retries = (_nullableInt(event['retries']) ?? 0) + 1;
        final backoffSeconds = min(300, 5 * (1 << min(retries, 5)));
        event['retries'] = retries;
        event['next_attempt_at'] = DateTime.now().add(Duration(seconds: backoffSeconds)).toIso8601String();
        _queuedEvents.add(event);
        syncStatus = 'offline_queue';
        syncFailureCount += 1;
      }
    }
    await _persistLocalState();
    notifyListeners();
  }

  void _enqueueEvent({
    required int sessionId,
    required String eventType,
    required int? trackId,
  }) {
    final signature = '$sessionId::$eventType::${trackId ?? 0}';
    final duplicate = _queuedEvents.any((e) => '${e['signature'] ?? ''}' == signature);
    if (duplicate) {
      return;
    }
    _queuedEvents.add(<String, dynamic>{
      'signature': signature,
      'session_id': sessionId,
      'event_type': eventType,
      'track_id': trackId,
      'retries': 0,
      'next_attempt_at': DateTime.now().toIso8601String(),
    });
  }

  Future<void> _syncAnonymousStateToCloud() async {
    if (!isAuthenticated) {
      return;
    }

    for (final session in sessions.take(12)) {
      await upsertSavedItem(
        itemType: 'history_snapshot',
        itemRef: session.startedAt.toIso8601String(),
        title: 'Session ${session.startedAt.toIso8601String().split('T').first}',
        subtitle: '${session.durationMinutes} min',
        meta: <String, dynamic>{
          'started_at': session.startedAt.toIso8601String(),
          'duration_minutes': session.durationMinutes,
        },
        refreshAfter: false,
      );
    }
    await refreshCloudSavedItems();
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
      mainPlayerVolume = _player.volume;
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

  Future<void> _initNotifications() async {
    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const ios = DarwinInitializationSettings();
    const settings = InitializationSettings(android: android, iOS: ios);
    await _notifications.initialize(
      settings,
      onDidReceiveNotificationResponse: (response) async {
        if (response.id == 1122 && bedtimeRoutineEnabled && !isPlaying) {
          await startSleepNow(entryPoint: 'bedtime_notification_tap');
          await _logEvent('schedule_triggered');
        }
      },
    );
  }

  Future<void> _scheduleBedtimeNotification() async {
    await _cancelBedtimeNotification();
    final now = tz.TZDateTime.now(tz.local);
    var scheduled = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      bedtimeTime.hour,
      bedtimeTime.minute,
    );
    if (scheduled.isBefore(now)) {
      scheduled = scheduled.add(const Duration(days: 1));
    }
    await _notifications.zonedSchedule(
      1122,
      'SleepWell bedtime',
      'Time to start your routine and relax for sleep.',
      scheduled,
      const NotificationDetails(
        android: AndroidNotificationDetails(
          'sleepwell_bedtime',
          'SleepWell Bedtime',
          channelDescription: 'Daily bedtime reminder',
          importance: Importance.high,
          priority: Priority.high,
        ),
        iOS: DarwinNotificationDetails(),
      ),
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      matchDateTimeComponents: DateTimeComponents.time,
      uiLocalNotificationDateInterpretation:
          UILocalNotificationDateInterpretation.absoluteTime,
    );
  }

  Future<void> _cancelBedtimeNotification() async {
    await _notifications.cancel(1122);
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

  void _startBedtimeTicker() {
    _bedtimeTicker?.cancel();
    _bedtimeTicker = Timer.periodic(const Duration(seconds: 30), (_) async {
      if (!bedtimeRoutineEnabled || !isOnboarded || isBusy || isPlaying) {
        return;
      }

      final now = DateTime.now();
      final alreadyTriggeredThisMinute = _lastBedtimeTriggerAt != null &&
          _lastBedtimeTriggerAt!.year == now.year &&
          _lastBedtimeTriggerAt!.month == now.month &&
          _lastBedtimeTriggerAt!.day == now.day &&
          _lastBedtimeTriggerAt!.hour == now.hour &&
          _lastBedtimeTriggerAt!.minute == now.minute;

      if (alreadyTriggeredThisMinute) {
        return;
      }

      if (_queuedEvents.isNotEmpty) {
        await _flushQueuedEvents();
      }

      if (now.hour == bedtimeTime.hour && now.minute == bedtimeTime.minute) {
        _lastBedtimeTriggerAt = now;
        await startSleepNow(entryPoint: 'bedtime_scheduler');
        await _logEvent('schedule_triggered');
        return;
      }

      final scheduled = DateTime(
        now.year,
        now.month,
        now.day,
        bedtimeTime.hour,
        bedtimeTime.minute,
      );
      if (now.isAfter(scheduled.add(const Duration(minutes: 30))) && !isPlaying) {
        final alreadyLoggedToday = _lastScheduleMissedAt != null &&
            _lastScheduleMissedAt!.year == now.year &&
            _lastScheduleMissedAt!.month == now.month &&
            _lastScheduleMissedAt!.day == now.day;
        if (!alreadyLoggedToday) {
          _lastScheduleMissedAt = now;
          await _logEvent('schedule_missed');
        }
      }
    });
  }

  bool _isWithinBedtimeAdherenceWindow(DateTime now) {
    final scheduled = DateTime(
      now.year,
      now.month,
      now.day,
      bedtimeTime.hour,
      bedtimeTime.minute,
    );
    final delta = now.difference(scheduled).inMinutes.abs();
    return delta <= 30;
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
    _bedtimeTicker?.cancel();
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
  int _index = 0;
  final Map<String, dynamic> _answers = <String, dynamic>{};
  final Set<String> _multiSelection = <String>{};
  final TextEditingController _emailController = TextEditingController();
  double _sliderValue = 8;

  OnboardingStepContent get _step {
    final screens = widget.state.onboardingScreens;
    if (screens.isEmpty) {
      return _fallbackOnboardingScreens.first;
    }
    final safeIndex = _index.clamp(0, screens.length - 1);
    return screens[safeIndex];
  }

  int get _totalSteps {
    final screens = widget.state.onboardingScreens;
    return screens.isEmpty ? _fallbackOnboardingScreens.length : screens.length;
  }

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Widget _buildStepContent() {
    final step = _step;
    final titleStyle = const TextStyle(
      color: Colors.white,
      fontSize: 36,
      fontWeight: FontWeight.w800,
      height: 1.2,
    );
    final subtitleStyle = const TextStyle(
      color: Colors.white70,
      fontSize: 20,
      height: 1.3,
    );

    switch (step.screenType) {
      case 'welcome':
        return Padding(
          padding: const EdgeInsets.only(top: 70),
          child: Column(
            children: [
              const Icon(Icons.nights_stay_rounded, size: 72, color: Color(0xFFE7B86C)),
              const SizedBox(height: 20),
              Text(step.title, style: titleStyle, textAlign: TextAlign.center),
              if (step.subtitle != null) ...[
                const SizedBox(height: 18),
                Text(step.subtitle!, style: subtitleStyle, textAlign: TextAlign.center),
              ],
              const SizedBox(height: 70),
              GestureDetector(
                onTap: () => _goNextStep(),
                child: Container(
                  height: 94,
                  width: 94,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white,
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.15),
                        blurRadius: 25,
                        spreadRadius: 8,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.arrow_forward, color: Colors.black, size: 34),
                ),
              ),
              const SizedBox(height: 46),
              const Text(
                'I already have an account. Sign In',
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
              const SizedBox(height: 18),
              const Text(
                'Privacy Policy   |   Terms of Service',
                style: TextStyle(color: Colors.white54, fontSize: 13),
              ),
            ],
          ),
        );
      case 'slider':
        _sliderValue = _answers[step.stepKey] is num
            ? (_answers[step.stepKey] as num).toDouble()
            : step.sliderDefault.toDouble();
        return _buildQuestionWrapper(
          step,
          child: Column(
            children: [
              const SizedBox(height: 40),
              Text(
                '${_sliderValue.round()}h',
                style: const TextStyle(fontSize: 52, fontWeight: FontWeight.w800),
              ),
              Slider(
                value: _sliderValue,
                min: step.sliderMin.toDouble(),
                max: step.sliderMax.toDouble(),
                divisions: step.sliderMax - step.sliderMin,
                onChanged: (v) => setState(() {
                  _sliderValue = v;
                  _answers[step.stepKey] = v.round();
                }),
              ),
            ],
          ),
        );
      case 'multi_choice':
        final selected = (_answers[step.stepKey] as List<dynamic>?)?.map((e) => '$e').toSet() ??
            _multiSelection;
        return _buildQuestionWrapper(
          step,
          child: Column(
            children: step.choiceItems
                .map((choice) => _optionTile(
                      title: choice.label,
                      emoji: choice.emoji,
                      iconUrl: choice.iconUrl,
                      selected: selected.contains(choice.label),
                      onTap: () {
                        setState(() {
                          if (selected.contains(choice.label)) {
                            selected.remove(choice.label);
                          } else {
                            selected.add(choice.label);
                          }
                          _answers[step.stepKey] = selected.toList();
                        });
                      },
                    ))
                .toList(),
          ),
        );
      case 'email':
        _emailController.text = (_answers[step.stepKey] ?? '').toString();
        return _buildQuestionWrapper(
          step,
          child: Column(
            children: [
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                onChanged: (v) => _answers[step.stepKey] = v.trim(),
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  hintText: 'Email',
                  hintStyle: TextStyle(color: Colors.white54),
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withValues(alpha: 0.06),
                ),
                child: const Text(
                  'No spam, no ads. Just better sleep.',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            ],
          ),
        );
      case 'info':
        final stats = (step.options['stats'] as List<dynamic>? ?? const <dynamic>[])
            .map(_coerceStatCard)
            .toList();
        return _buildQuestionWrapper(
          step,
          child: Column(
            children: [
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: stats.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 1.05,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                ),
                itemBuilder: (_, i) {
                  final item = stats[i];
                  return Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(color: const Color(0xFFE7B86C), width: 1.3),
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.05),
                          Colors.white.withValues(alpha: 0.01),
                        ],
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          item.headline,
                          style: const TextStyle(
                            color: Color(0xFFE7B86C),
                            fontSize: 24,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                        ),
                        Text(
                          item.subline,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            height: 1.2,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 14),
              const Text(
                'Preparing your sleep plan',
                style: TextStyle(color: Colors.white70, fontSize: 18),
              ),
            ],
          ),
        );
      case 'single_choice':
      default:
        final selected = _answers[step.stepKey]?.toString();
        return _buildQuestionWrapper(
          step,
          child: Column(
            children: step.choiceItems
                .map(
                  (choice) => _optionTile(
                    title: choice.label,
                    emoji: choice.emoji,
                    iconUrl: choice.iconUrl,
                    selected: selected == choice.label,
                    onTap: () async {
                      setState(() => _answers[step.stepKey] = choice.label);
                      await _goNextStep();
                    },
                  ),
                )
                .toList(),
          ),
        );
    }
  }

  Widget _buildQuestionWrapper(OnboardingStepContent step, {required Widget child}) {
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        children: [
          Text(
            step.title,
            style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800, color: Colors.white),
            textAlign: TextAlign.center,
          ),
          if (step.subtitle != null && step.subtitle!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              step.subtitle!,
              style: const TextStyle(fontSize: 20, color: Colors.white70),
              textAlign: TextAlign.center,
            ),
          ],
          const SizedBox(height: 24),
          child,
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _optionTile({
    required String title,
    String? emoji,
    String? iconUrl,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 170),
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            color: selected ? const Color(0x332C3EFF) : Colors.white.withValues(alpha: 0.02),
            border: Border.all(
              color: selected ? const Color(0xFFE7B86C) : Colors.white.withValues(alpha: 0.18),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontSize: 22,
                    color: Colors.white,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (iconUrl != null && iconUrl.trim().isNotEmpty)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(
                    _normalizeMediaUrl(iconUrl, apiBaseUrl: SleepWellApi.baseUrl),
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                  ),
                )
              else if (emoji != null && emoji.isNotEmpty)
                Text(
                  emoji,
                  style: const TextStyle(fontSize: 30),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String? _resolvedOnboardingImageUrl(OnboardingStepContent step) {
    final raw = step.imageUrl;
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return _normalizeMediaUrl(raw, apiBaseUrl: SleepWellApi.baseUrl);
  }

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final stepImage = _resolvedOnboardingImageUrl(step);

    return Scaffold(
      body: Stack(
        children: [
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF1A223A), Color(0xFF07090F), Color(0xFF010203)],
              ),
            ),
          ),
          if (stepImage != null)
            Positioned.fill(
              child: Image.network(
                stepImage,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          Positioned.fill(
            child: Container(
              color: Colors.black.withValues(alpha: stepImage == null ? 0.12 : 0.45),
            ),
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        '${_index + 1}/$_totalSteps',
                        style: const TextStyle(color: Colors.white70),
                      ),
                      if (_step.skippable)
                        TextButton(
                          onPressed: () => _goNextStep(skipped: true),
                          child: const Text('Skip'),
                        )
                      else
                        const SizedBox(width: 56),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      minHeight: 4,
                      value: (_index + 1) / _totalSteps,
                      backgroundColor: Colors.white.withValues(alpha: 0.14),
                      valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFE7B86C)),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: SingleChildScrollView(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 280),
                        switchInCurve: Curves.easeOutCubic,
                        switchOutCurve: Curves.easeInCubic,
                        transitionBuilder: (child, animation) {
                          final slide = Tween<Offset>(
                            begin: const Offset(0.06, 0),
                            end: Offset.zero,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: SlideTransition(position: slide, child: child),
                          );
                        },
                        child: KeyedSubtree(
                          key: ValueKey<String>(_step.stepKey),
                          child: _buildStepContent(),
                        ),
                      ),
                    ),
                  ),
                  if (_step.screenType != 'single_choice')
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: _canContinue() && !widget.state.isBusy
                            ? () => _goNextStep()
                            : null,
                        child: Text(widget.state.isBusy ? 'Saving...' : _step.ctaLabel),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  bool _canContinue() {
    final step = _step;
    switch (step.screenType) {
      case 'welcome':
      case 'info':
        return true;
      case 'multi_choice':
        return (_answers[step.stepKey] as List<dynamic>?)?.isNotEmpty == true;
      case 'slider':
        return true;
      case 'email':
        final value = (_answers[step.stepKey] ?? '').toString().trim();
        return value.isEmpty || value.contains('@');
      case 'single_choice':
      default:
        return _answers[step.stepKey] != null;
    }
  }

  Future<void> _goNextStep({bool skipped = false}) async {
    if (!skipped && !_canContinue()) {
      return;
    }
    if (_index < _totalSteps - 1) {
      setState(() => _index++);
      return;
    }

    final onboardingGoals =
        (_answers['help_goal'] as List<dynamic>? ?? const <dynamic>[]).map((e) => '$e').toList();
    final chosenSatisfaction = (_answers['sleep_satisfaction'] ?? '').toString().toLowerCase();
    final chosenHours = (_answers['desired_sleep_hours'] as num?)?.toInt() ?? 8;
    final talking = onboardingGoals.any((g) => g.toLowerCase().contains('focus'));

    final categories = <String>[
      if (onboardingGoals.any((g) => g.toLowerCase().contains('relax'))) 'rain',
      if (onboardingGoals.any((g) => g.toLowerCase().contains('anxiety'))) 'whisper',
      if (onboardingGoals.any((g) => g.toLowerCase().contains('focus'))) 'no_talking',
      if (onboardingGoals.any((g) => g.toLowerCase().contains('kids'))) 'roleplay',
    ];

    final soundTypes = <String>[
      if (chosenHours <= 6) 'brown_noise',
      if (chosenHours >= 8) 'nature',
      if (chosenSatisfaction.contains('unsatisfied')) 'story',
      if (onboardingGoals.any((g) => g.toLowerCase().contains('stress'))) 'rain',
    ];

    var difficulty = 3;
    if (chosenSatisfaction.contains('very unsatisfied')) {
      difficulty = 5;
    } else if (chosenSatisfaction.contains('unsatisfied')) {
      difficulty = 4;
    } else if (chosenSatisfaction.contains('very satisfied')) {
      difficulty = 2;
    }

    await widget.state.completeOnboarding(
      talking: talking,
      difficulty: difficulty,
      categories: categories.isEmpty ? <String>['rain', 'no_talking'] : categories.toSet().toList(),
      soundTypes: soundTypes.isEmpty ? <String>['nature'] : soundTypes.toSet().toList(),
      answers: _answers,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Your personalized sleep plan is ready.')),
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
  bool showProfile = false;
  bool showSettings = false;

  @override
  Widget build(BuildContext context) {
    final pages = [
      HomeHubPage(
        state: widget.state,
        onOpenProfile: () => setState(() => showProfile = true),
        onNavigateTab: (tabIndex) => setState(() {
          index = tabIndex;
          showProfile = false;
          showSettings = false;
        }),
      ),
      PlayerPage(state: widget.state),
      RoutinePage(state: widget.state),
      InsightsPage(state: widget.state),
      SavedPage(state: widget.state),
    ];
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    const Color(0xFF1E2343).withValues(alpha: 0.55),
                    const Color(0xFF0C101F),
                    const Color(0xFF090C18),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            top: true,
            bottom: false,
            child: Column(
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
                Expanded(
                  child: showProfile
                      ? (showSettings
                            ? SettingsPage(
                                state: widget.state,
                                onBack: () => setState(() => showSettings = false),
                              )
                            : ProfilePage(
                                state: widget.state,
                                onBack: () => setState(() => showProfile = false),
                                onOpenSettings: () => setState(() => showSettings = true),
                              ))
                      : pages[index],
                ),
              ],
            ),
          ),
          if (widget.state.selectedTrack != null)
            Positioned(
              left: 14,
              right: 14,
              bottom: _UiBaseline.savedMiniPlayerBottomGap,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF4951B9), Color(0xFF6A45BF)],
                  ),
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 16,
                      offset: const Offset(0, 6),
                    ),
                  ],
                ),
                child: ListTile(
                  dense: true,
                  onTap: () {
                    final track = widget.state.selectedTrack;
                    if (track == null) {
                      return;
                    }
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => NowPlayingPage(state: widget.state, track: track),
                      ),
                    );
                  },
                  leading: Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(Icons.music_note_rounded, color: Colors.white),
                  ),
                  title: Text(
                    widget.state.selectedTrack!.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                  ),
                  subtitle: const Text(
                    'My Favorite Mix',
                    style: TextStyle(color: Colors.white70),
                  ),
                  trailing: IconButton(
                    icon: Icon(
                      widget.state.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                    ),
                    onPressed: () async {
                      await widget.state.togglePlayPause();
                    },
                  ),
                ),
              ),
            ),
          IgnorePointer(
            ignoring: true,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 500),
              opacity: widget.state.isScreenDimmed ? 0.35 : 0.0,
              child: Container(color: Colors.black),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          height: 78,
          margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          decoration: BoxDecoration(
            color: const Color(0xFF0A0E1A).withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 20,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(i: 0, icon: Icons.home_rounded, label: 'Home'),
              _navItem(i: 1, icon: Icons.music_note_rounded, label: 'Sounds'),
              _navItem(i: 2, icon: Icons.nights_stay_rounded, label: 'Routine', emphasize: true),
              _navItem(i: 3, icon: Icons.bar_chart_rounded, label: 'Insights'),
              _navItem(i: 4, icon: Icons.favorite_border_rounded, label: 'Saved'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem({
    required int i,
    required IconData icon,
    required String label,
    bool emphasize = false,
  }) {
    final selected = index == i;
    final iconWidget = emphasize
        ? Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: selected
                    ? const [Color(0xFF5D5EFF), Color(0xFF3E47F2)]
                    : const [Color(0xFF2B2E55), Color(0xFF1F2345)],
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF5D5EFF).withValues(alpha: 0.35),
                        blurRadius: 12,
                      ),
                    ]
                  : null,
            ),
            child: Icon(icon, color: Colors.white),
          )
        : Icon(icon, color: selected ? Colors.white : Colors.white60);

    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: () => setState(() {
          index = i;
          showProfile = false;
          showSettings = false;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              iconWidget,
              const SizedBox(height: 3),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: selected ? Colors.white : Colors.white54,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class HomeHubPage extends StatefulWidget {
  const HomeHubPage({
    super.key,
    required this.state,
    required this.onOpenProfile,
    required this.onNavigateTab,
  });
  final SleepWellState state;
  final VoidCallback onOpenProfile;
  final ValueChanged<int> onNavigateTab;

  @override
  State<HomeHubPage> createState() => _HomeHubPageState();
}

class _HomeHubPageState extends State<HomeHubPage> {
  late final PageController _featuredController;
  Timer? _featuredTicker;
  int _featuredIndex = 0;
  int _featuredItemCount = 0;

  @override
  void initState() {
    super.initState();
    _featuredController = PageController(viewportFraction: 0.94);
  }

  @override
  void dispose() {
    _featuredTicker?.cancel();
    _featuredController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final featured = state.sectionByKey('featured_content');
    final explore = state.sectionByKey('explore_grid');
    final therapyPromo = state.sectionByKey('promo_therapy');
    final sleepRecorder = state.sectionByKey('sleep_recorder');
    final coloredNoises = state.sectionByKey('colored_noises');
    final topRated = state.sectionByKey('top_rated');
    final quickTopics = state.sectionByKey('quick_topics');
    final discover = state.sectionByKey('discover_banner');
    final trySomethingElse = state.sectionByKey('try_something_else');
    final curatedPlaylists = state.sectionByKey('curated_playlists');
    final sleepHypnosis = state.sectionByKey('sleep_hypnosis');

    final featuredItems = featured?.items ?? const <HomeItemContent>[];
    _ensureFeaturedTicker(featuredItems.length);

    return RefreshIndicator(
      onRefresh: () => state.fetchHomeFeed(),
      child: ListView(
        physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 180),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Good evening',
                  style: TextStyle(fontSize: 38, fontWeight: FontWeight.w800),
                ),
              ),
              IconButton(
                onPressed: _openTrackSearch,
                icon: const Icon(Icons.search_rounded),
              ),
              IconButton(
                onPressed: widget.onOpenProfile,
                icon: const Icon(Icons.account_circle_rounded),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: InkWell(
              borderRadius: BorderRadius.circular(999),
              onTap: () {
                widget.onNavigateTab(3);
                _showHomeSnack('Sleep Recorder opened in Insights.');
              },
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.graphic_eq, color: Colors.black87, size: 18),
                      SizedBox(width: 8),
                      Text('Recorder', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text('My mixes', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          SizedBox(
            height: 84,
            child: ListView(
              physics: const BouncingScrollPhysics(),
              scrollDirection: Axis.horizontal,
              children: [
                _mixBubble(
                  icon: Icons.add,
                  onTap: () async {
                    await state.saveCurrentMixPreset();
                    if (!mounted) {
                      return;
                    }
                    _showHomeSnack('Current mixer levels saved as preset.');
                  },
                ),
                const SizedBox(width: 10),
                _mixPill(
                  title: state.mixerPresets.isEmpty ? 'Your First Mix' : state.mixerPresets.first.name,
                  isPlaying: state.isMixerPlaying || state.isPlaying,
                  onTap: () async {
                    if (state.mixerPresets.isNotEmpty) {
                      await state.applyMixPreset(state.mixerPresets.first);
                    }
                    await state.toggleMixerPlayback();
                    if (!mounted) {
                      return;
                    }
                    _showHomeSnack(state.isMixerPlaying ? 'Mixer started.' : 'Mixer stopped.');
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Colors.white12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Your sleep goal', style: TextStyle(color: Colors.white70)),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    value: state.selectedSleepGoal,
                    items: state.sleepGoals
                        .map((goal) => DropdownMenuItem<String>(value: goal, child: Text(goal)))
                        .toList(),
                    dropdownColor: const Color(0xFF111118),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white24),
                      ),
                    ),
                    onChanged: (value) {
                      if (value != null) {
                        state.setSelectedSleepGoal(value);
                      }
                    },
                  ),
                ],
              ),
            ),
          ),
          if (state.adEnabled('home', 'feed_banner'))
            const Padding(
              padding: EdgeInsets.only(top: 12),
              child: AdBannerSlot(),
            ),
          const SizedBox(height: 20),
          _sectionHeader(featured?.title ?? 'Featured content'),
          const SizedBox(height: 10),
          SizedBox(
            height: 148,
            child: PageView.builder(
              controller: _featuredController,
              itemCount: featuredItems.isEmpty ? 1 : featuredItems.length,
              onPageChanged: (idx) => setState(() => _featuredIndex = idx),
              itemBuilder: (_, i) {
                final item = featuredItems.isEmpty
                    ? const HomeItemContent(title: 'Night Session', subtitle: 'Relax and drift to sleep')
                    : featuredItems[i];
                final isActive = i == _featuredIndex;
                return Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: AnimatedScale(
                    duration: const Duration(milliseconds: 260),
                    curve: Curves.easeOutCubic,
                    scale: isActive ? 1.0 : 0.96,
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 260),
                      opacity: isActive ? 1.0 : 0.82,
                      child: _heroCard(item: item),
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(max(1, featuredItems.length), (idx) {
                final active = _featuredIndex == idx;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  width: active ? 20 : 7,
                  height: 7,
                  margin: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: active ? Colors.white : Colors.white30,
                    borderRadius: BorderRadius.circular(99),
                  ),
                );
              }),
            ),
          ),
          const SizedBox(height: 18),
          _sectionHeader(explore?.title ?? 'Explore more'),
          const SizedBox(height: 12),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              childAspectRatio: 1.25,
            ),
            itemCount: (explore?.items.length ?? 0).clamp(0, 6),
            itemBuilder: (_, i) {
              final item = explore!.items[i];
              return InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => _handleExploreTap(item),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(item.emoji ?? '✨', style: const TextStyle(fontSize: 20)),
                      const SizedBox(height: 6),
                      Text(item.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
              );
            },
          ),
          if (therapyPromo != null && therapyPromo.items.isNotEmpty) ...[
            const SizedBox(height: 20),
            _sectionHeader(therapyPromo.title ?? 'Still waking up tired?'),
            const SizedBox(height: 10),
            _promoCard(
              headline: therapyPromo.items.first.title,
              description: therapyPromo.items.first.subtitle ?? '',
              cta: therapyPromo.items.first.ctaLabel ?? 'Learn more',
              accent: const Color(0xFF2BD8C7),
              onPressed: widget.onOpenProfile,
            ),
          ],
          if (sleepRecorder != null && sleepRecorder.items.isNotEmpty) ...[
            const SizedBox(height: 18),
            _sleepRecorderCard(
              sleepRecorder,
              onPressed: () {
                widget.onNavigateTab(3);
                _showHomeSnack('Track My Sleep opened in Insights.');
              },
            ),
          ],
          if (coloredNoises != null) ...[
            const SizedBox(height: 20),
            Row(
              children: [
                Expanded(child: _sectionHeader(coloredNoises.title ?? 'Colored Noises')),
                TextButton(
                  onPressed: () => widget.onNavigateTab(1),
                  child: const Text('See all'),
                ),
              ],
            ),
            if ((coloredNoises.subtitle ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 8),
                child: Text(coloredNoises.subtitle!, style: const TextStyle(color: Colors.white70)),
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: coloredNoises.items
                  .map(
                    (item) => ActionChip(
                      onPressed: () => _playBestMatchTrack(item.title),
                      label: Text(item.title),
                      avatar: const Icon(Icons.graphic_eq_rounded, size: 16),
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      side: const BorderSide(color: Colors.white24),
                    ),
                  )
                  .toList(),
            ),
          ],
          if (topRated != null) ...[
            const SizedBox(height: 18),
            _sectionHeader(topRated.title ?? 'Top 5 rated'),
            const SizedBox(height: 8),
            ...topRated.items.map(
              (item) => InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => _playBestMatchTrack(item.title),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 36,
                        child: Text(
                          '${item.rank == 0 ? topRated.items.indexOf(item) + 1 : item.rank}',
                          style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: Color(0xFFE5C065)),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(10),
                          gradient: const LinearGradient(
                            colors: [Color(0xFF24598D), Color(0xFF123A5B)],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                            Text(item.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
          if (quickTopics != null && quickTopics.items.isNotEmpty) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 42,
              child: ListView(
                physics: const BouncingScrollPhysics(),
                scrollDirection: Axis.horizontal,
                children: quickTopics.items
                    .map(
                      (item) => InkWell(
                        borderRadius: BorderRadius.circular(999),
                        onTap: () => _playBestMatchTrack(item.title),
                        child: Container(
                          margin: const EdgeInsets.only(right: 8),
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(999),
                            border: Border.all(color: Colors.white24),
                            color: Colors.black.withValues(alpha: 0.18),
                          ),
                          alignment: Alignment.center,
                          child: Text('${item.emoji ?? '•'}  ${item.title}', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    )
                    .toList(),
              ),
            ),
          ],
          if (discover != null && discover.items.isNotEmpty) ...[
            const SizedBox(height: 18),
            _discoverBanner(
              discover.items.first,
              onTap: () {
                widget.onNavigateTab(1);
                _showHomeSnack('Explore more sounds in Sounds.');
              },
            ),
          ],
          if (trySomethingElse != null) _horizontalSection(trySomethingElse),
          if (curatedPlaylists != null) _horizontalSection(curatedPlaylists),
          if (sleepHypnosis != null) _horizontalSection(sleepHypnosis),
        ],
      ),
    );
  }

  void _ensureFeaturedTicker(int itemCount) {
    if (_featuredItemCount == itemCount && (_featuredTicker != null || itemCount <= 1)) {
      return;
    }
    _featuredItemCount = itemCount;
    _featuredTicker?.cancel();
    _featuredTicker = null;
    if (itemCount <= 1) {
      return;
    }
    _featuredTicker = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || !_featuredController.hasClients) {
        return;
      }
      final nextIndex = (_featuredIndex + 1) % itemCount;
      _featuredController.animateToPage(
        nextIndex,
        duration: const Duration(milliseconds: 560),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Widget _sectionHeader(String text) {
    return Text(text, style: const TextStyle(fontSize: 31, fontWeight: FontWeight.w700, letterSpacing: -0.2));
  }

  Widget _heroCard({required HomeItemContent item}) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _playBestMatchTrack(item.title),
      child: Container(
        width: 300,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [Color(0xFF24327F), Color(0xFF4D63D4)]),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF4D63D4).withValues(alpha: 0.24),
              blurRadius: 18,
              offset: const Offset(0, 7),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const Spacer(),
            Text(item.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 6),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
              onPressed: () => _playBestMatchTrack(item.title),
              child: Text(item.ctaLabel ?? 'Listen'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _promoCard({
    required String headline,
    required String description,
    required String cta,
    required Color accent,
    required VoidCallback onPressed,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(colors: [Color(0xFF1A3550), Color(0xFF12263A)]),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(headline, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text(description, style: const TextStyle(color: Colors.white70)),
          const SizedBox(height: 14),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: accent, foregroundColor: Colors.black),
            onPressed: onPressed,
            child: Text(cta),
          ),
        ],
      ),
    );
  }

  Widget _sleepRecorderCard(HomeSectionContent section, {required VoidCallback onPressed}) {
    final card = section.items.first;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        gradient: const LinearGradient(colors: [Color(0xFF19181F), Color(0xFF141321)]),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(section.title ?? 'Sleep Recorder', style: const TextStyle(color: Color(0xFFE3B260), fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(card.title, style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800)),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(card.subtitle ?? '', style: const TextStyle(color: Colors.white70)),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                onPressed: onPressed,
                child: Text(card.ctaLabel ?? 'Start Recorder'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _discoverBanner(HomeItemContent item, {required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          gradient: const LinearGradient(colors: [Color(0xFF3E2D20), Color(0xFF201410)]),
        ),
        child: Center(
          child: Text(
            item.title.toUpperCase(),
            style: const TextStyle(
              letterSpacing: 3.4,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _horizontalSection(HomeSectionContent section) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18, top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionHeader(section.title ?? ''),
          if ((section.subtitle ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(section.subtitle!, style: const TextStyle(color: Colors.white70)),
            ),
          const SizedBox(height: 10),
          SizedBox(
            height: 170,
            child: ListView(
              physics: const BouncingScrollPhysics(),
              scrollDirection: Axis.horizontal,
              children: section.items
                  .map(
                    (item) => InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _playBestMatchTrack(item.title),
                      child: Container(
                        width: 170,
                        margin: const EdgeInsets.only(right: 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(16),
                                child: Container(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  child: item.imageUrl == null
                                      ? const Center(child: Icon(Icons.nights_stay_rounded))
                                      : Image.network(
                                          item.imageUrl!,
                                          fit: BoxFit.cover,
                                          width: double.infinity,
                                          errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
                                        ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
                            Text(item.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  void _playBestMatchTrack(String query) {
    final tracks = widget.state.tracks;
    if (tracks.isEmpty) {
      return;
    }
    final queryLower = query.toLowerCase();
    SleepTrack? selected;
    for (final track in tracks) {
      final titleLower = track.title.toLowerCase();
      if (titleLower.contains(queryLower) || queryLower.contains(titleLower)) {
        selected = track;
        break;
      }
    }
    selected ??= tracks.first;
    unawaited(widget.state.playTrack(selected));
  }

  Widget _mixBubble({required IconData icon, required VoidCallback onTap}) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: 84,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.04),
          border: Border.all(color: Colors.white12),
        ),
        child: Icon(icon, size: 30),
      ),
    );
  }

  Widget _mixPill({
    required String title,
    required bool isPlaying,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Container(
        width: 280,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white54),
        ),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            child: const Icon(Icons.tune_rounded),
          ),
          title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
      ),
    );
  }

  Future<void> _openTrackSearch() async {
    var tracks = widget.state.tracks;
    try {
      final remote = await widget.state.searchTracks('');
      if (remote.isNotEmpty) {
        tracks = remote;
      }
    } catch (_) {
      // Keep local fallback tracks.
    }
    if (!mounted) {
      return;
    }
    await showSearch<SleepTrack?>(
      context: context,
      delegate: _TrackSearchDelegate(tracks: tracks),
    ).then((selected) {
      if (selected != null) {
        unawaited(widget.state.playTrack(selected));
      }
    });
  }

  void _handleExploreTap(HomeItemContent item) {
    final action = '${item.meta['action'] ?? ''}'.toLowerCase();
    final targetTab = _nullableInt(item.meta['target_tab']);
    if (action == 'navigate_tab' && targetTab != null) {
      widget.onNavigateTab(targetTab.clamp(0, 4));
      return;
    }
    if (action == 'open_profile') {
      widget.onOpenProfile();
      return;
    }
    if (action == 'start_sleep_now') {
      unawaited(widget.state.startSleepNow(entryPoint: 'home_explore_action'));
      return;
    }
    if (action == 'open_insights') {
      widget.onNavigateTab(3);
      return;
    }
    if (action == 'open_routine') {
      widget.onNavigateTab(2);
      return;
    }
    if (action == 'open_saved') {
      widget.onNavigateTab(4);
      return;
    }
    if (action == 'open_sounds') {
      widget.onNavigateTab(1);
      return;
    }
    final deepLink = item.meta['deep_link']?.toString();
    if (action == 'play_track' && deepLink != null && deepLink.isNotEmpty) {
      _playBestMatchTrack(deepLink);
      return;
    }
    _playBestMatchTrack(item.title);
  }

  void _showHomeSnack(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _TrackSearchDelegate extends SearchDelegate<SleepTrack?> {
  _TrackSearchDelegate({required this.tracks});

  final List<SleepTrack> tracks;

  @override
  String get searchFieldLabel => 'Search sounds, mixes, music...';

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        onPressed: () => query = '',
        icon: const Icon(Icons.close_rounded),
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      onPressed: () => close(context, null),
      icon: const Icon(Icons.arrow_back_ios_new_rounded),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    final results = _filteredTracks(query);
    if (results.isEmpty) {
      return const Center(child: Text('No matching track found.'));
    }
    return _resultList(context, results);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    final suggestions = query.trim().isEmpty ? tracks.take(10).toList() : _filteredTracks(query);
    return _resultList(context, suggestions);
  }

  Widget _resultList(BuildContext context, List<SleepTrack> items) {
    return ListView.separated(
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (_, idx) {
        final track = items[idx];
        return ListTile(
          title: Text(track.title),
          subtitle: Text('${track.category} • ${track.talking ? 'Talking' : 'No talking'}'),
          onTap: () => close(context, track),
        );
      },
    );
  }

  List<SleepTrack> _filteredTracks(String q) {
    final lower = q.trim().toLowerCase();
    if (lower.isEmpty) {
      return tracks;
    }
    return tracks.where((track) {
      return track.title.toLowerCase().contains(lower) ||
          track.category.toLowerCase().contains(lower);
    }).toList();
  }
}

class SavedPage extends StatefulWidget {
  const SavedPage({super.key, required this.state});
  final SleepWellState state;

  @override
  State<SavedPage> createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
  int _tabIndex = 0;

  static const List<String> _tabs = <String>['Favorites', 'Recently Played', 'Playlists'];

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final favorites = state.sectionByKey('saved_favorites');
    final recentlyPlayed = state.sectionByKey('saved_recently_played');
    final playlists = state.sectionByKey('saved_playlists');
    final findLove = state.sectionByKey('saved_find_love');
    final suggestions = state.sectionByKey('saved_suggestions');
    final activeSection = switch (_tabIndex) {
      0 => state.isAuthenticated && state.savedCloudItems.isNotEmpty
          ? HomeSectionContent(
              sectionKey: 'saved_cloud_favorites',
              title: 'Favorites',
              subtitle: null,
              sectionType: 'horizontal',
              items: state.savedCloudItems
                  .map(
                    (item) => HomeItemContent(
                      title: item.title,
                      subtitle: item.subtitle,
                      meta: item.meta,
                    ),
                  )
                  .toList(),
            )
          : favorites,
      1 => recentlyPlayed,
      _ => playlists,
    };
    final showFindLoveGrid = _tabIndex != 0;

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1F1934), Color(0xFF0D0F1D), Color(0xFF090C18)],
              ),
            ),
          ),
        ),
        ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(_UiBaseline.pageHorizontal, 6, _UiBaseline.pageHorizontal, 190),
          children: [
            const SizedBox(height: 6),
            const Center(
              child: Text(
                'My Library',
                style: TextStyle(fontSize: _UiBaseline.savedTitleSize, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: _UiBaseline.savedTabHeight,
              child: ListView.separated(
                physics: const BouncingScrollPhysics(),
                scrollDirection: Axis.horizontal,
                itemCount: _tabs.length,
                separatorBuilder: (_, __) => const SizedBox(width: 10),
                itemBuilder: (_, idx) {
                  final selected = idx == _tabIndex;
                  return InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () => setState(() => _tabIndex = idx),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 170),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: selected ? Colors.white : Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: selected ? Colors.white : Colors.white24, width: 1.4),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _tabs[idx],
                        style: TextStyle(
                          color: selected ? Colors.black : Colors.white,
                          fontWeight: FontWeight.w700,
                          fontSize: _UiBaseline.savedTabFontSize,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            if ((activeSection?.subtitle ?? '').isNotEmpty) ...[
              Text(
                activeSection!.subtitle!,
                style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.2),
              ),
              const SizedBox(height: 6),
            ],
            if (activeSection != null)
              ...activeSection.items.map((item) => _libraryRow(item: item, tabIndex: _tabIndex, state: state))
            else
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 18),
                child: Text('No saved items yet.', style: TextStyle(color: Colors.white70)),
              ),
            if (_tabIndex == 0 && suggestions != null && suggestions.items.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                suggestions.title ?? 'Suggestions for you',
                style: const TextStyle(fontSize: _UiBaseline.savedSectionTitleSize, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              ),
              const SizedBox(height: 8),
              ...suggestions.items.map((item) => _libraryRow(item: item, tabIndex: _tabIndex, state: state)),
            ],
            if (showFindLoveGrid && findLove != null && findLove.items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                findLove.title ?? 'Find something you love',
                style: const TextStyle(fontSize: _UiBaseline.savedSectionTitleSize, fontWeight: FontWeight.w800, letterSpacing: -0.5),
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: findLove.items.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                  childAspectRatio: 1.0,
                ),
                itemBuilder: (_, idx) => _suggestionCard(findLove.items[idx], state),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _libraryRow({
    required HomeItemContent item,
    required int tabIndex,
    required SleepWellState state,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _playBestMatchTrack(state, item.title),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: _UiBaseline.savedThumbSize,
                height: _UiBaseline.savedThumbSize,
                child: item.imageUrl == null
                    ? _savedArtworkThumb(item.title, compact: true)
                    : Image.network(
                        item.imageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _savedArtworkThumb(item.title, compact: true),
                      ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: _UiBaseline.savedRowTitleSize,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.25,
                    ),
                  ),
                  if ((item.subtitle ?? '').isNotEmpty)
                    Text(
                      item.subtitle!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: _UiBaseline.savedRowSubtitleSize,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _trailingAction(item: item, tabIndex: tabIndex),
          ],
        ),
      ),
    );
  }

  Widget _trailingAction({required HomeItemContent item, required int tabIndex}) {
    final action = (item.meta['action']?.toString() ?? '').toLowerCase();
    if (action == 'arrow') {
      return const Icon(Icons.chevron_right_rounded, size: 24);
    }
    if (action == 'heart') {
      return const Icon(Icons.favorite_border_rounded, size: 22);
    }
    if (action == 'none') {
      return const SizedBox(width: 24, height: 24);
    }
    if (tabIndex == 2) {
      return const Icon(Icons.chevron_right_rounded, size: 24);
    }
    final title = item.title.toLowerCase();
    final subtitle = (item.subtitle ?? '').toLowerCase();
    if (subtitle.contains('mix') || title.contains('mix')) {
      return const Icon(Icons.favorite_border_rounded, size: 22);
    }
    return const Icon(Icons.more_horiz_rounded, size: 24);
  }

  Widget _suggestionCard(HomeItemContent item, SleepWellState state) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => _playBestMatchTrack(state, item.title),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withValues(alpha: 0.04),
          border: Border.all(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Spacer(),
              _savedArtworkThumb(item.title, compact: false),
              const SizedBox(height: 16),
              Text(
                item.title,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, letterSpacing: -0.3),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _savedArtworkThumb(String title, {required bool compact}) {
    final spec = _savedArtSpec(title);
    final iconSize = compact ? 28.0 : 44.0;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: spec.colors,
        ),
      ),
      child: Stack(
        children: [
          Positioned(
            right: -8,
            top: -8,
            child: Icon(spec.secondaryIcon, size: compact ? 24 : 36, color: Colors.white.withValues(alpha: 0.2)),
          ),
          Center(
            child: Icon(spec.primaryIcon, size: iconSize, color: Colors.white.withValues(alpha: 0.9)),
          ),
        ],
      ),
    );
  }

  _SavedArtSpec _savedArtSpec(String title) {
    final key = title.toLowerCase();
    if (key.contains('mix')) {
      return const _SavedArtSpec(
        colors: <Color>[Color(0xFF2D5AB6), Color(0xFF17316B)],
        primaryIcon: Icons.graphic_eq_rounded,
        secondaryIcon: Icons.tune_rounded,
      );
    }
    if (key.contains('sleeptale') || key.contains('galileo') || key.contains('underwater')) {
      return const _SavedArtSpec(
        colors: <Color>[Color(0xFF2A4D8A), Color(0xFF15223E)],
        primaryIcon: Icons.menu_book_rounded,
        secondaryIcon: Icons.auto_stories_rounded,
      );
    }
    if (key.contains('meditation') || key.contains('present') || key.contains('insomnia')) {
      return const _SavedArtSpec(
        colors: <Color>[Color(0xFF2E8A6F), Color(0xFF173F35)],
        primaryIcon: Icons.self_improvement_rounded,
        secondaryIcon: Icons.spa_rounded,
      );
    }
    if (key.contains('music')) {
      return const _SavedArtSpec(
        colors: <Color>[Color(0xFF3960A2), Color(0xFF1A2744)],
        primaryIcon: Icons.music_note_rounded,
        secondaryIcon: Icons.album_rounded,
      );
    }
    if (key.contains('sleep') || key.contains('night') || key.contains('rain')) {
      return const _SavedArtSpec(
        colors: <Color>[Color(0xFF27637F), Color(0xFF102C39)],
        primaryIcon: Icons.nights_stay_rounded,
        secondaryIcon: Icons.bedtime_rounded,
      );
    }
    return const _SavedArtSpec(
      colors: <Color>[Color(0xFF28396D), Color(0xFF161F3A)],
      primaryIcon: Icons.headphones_rounded,
      secondaryIcon: Icons.audiotrack_rounded,
    );
  }

  void _playBestMatchTrack(SleepWellState state, String query) {
    final tracks = state.tracks;
    if (tracks.isEmpty) {
      return;
    }
    final queryLower = query.toLowerCase();
    SleepTrack? selected;
    for (final track in tracks) {
      final titleLower = track.title.toLowerCase();
      if (titleLower.contains(queryLower) || queryLower.contains(titleLower)) {
        selected = track;
        break;
      }
    }
    selected ??= tracks.first;
    unawaited(state.playTrack(selected));
  }
}

class _SavedArtSpec {
  const _SavedArtSpec({
    required this.colors,
    required this.primaryIcon,
    required this.secondaryIcon,
  });

  final List<Color> colors;
  final IconData primaryIcon;
  final IconData secondaryIcon;
}

class ProfilePage extends StatelessWidget {
  const ProfilePage({
    super.key,
    required this.state,
    required this.onBack,
    required this.onOpenSettings,
  });

  final SleepWellState state;
  final VoidCallback onBack;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final topPromo = state.sectionByKey('profile_top_promo');
    final header = state.sectionByKey('profile_header');
    final chronotype = state.sectionByKey('profile_chronotype');
    final accountCard = state.sectionByKey('profile_auth_card');
    final promo = state.sectionByKey('profile_promo_therapy') ?? state.sectionByKey('promo_therapy');
    final resources = state.sectionByKey('profile_resources');
    final account = state.sectionByKey('profile_account');

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1F1934), Color(0xFF0E1020), Color(0xFF090C18)],
              ),
            ),
          ),
        ),
        ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(_UiBaseline.pageHorizontal, 8, _UiBaseline.pageHorizontal, 190),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back_ios_new_rounded),
                ),
                const Spacer(),
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.03),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    onPressed: onOpenSettings,
                    icon: const Icon(Icons.settings_rounded, size: 19),
                  ),
                ),
              ],
            ),
            if (topPromo != null && topPromo.items.isNotEmpty) ...[
              const SizedBox(height: 8),
              _betterHelpPromoCard(topPromo.items.first, compact: true),
            ],
            if (header != null && header.items.isNotEmpty) ...[
              const SizedBox(height: 10),
              Center(
                child: Container(
                  width: _UiBaseline.profileAvatarSize,
                  height: _UiBaseline.profileAvatarSize,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(Icons.nights_stay_rounded, size: 46, color: Color(0xFFFFC992)),
                ),
              ),
              const SizedBox(height: 8),
              Center(
                child: Text(
                  header.items.first.title,
                  style: const TextStyle(
                    fontSize: _UiBaseline.profileNameSize,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.35,
                  ),
                ),
              ),
            ],
            if (chronotype != null && chronotype.items.isNotEmpty) ...[
              const SizedBox(height: 14),
              _profileListCard(
                children: [
                  _profileRow(
                    item: chronotype.items.first,
                    leadingIcon: Icons.auto_awesome_rounded,
                  ),
                ],
              ),
            ],
            if (accountCard != null && accountCard.items.isNotEmpty) ...[
              const SizedBox(height: 10),
              _accountPromptCard(context, accountCard.items.first),
            ],
            if (promo != null && promo.items.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text(
                promo.title ?? 'Still waking up tired?',
                style: const TextStyle(
                  fontSize: _UiBaseline.profileHeroTitleSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.45,
                ),
              ),
              const SizedBox(height: 10),
              _betterHelpPromoCard(promo.items.first),
            ],
            if (resources != null && resources.items.isNotEmpty) ...[
              if (state.adEnabled('profile', 'mid_banner'))
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: AdBannerSlot(),
                ),
              const SizedBox(height: 16),
              Text(
                resources.title ?? 'BetterSleep Resources',
                style: const TextStyle(
                  fontSize: _UiBaseline.profileTitleSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 10),
              _profileListCard(
                children: resources.items
                    .map(
                      (item) => _profileRow(
                        item: item,
                        showDivider: item != resources.items.last,
                      ),
                    )
                    .toList(),
              ),
            ],
            if (account != null && account.items.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(
                account.title ?? 'Account',
                style: const TextStyle(
                  fontSize: _UiBaseline.profileTitleSize,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
              const SizedBox(height: 10),
              _profileListCard(
                children: account.items
                    .map(
                      (item) => _profileRow(
                        item: item,
                        showDivider: item != account.items.last,
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _accountPromptCard(BuildContext context, HomeItemContent item) {
    if (state.isAuthenticated && state.currentUser != null) {
      return Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_UiBaseline.profileCardRadius),
          color: Colors.white.withValues(alpha: 0.04),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          children: [
            Text(
              'Signed in as ${state.currentUser!.name}',
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              state.currentUser!.email,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: () async {
                await state.logoutAccount();
              },
              child: const Text('Logout'),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_UiBaseline.profileCardRadius),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Text(
            item.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -0.4),
          ),
          if ((item.subtitle ?? '').isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              item.subtitle!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, height: 1.15),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: const BorderSide(color: Colors.white24),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    minimumSize: const Size(0, 52),
                  ),
                  onPressed: () => _openAuthSheet(context, isRegister: false),
                  child: const Text('Log in', style: TextStyle(fontWeight: FontWeight.w700)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    minimumSize: const Size(0, 52),
                  ),
                  onPressed: () => _openAuthSheet(context, isRegister: true),
                  child: const Text('Register', style: TextStyle(fontWeight: FontWeight.w800)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _openAuthSheet(BuildContext context, {required bool isRegister}) async {
    final emailCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    final nameCtrl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF15182A),
      builder: (context) {
        return Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, MediaQuery.of(context).viewInsets.bottom + 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(isRegister ? 'Create account' : 'Log in', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              const SizedBox(height: 12),
              if (isRegister)
                TextField(
                  controller: nameCtrl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
              if (isRegister) const SizedBox(height: 10),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () async {
                    try {
                      if (isRegister) {
                        await state.registerWithEmail(
                          name: nameCtrl.text.trim(),
                          email: emailCtrl.text.trim(),
                          password: passCtrl.text.trim(),
                        );
                      } else {
                        await state.loginWithEmail(
                          email: emailCtrl.text.trim(),
                          password: passCtrl.text.trim(),
                        );
                      }
                      if (!context.mounted) {
                        return;
                      }
                      Navigator.of(context).pop();
                    } catch (_) {
                      if (!context.mounted) {
                        return;
                      }
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(isRegister ? 'Registration failed.' : 'Login failed.')),
                      );
                    }
                  },
                  child: Text(isRegister ? 'Create account' : 'Log in'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _betterHelpPromoCard(HomeItemContent item, {bool compact = false}) {
    return Container(
      padding: EdgeInsets.all(compact ? 12 : 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_UiBaseline.profileCardRadius),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F2E52), Color(0xFF17304A), Color(0xFF24314F)],
        ),
        border: Border.all(color: Colors.cyanAccent.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('betterhelp', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text(
            item.title,
            style: TextStyle(
              fontSize: compact ? 24 : 33,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.35,
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF5BFFE8),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              item.ctaLabel ?? 'Take the assessment →',
              style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w800),
            ),
          ),
        ],
      ),
    );
  }

  Widget _profileListCard({required List<Widget> children}) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_UiBaseline.profileListRadius),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(children: children),
    );
  }

  Widget _profileRow({
    required HomeItemContent item,
    bool showDivider = false,
    IconData? leadingIcon,
  }) {
    final action = (item.meta['action']?.toString() ?? '').toLowerCase();
    final badge = item.meta['badge']?.toString() ?? item.ctaLabel ?? '';
    final value = item.meta['value']?.toString() ?? item.tag ?? '';
    final showsArrow = action.contains('arrow');
    final showsBadge = action == 'pill' || action == 'badge';

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 15),
          child: Row(
            children: [
              if (leadingIcon != null) ...[
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  alignment: Alignment.center,
                  child: Icon(leadingIcon, size: 20),
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.title,
                      style: const TextStyle(
                        fontSize: _UiBaseline.profileRowTitleSize,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if ((item.subtitle ?? '').isNotEmpty)
                      Text(item.subtitle!, style: const TextStyle(color: Colors.white70)),
                  ],
                ),
              ),
              if (value.isNotEmpty) ...[
                Text(value, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
              ],
              if (showsBadge && badge.isNotEmpty)
                Container(
                  constraints: const BoxConstraints(minHeight: _UiBaseline.profileActionPillHeight),
                  padding: const EdgeInsets.symmetric(horizontal: _UiBaseline.profileActionPillHorizontal, vertical: 7),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.white.withValues(alpha: 0.08),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(badge, style: const TextStyle(fontWeight: FontWeight.w700)),
                ),
              if (showsArrow) const Icon(Icons.chevron_right_rounded, color: Colors.white70),
            ],
          ),
        ),
        if (showDivider) const Divider(height: 1, color: Colors.white10),
      ],
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    required this.state,
    required this.onBack,
  });

  final SleepWellState state;
  final VoidCallback onBack;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final Map<String, bool> _toggles = <String, bool>{};

  @override
  Widget build(BuildContext context) {
    final main = widget.state.sectionByKey('profile_settings_main');
    final more = widget.state.sectionByKey('profile_settings_more');

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF1F1934), Color(0xFF0E1020), Color(0xFF090C18)],
              ),
            ),
          ),
        ),
        ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(_UiBaseline.pageHorizontal, 8, _UiBaseline.pageHorizontal, 190),
          children: [
            IconButton(
              onPressed: widget.onBack,
              alignment: Alignment.centerLeft,
              padding: EdgeInsets.zero,
              icon: const Icon(Icons.arrow_back_ios_new_rounded),
            ),
            _settingsSectionHeader('Settings', withLine: true),
            const SizedBox(height: 8),
            if (main != null && main.items.isNotEmpty) _settingsListCard(main.items),
            if (widget.state.adEnabled('settings', 'list_banner'))
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: AdBannerSlot(),
              ),
            const SizedBox(height: 14),
            _settingsSectionHeader(more?.title ?? 'More'),
            const SizedBox(height: 8),
            if (more != null && more.items.isNotEmpty) _settingsListCard(more.items),
          ],
        ),
      ],
    );
  }

  Widget _settingsListCard(List<HomeItemContent> items) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(_UiBaseline.settingsCardRadius),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          for (var i = 0; i < items.length; i++) ...[
            _settingsRow(items[i]),
            if (i != items.length - 1) const Divider(height: 1, color: Colors.white10),
          ],
        ],
      ),
    );
  }

  Widget _settingsRow(HomeItemContent item) {
    final action = (item.meta['action']?.toString() ?? '').toLowerCase();
    final isToggle = action == 'toggle';
    final current = _toggles[item.title] ?? (item.meta['enabled'] == true);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: _UiBaseline.settingsRowVertical),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    fontSize: _UiBaseline.profileRowTitleSize,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                if ((item.subtitle ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    item.subtitle!,
                    style: const TextStyle(color: Colors.white70, height: 1.15),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (isToggle)
            Transform.scale(
              scale: _UiBaseline.settingsToggleScale,
              child: Switch(
                value: current,
                onChanged: (value) => setState(() => _toggles[item.title] = value),
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white24,
                activeColor: Colors.black,
                inactiveThumbColor: Colors.white,
              ),
            )
          else
            const Icon(Icons.chevron_right_rounded, color: Colors.white70),
        ],
      ),
    );
  }

  Widget _settingsSectionHeader(String text, {bool withLine = false}) {
    return Row(
      children: [
        Text(
          text,
          style: const TextStyle(
            fontSize: _UiBaseline.settingsTitleSize,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.4,
          ),
        ),
        if (withLine) ...[
          const SizedBox(width: 10),
          Expanded(
            child: Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.08),
            ),
          ),
        ],
      ],
    );
  }
}

class RoutinePage extends StatefulWidget {
  const RoutinePage({super.key, required this.state});
  final SleepWellState state;

  @override
  State<RoutinePage> createState() => _RoutinePageState();
}

class _RoutinePageState extends State<RoutinePage> {
  bool _trackSleepEnabled = false;

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final habits = state.sectionByKey('routine_habits');
    final windDown = state.sectionByKey('routine_wind_down');
    final sleep = state.sectionByKey('routine_sleep');
    final recommendation = state.sectionByKey('routine_recommendation');

    return Stack(
      children: [
        Positioned.fill(
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Color(0xFF2D2DB2), Color(0xFF111536), Color(0xFF171A3F)],
              ),
            ),
          ),
        ),
        ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 180),
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    state.setBedtimeRoutineEnabled(!state.bedtimeRoutineEnabled);
                    _showRoutineSnack(
                      state.bedtimeRoutineEnabled
                          ? 'Bedtime routine enabled.'
                          : 'Bedtime routine disabled.',
                    );
                  },
                  icon: const Icon(Icons.close),
                ),
                const Spacer(),
                const Text('Routine Mar 28', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                const Spacer(),
                TextButton(
                  onPressed: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: state.bedtimeTime,
                    );
                    if (picked != null) {
                      state.setBedtimeTime(picked);
                      state.setBedtimeRoutineEnabled(true);
                    }
                  },
                  child: const Text('Edit'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: _alarmTile(
                    label: 'Bedtime Reminder',
                    time: _formatTimeOfDay(state.bedtimeTime),
                    enabled: state.bedtimeRoutineEnabled,
                    onTap: () async {
                      final picked = await showTimePicker(context: context, initialTime: state.bedtimeTime);
                      if (picked != null) {
                        state.setBedtimeTime(picked);
                        state.setBedtimeRoutineEnabled(true);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 6),
                Container(width: 1, height: 56, color: Colors.white24),
                const SizedBox(width: 6),
                Expanded(
                  child: _alarmTile(
                    label: 'Wake Up Alarm',
                    time: '08:00',
                    enabled: false,
                    onTap: () => _showRoutineSnack('Wake up alarm UI is coming in next pass.'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 44,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 6,
                separatorBuilder: (_, __) => const SizedBox(width: 14),
                itemBuilder: (_, idx) {
                  final day = 22 + idx;
                  final selected = day == 28;
                  return Container(
                    width: 42,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: selected ? Border.all(color: Colors.white, width: 3) : null,
                      color: selected ? Colors.transparent : Colors.white.withValues(alpha: 0.06),
                    ),
                    alignment: Alignment.center,
                    child: Text('$day', style: const TextStyle(fontWeight: FontWeight.w700)),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            _routineSection(
              title: habits?.title ?? 'HABITS',
              child: _noticeCard(habits?.items.first.title ?? "You don't have any habits. Tap the plus to add one."),
            ),
            const SizedBox(height: 8),
            _routineSectionWithTimeline(
              title: windDown?.title ?? 'WIND DOWN',
              timelineHeight: 116,
              child: Column(
                children: [
                  _trackCard(
                    title: windDown?.items.first.title ?? 'Dropping into the Present Moment',
                    subtitle: windDown?.items.first.subtitle ?? 'Meditation • 14 min',
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            _routineSectionWithTimeline(
              title: sleep?.title ?? 'SLEEP',
              timelineHeight: 170,
              child: Column(
                children: [
                  _trackSleepCard(
                    title: sleep?.items.first.title ?? 'Track your sleep',
                    subtitle: sleep?.items.first.subtitle ?? 'Tap to learn more info.',
                    enabled: _trackSleepEnabled,
                    onChanged: (v) => setState(() => _trackSleepEnabled = v),
                  ),
                  const SizedBox(height: 10),
                  _trackCard(
                    title: sleep != null && sleep.items.length > 1 ? sleep.items[1].title : 'Night Wind',
                    subtitle: sleep != null && sleep.items.length > 1 ? sleep.items[1].subtitle ?? '' : 'Mix • 1 h 0 min',
                  ),
                ],
              ),
            ),
            if (recommendation != null && recommendation.items.isNotEmpty) ...[
              const SizedBox(height: 14),
              const Divider(color: Colors.white24, indent: 48, endIndent: 48, height: 24),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(18),
                  gradient: const LinearGradient(colors: [Color(0xFF21367A), Color(0xFF2C2E65)]),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      recommendation.items.first.title,
                      style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 6),
                    Text(recommendation.items.first.subtitle ?? '', style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 12),
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.15),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: () => _showRoutineSnack('Explore more routines from Sounds tab.'),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(recommendation.items.first.ctaLabel ?? 'Explore more'),
                          const SizedBox(width: 6),
                          const Icon(Icons.chevron_right_rounded),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            FilledButton(
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(double.infinity, 58),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              onPressed: () async {
                await state.startSleepNow();
              },
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Start Routine', style: TextStyle(fontWeight: FontWeight.w800)),
                  SizedBox(width: 8),
                  Icon(Icons.play_arrow_rounded),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _alarmTile({
    required String label,
    required String time,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.edit, size: 12, color: Colors.white70),
              const SizedBox(width: 4),
              Text(time, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            ],
          ),
          Text(enabled ? 'Enabled' : 'Tap to enable', style: const TextStyle(color: Colors.white60)),
        ],
      ),
    );
  }

  void _showRoutineSnack(String text) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Widget _routineSection({required String title, required Widget child}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _routineHeader(title),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _routineSectionWithTimeline({
    required String title,
    required Widget child,
    required double timelineHeight,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _routineHeader(title),
        const SizedBox(height: 8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 16,
              child: Column(
                children: [
                  _dashedSegment(10),
                  const SizedBox(height: 4),
                  _timelineDot(filled: true),
                  const SizedBox(height: 4),
                  _dashedSegment(timelineHeight * 0.42),
                  const SizedBox(height: 4),
                  _timelineDot(filled: false),
                  const SizedBox(height: 4),
                  _dashedSegment(timelineHeight * 0.46),
                ],
              ),
            ),
            const SizedBox(width: 6),
            Expanded(child: child),
          ],
        ),
      ],
    );
  }

  Widget _routineHeader(String title) {
    return Row(
      children: [
        Text('• $title', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
        const Spacer(),
        CircleAvatar(
          radius: 15,
          backgroundColor: Colors.white.withValues(alpha: 0.1),
          child: const Icon(Icons.add, size: 16),
        ),
      ],
    );
  }

  Widget _timelineDot({required bool filled}) {
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: filled ? Colors.white70 : Colors.transparent,
        border: Border.all(color: Colors.white54, width: 1),
      ),
    );
  }

  Widget _dashedSegment(double height) {
    final bars = max(1, (height / 7).floor());
    return SizedBox(
      height: height,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: List.generate(
          bars,
          (_) => Container(width: 2, height: 3, color: Colors.white24),
        ),
      ),
    );
  }

  Widget _noticeCard(String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.07),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.white.withValues(alpha: 0.12),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.spa_rounded),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _trackCard({required String title, required String subtitle}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.black.withValues(alpha: 0.23),
      ),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.blueGrey.withValues(alpha: 0.35),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                Text(subtitle, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          const Icon(Icons.more_horiz_rounded, size: 30),
        ],
      ),
    );
  }

  Widget _trackSleepCard({
    required String title,
    required String subtitle,
    required bool enabled,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: Colors.white.withValues(alpha: 0.08),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFA071FF),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                    const SizedBox(width: 6),
                    const CircleAvatar(radius: 8, child: Icon(Icons.info_outline, size: 12)),
                  ],
                ),
                Text(subtitle, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          Switch(value: enabled, onChanged: onChanged),
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
            SwitchListTile(
              title: const Text('Bedtime routine'),
              subtitle: Text(
                'Auto-start Sleep Now at ${_formatTimeOfDay(state.bedtimeTime)}',
              ),
              value: state.bedtimeRoutineEnabled,
              onChanged: (value) {
                state.setBedtimeRoutineEnabled(value);
              },
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: state.bedtimeTime,
                  );
                  if (picked != null) {
                    state.setBedtimeTime(picked);
                  }
                },
                icon: const Icon(Icons.schedule),
                label: const Text('Set Bedtime Time'),
              ),
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

class PlayerPage extends StatefulWidget {
  const PlayerPage({super.key, required this.state});
  final SleepWellState state;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends State<PlayerPage> {
  int _tabIndex = 0;
  int _chipIndex = 0;
  int _promotedIndex = 0;
  final List<String> _tabs = const <String>['Sounds', 'Music', 'Mixes', 'Meditations', 'SleepTales'];

  static const Map<String, List<String>> _filters = <String, List<String>>{
    'Sounds': <String>['My ❤️', 'Popular', 'New', 'Colored Noise', 'Nature', 'ASMR'],
    'Music': <String>['All', 'Deeper Sleep', 'Relaxation', 'Focus'],
    'Mixes': <String>['All', 'Easy', 'With Sound', 'New'],
    'Meditations': <String>['All', 'Hypnosis', 'With Sound', 'Emotions'],
    'SleepTales': <String>['All', 'Fantasy', 'Sci-fi', 'Non-Fiction', 'Kids'],
  };

  @override
  Widget build(BuildContext context) {
    final tab = _tabs[_tabIndex];
    final chips = _filters[tab] ?? const <String>[];
    final promoted = _sectionForTabPromoted(tab);
    final sections = _sectionsForTab(tab);
    return ListView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(
        _UiBaseline.pageHorizontal,
        _UiBaseline.pageTop,
        _UiBaseline.pageHorizontal,
        _UiBaseline.pageBottomInset,
      ),
      children: [
        SizedBox(
          height: 50,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemBuilder: (_, i) {
              final selected = _tabIndex == i;
              return InkWell(
                onTap: () => setState(() {
                  _tabIndex = i;
                  _chipIndex = 0;
                }),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Column(
                    children: [
                      Text(
                        _tabs[i],
                        style: TextStyle(
                          fontSize: _UiBaseline.tabSize,
                          color: selected ? Colors.white : Colors.white38,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.1,
                        ),
                      ),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        margin: const EdgeInsets.only(top: 4),
                        height: 2.6,
                        width: selected ? 42 : 0,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
            separatorBuilder: (_, __) => const SizedBox(width: 14),
            itemCount: _tabs.length,
          ),
        ),
        const SizedBox(height: 14),
        if (chips.isNotEmpty)
          SizedBox(
            height: _UiBaseline.chipHeight,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemBuilder: (_, i) {
                final selected = _chipIndex == i;
                return InkWell(
                  borderRadius: BorderRadius.circular(999),
                  onTap: () => setState(() => _chipIndex = i),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 15),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: selected ? Colors.white38 : Colors.white24),
                      color: Colors.white.withValues(alpha: selected ? 0.11 : 0.02),
                    ),
                    alignment: Alignment.center,
                    child: Text(
                      chips[i],
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: selected ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                );
              },
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemCount: chips.length,
            ),
          ),
        if (promoted != null && promoted.items.isNotEmpty) ...[
          const SizedBox(height: _UiBaseline.sectionGap),
          Text(
            promoted.title ?? 'Promoted content',
            style: const TextStyle(fontSize: _UiBaseline.titleSize, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: _UiBaseline.promotedHeight,
            child: PageView.builder(
              onPageChanged: (value) => setState(() => _promotedIndex = value),
              itemCount: promoted.items.length,
              itemBuilder: (_, i) => Padding(
                padding: const EdgeInsets.only(right: 10),
                child: _promotedCard(promoted.items[i]),
              ),
            ),
          ),
          if (promoted.items.length > 1) ...[
            const SizedBox(height: 8),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(promoted.items.length, (i) {
                  final active = i == _promotedIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    width: active ? 18 : 6,
                    height: 6,
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    decoration: BoxDecoration(
                      color: active ? Colors.white : Colors.white30,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  );
                }),
              ),
            ),
          ],
          if (tab == 'Meditations' || tab == 'SleepTales') ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 38,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: 8,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, idx) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(color: Colors.white24),
                    color: Colors.black.withValues(alpha: 0.18),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: Colors.white.withValues(alpha: 0.2),
                        child: Text(
                          String.fromCharCode(65 + idx),
                          style: const TextStyle(fontSize: 10, color: Colors.white),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        tab == 'Meditations'
                            ? ['Nicky', 'Dr. Ryan', 'Dr. Liz', 'Michelle', 'Lauren', 'Andrew', 'Aster', 'Dave'][idx]
                            : ['Christine', 'Drew', 'Aster', 'Dave', 'Lisa', 'Victoria', 'Shogo', 'Mia'][idx],
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
        const SizedBox(height: _UiBaseline.sectionGap),
        ...sections.map((section) => _sectionBlock(section)),
      ],
    );
  }

  HomeSectionContent? _sectionForTabPromoted(String tab) {
    final state = widget.state;
    switch (tab) {
      case 'Sounds':
        return state.sectionByKey('sounds_featured');
      case 'Music':
        return state.sectionByKey('music_hero');
      case 'Mixes':
        return state.sectionByKey('mixes_featured');
      case 'Meditations':
        return state.sectionByKey('meditation_promoted');
      case 'SleepTales':
        return state.sectionByKey('sleeptales_promoted');
      default:
        return null;
    }
  }

  List<HomeSectionContent> _sectionsForTab(String tab) {
    final state = widget.state;
    switch (tab) {
      case 'Sounds':
        return <HomeSectionContent>[
          if (state.sectionByKey('sounds_my_sounds') != null) state.sectionByKey('sounds_my_sounds')!,
          if (state.sectionByKey('sounds_popular') != null) state.sectionByKey('sounds_popular')!,
        ];
      case 'Music':
        return <HomeSectionContent>[
          if (state.sectionByKey('music_top10') != null) state.sectionByKey('music_top10')!,
          if (state.sectionByKey('music_layers') != null) state.sectionByKey('music_layers')!,
        ];
      case 'Mixes':
        return <HomeSectionContent>[
          if (state.sectionByKey('mixes_favorites') != null) state.sectionByKey('mixes_favorites')!,
          if (state.sectionByKey('mixes_sound_escapes') != null) state.sectionByKey('mixes_sound_escapes')!,
        ];
      case 'Meditations':
        return <HomeSectionContent>[
          if (state.sectionByKey('meditation_bedtime') != null) state.sectionByKey('meditation_bedtime')!,
          if (state.sectionByKey('meditation_new') != null) state.sectionByKey('meditation_new')!,
        ];
      case 'SleepTales':
        return <HomeSectionContent>[
          if (state.sectionByKey('sleeptales_popular') != null) state.sectionByKey('sleeptales_popular')!,
          if (state.sectionByKey('sleeptales_cozy') != null) state.sectionByKey('sleeptales_cozy')!,
        ];
      default:
        return const <HomeSectionContent>[];
    }
  }

  Widget _promotedCard(HomeItemContent item) {
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => _openTrack(item.title),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_UiBaseline.radiusLg),
          gradient: const LinearGradient(
            colors: [Color(0xFF434D8F), Color(0xFF2C345C)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Row(
                    children: [
                      Icon(Icons.videocam_outlined, size: 16),
                      SizedBox(width: 6),
                      Text('Video'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(item.title, maxLines: 4, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 12,
                        backgroundColor: Colors.white.withValues(alpha: 0.3),
                        child: const Icon(Icons.person, size: 14),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          item.subtitle ?? 'by SleepWell',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Container(
              width: 110,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(_UiBaseline.radiusMd),
                color: Colors.white.withValues(alpha: 0.1),
              ),
              child: Center(
                child: CircleAvatar(
                  radius: 22,
                  backgroundColor: Colors.white,
                  child: const Icon(Icons.play_arrow, color: Colors.black),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionBlock(HomeSectionContent section) {
    final items = section.items;
    final isGrid = section.sectionType == 'grid';
    final isChips = section.sectionType == 'chips';
    final tab = _tabs[_tabIndex];
    final isSoundsGrid = tab == 'Sounds' && isGrid;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((section.title ?? '').isNotEmpty)
            Text(section.title!, style: const TextStyle(fontSize: _UiBaseline.titleSize, fontWeight: FontWeight.w700)),
          if ((section.subtitle ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 10),
              child: Text(section.subtitle!, style: const TextStyle(color: Colors.white70)),
            ),
          if (isGrid)
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: isSoundsGrid ? 4 : 3,
                crossAxisSpacing: 10,
                mainAxisSpacing: 12,
                childAspectRatio: isSoundsGrid ? 0.72 : 0.78,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _openTrack(item.title),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Container(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(_UiBaseline.radiusMd),
                            gradient: LinearGradient(
                              colors: isSoundsGrid
                                  ? const [Color(0xFFE4BF86), Color(0xFFD2A763)]
                                  : const [Color(0xFFDFB877), Color(0xFFCCA86C)],
                            ),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(Icons.graphic_eq_rounded, color: Color(0xFF3B2A19)),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    ],
                  ),
                );
              },
            )
          else if (isChips)
            Wrap(
              spacing: 12,
              runSpacing: 10,
              children: items
                  .map(
                    (item) => InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _openTrack(item.title),
                      child: SizedBox(
                        width: 160,
                        child: Row(
                          children: [
                            Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(_UiBaseline.radiusSm),
                              ),
                              child: const Icon(Icons.graphic_eq_rounded, size: 20),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                                  Text(item.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(),
            )
          else
            SizedBox(
              height: _UiBaseline.cardRailHeight,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                physics: const BouncingScrollPhysics(),
                itemBuilder: (_, i) {
                  final item = items[i];
                  return InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _openTrack(item.title),
                    child: SizedBox(
                      width: _UiBaseline.cardRailWidth,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(_UiBaseline.radiusMd),
                              child: Container(
                                color: Colors.white.withValues(alpha: 0.08),
                                child: item.imageUrl == null
                                    ? const Center(child: Icon(Icons.nights_stay_rounded, size: 42))
                                    : Image.network(
                                        item.imageUrl!,
                                        fit: BoxFit.cover,
                                        width: double.infinity,
                                        errorBuilder: (_, __, ___) => const Center(child: Icon(Icons.broken_image)),
                                      ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                          Text(item.subtitle ?? '', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                    ),
                  );
                },
                separatorBuilder: (_, __) => const SizedBox(width: 12),
                itemCount: items.length,
              ),
            ),
        ],
      ),
    );
  }

  void _openTrack(String queryTitle) {
    SleepTrack? selected;
    final query = queryTitle.toLowerCase();
    for (final track in widget.state.tracks) {
      final title = track.title.toLowerCase();
      if (title.contains(query) || query.contains(title)) {
        selected = track;
        break;
      }
    }
    selected ??= widget.state.tracks.isNotEmpty ? widget.state.tracks.first : null;
    if (selected == null) {
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => TrackDetailPage(state: widget.state, track: selected!),
      ),
    );
  }
}

class TrackDetailPage extends StatefulWidget {
  const TrackDetailPage({super.key, required this.state, required this.track});
  final SleepWellState state;
  final SleepTrack track;

  @override
  State<TrackDetailPage> createState() => _TrackDetailPageState();
}

class _TrackDetailPageState extends State<TrackDetailPage> {
  bool repeat = false;
  bool closeAfter = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF16475B), Color(0xFF0B0F1B)],
                ),
              ),
            ),
          ),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(
                _UiBaseline.pageHorizontal + 2,
                10,
                _UiBaseline.pageHorizontal + 2,
                24,
              ),
              children: [
                Row(
                  children: [
                    IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.close)),
                    const Spacer(),
                    const Icon(Icons.cloud_download_outlined),
                    const SizedBox(width: 18),
                    const Icon(Icons.favorite_border_rounded),
                    const SizedBox(width: 18),
                    const Icon(Icons.add),
                  ],
                ),
                const SizedBox(height: 6),
                Container(
                  height: 250,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_UiBaseline.radiusLg),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF21A9A7), Color(0xFF0F2C42)],
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Spacer(),
                        Text(
                          widget.track.title,
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 14),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black),
                            onPressed: () async {
                              await widget.state.playTrack(widget.track);
                              if (!context.mounted) {
                                return;
                              }
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => NowPlayingPage(state: widget.state, track: widget.track),
                                ),
                              );
                            },
                            child: const Text('Play', style: TextStyle(fontWeight: FontWeight.w700)),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: Text(
                    widget.track.title,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 16),
                const ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(radius: 22),
                  title: Text('Aster J. Haile'),
                  subtitle: Text('Meditation Teacher • North American Accent'),
                  trailing: Icon(Icons.chevron_right_rounded),
                ),
                const SizedBox(height: 4),
                const Text('Single Session • 30 min', style: TextStyle(color: Colors.white70)),
                const SizedBox(height: 10),
                const Text(
                  'Try this potent hypnosis accompanied by the sound of green noise, to smooth all thoughts and drift into the deepest sleep.',
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: const ['Deep Sleep', 'With Sound', 'Bored', 'Bedtime', 'Fall Asleep', 'Hypnosis', 'Sleep']
                      .map((label) => Chip(label: Text(label, style: TextStyle(fontWeight: FontWeight.w600))))
                      .toList(),
                ),
                const SizedBox(height: 14),
                _settingRow(icon: Icons.music_note, title: 'Mixes', value: 'None'),
                _settingRow(icon: Icons.alarm, title: 'Keep music playing', value: 'Until meditation ends'),
                _toggleRow(icon: Icons.repeat, title: 'Repeat meditation', value: repeat, onChanged: (v) => setState(() => repeat = v)),
                _toggleRow(
                  icon: Icons.exit_to_app_outlined,
                  title: 'Close app after ending',
                  value: closeAfter,
                  onChanged: (v) => setState(() => closeAfter = v),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _settingRow({required IconData icon, required String title, required String value}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Text(value, style: const TextStyle(color: Colors.white70)),
          const SizedBox(width: 6),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }

  Widget _toggleRow({
    required IconData icon,
    required String title,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white12)),
      ),
      child: Row(
        children: [
          Icon(icon),
          const SizedBox(width: 10),
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
          const Spacer(),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

class NowPlayingPage extends StatelessWidget {
  const NowPlayingPage({super.key, required this.state, required this.track});
  final SleepWellState state;
  final SleepTrack track;

  @override
  Widget build(BuildContext context) {
    final duration = state.currentDuration.inMilliseconds <= 0
        ? Duration(seconds: max(track.durationSeconds, 1))
        : state.currentDuration;
    final positionMs = min(state.currentPosition.inMilliseconds, duration.inMilliseconds).toDouble();
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF17495D), Color(0xFF11162A), Color(0xFF171E37)],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      IconButton(onPressed: () => Navigator.pop(context), icon: const Icon(Icons.keyboard_arrow_down)),
                      const Spacer(),
                      FilledButton.tonal(
                        style: FilledButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.14),
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        ),
                        onPressed: () async {
                          await state.stopPlayback();
                          if (context.mounted) {
                            Navigator.pop(context);
                          }
                        },
                        child: const Text('End Session'),
                      ),
                    ],
                  ),
                ),
                Container(
                  height: 200,
                  margin: const EdgeInsets.symmetric(horizontal: _UiBaseline.pageHorizontal),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(_UiBaseline.radiusLg),
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF2BBAB6), Color(0xFF142E45)],
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                      const SizedBox(height: 4),
                      const Text('Narrated by Aster J. Haile', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 5.5,
                          activeTrackColor: const Color(0xFFB9A7FF),
                          inactiveTrackColor: Colors.white24,
                          thumbColor: Colors.white,
                          overlayColor: Colors.white24,
                          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                        ),
                        child: Slider(
                          value: positionMs,
                          min: 0,
                          max: duration.inMilliseconds.toDouble(),
                          onChanged: (value) async {
                            final target = Duration(milliseconds: value.round());
                            await state.seekTo(target);
                          },
                        ),
                      ),
                      Row(
                        children: [
                          Text(_formatDuration(state.currentPosition), style: const TextStyle(color: Colors.white70)),
                          const Spacer(),
                          Text(_formatDuration(duration), style: const TextStyle(color: Colors.white70)),
                        ],
                      ),
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          const Icon(Icons.more_horiz, size: 30),
                          const Icon(Icons.skip_previous_rounded, color: Colors.white38, size: 34),
                          IconButton(
                            iconSize: _UiBaseline.nowPlayingMainButton,
                            icon: CircleAvatar(
                              radius: _UiBaseline.nowPlayingMainButton / 2,
                              backgroundColor: Colors.white,
                              child: Icon(
                                state.isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.black,
                                size: _UiBaseline.nowPlayingMainIcon,
                              ),
                            ),
                            onPressed: () async => state.togglePlayPause(),
                          ),
                          const Icon(Icons.skip_next_rounded, size: 34),
                          IconButton(
                            icon: const Icon(Icons.favorite_border_rounded, size: 30),
                            onPressed: () async {
                              await state.upsertSavedItem(
                                itemType: 'favorites',
                                itemRef: '${track.id ?? track.title}',
                                title: track.title,
                                subtitle: '${track.category} • ${track.talking ? 'Talking' : 'No talking'}',
                              );
                              if (!context.mounted) {
                                return;
                              }
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Added to favorites')),
                              );
                            },
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Center(
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white,
                            foregroundColor: Colors.black,
                            minimumSize: const Size(220, 50),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
                          ),
                          onPressed: () async {
                            await state.startSleepNow(entryPoint: 'track_detail_track_sleep');
                            if (!context.mounted) {
                              return;
                            }
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Sleep tracking started')),
                            );
                          },
                          child: const Text('Track My Sleep'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: const BoxDecoration(
                    color: Color(0xFF1B2442),
                    borderRadius: BorderRadius.vertical(top: Radius.circular(_UiBaseline.radiusXl)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Center(child: Text('Adjust Sounds', style: TextStyle(fontWeight: FontWeight.w700))),
                      const SizedBox(height: 10),
                      const Text('Meditation', style: TextStyle(fontWeight: FontWeight.w700)),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const CircleAvatar(child: Icon(Icons.volume_up_rounded)),
                        title: Text(track.title),
                        subtitle: Slider(
                          value: state.mainPlayerVolume,
                          onChanged: (v) async => state.setMainPlayerVolume(v),
                        ),
                      ),
                      const Divider(color: Colors.white12),
                      _adjustRow(
                        title: 'Sounds',
                        subtitle: 'Include relaxing sounds.',
                        button: 'Add Sounds',
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Open Sounds tab to add layers.')),
                        ),
                      ),
                      const Divider(color: Colors.white12),
                      _adjustRow(
                        title: 'Music',
                        subtitle: 'Enhance your mix with music.',
                        button: 'Add Music',
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Open Music tab to add tracks.')),
                        ),
                      ),
                      const Divider(color: Colors.white12),
                      _adjustRow(
                        title: 'Brainwaves',
                        subtitle: 'Elevate your mix.',
                        button: 'Add Brainwave',
                        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Open Mixer to add brainwaves.')),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _adjustRow({
    required String title,
    required String subtitle,
    required String button,
    required VoidCallback onPressed,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(subtitle, style: const TextStyle(color: Colors.white70)),
              ],
            ),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              foregroundColor: Colors.white,
            ),
            onPressed: onPressed,
            child: Text(button),
          ),
        ],
      ),
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
    final quality = state.sectionByKey('insight_sleep_quality');
    final snore = state.sectionByKey('insight_snore');
    final phases = state.sectionByKey('insight_phases');
    final qualityItem = quality?.items.isNotEmpty == true ? quality!.items.first : null;
    final snoreItem = snore?.items.isNotEmpty == true ? snore!.items.first : null;
    final phasesItem = phases?.items.isNotEmpty == true ? phases!.items.first : null;
    final qualityScore = qualityItem == null ? 0 : _toInt(qualityItem.meta['score']);

    return ListView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 180),
      children: [
        const Text('Friday Jul 10', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: 7,
            separatorBuilder: (_, __) => const SizedBox(width: 8),
            itemBuilder: (_, idx) {
              final day = 5 + idx;
              final selected = day == 10;
              return Container(
                width: 42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: selected ? Border.all(color: Colors.white, width: 3.2) : null,
                  color: selected ? Colors.transparent : Colors.white.withValues(alpha: 0.04),
                ),
                alignment: Alignment.center,
                child: Text(
                  '$day',
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white38,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 10),
        _insightCard(
          minHeight: 300,
          child: Column(
            children: [
              SizedBox(
                height: 92,
                child: CustomPaint(
                  painter: _InsightsGaugePainter(),
                  child: const SizedBox.expand(),
                ),
              ),
              Text('$qualityScore', style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800)),
              const Text('Sleep quality', style: TextStyle(color: Colors.white60)),
              const SizedBox(height: 8),
              Text(
                qualityItem?.title ?? 'No Sleep Quality Yet',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 4),
              Text(
                qualityItem?.subtitle ?? 'Track your sleep tonight and wake up to detailed insights here.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _insightCard(
          minHeight: 188,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(snoreItem?.title ?? 'Do you snore?', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(
                      snoreItem?.subtitle ?? "Record your sleep sounds to uncover what's disturbing your rest.",
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        minimumSize: const Size(140, 44),
                      ),
                      onPressed: () async {
                        await state.startSleepNow(entryPoint: 'insight_snore_track_sleep');
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Sleep tracking started.')),
                        );
                      },
                      child: Text(snoreItem?.ctaLabel ?? 'Track my sleep'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 142,
                height: 124,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  color: Colors.white.withValues(alpha: 0.09),
                ),
                alignment: Alignment.center,
                child: const Text('😴', style: TextStyle(fontSize: 64)),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _insightCard(
          minHeight: 188,
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(phasesItem?.title ?? 'Your Sleep Phases', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
                    const SizedBox(height: 6),
                    Text(
                      phasesItem?.subtitle ?? 'Learn more about your sleeping patterns and how to improve them.',
                      style: const TextStyle(color: Colors.white70),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                        minimumSize: const Size(140, 44),
                      ),
                      onPressed: () async {
                        await state.refreshInsights();
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Insights refreshed from latest sessions.')),
                        );
                      },
                      child: Text(phasesItem?.ctaLabel ?? 'Learn more'),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Container(
                width: 142,
                height: 124,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  gradient: const LinearGradient(colors: [Color(0xFF2E376F), Color(0xFF2D2E58)]),
                ),
                alignment: Alignment.center,
                child: const Icon(Icons.multiline_chart_rounded, size: 62, color: Color(0xFFAD7DFF)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _insightCard({required Widget child, double? minHeight}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.06),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight ?? 0),
        child: child,
      ),
    );
  }
}

class _InsightsGaugePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..strokeWidth = 8
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final rect = Rect.fromLTWH(0, 0, size.width, size.height * 2);
    canvas.drawArc(rect, pi, pi, false, stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    this.updatedAt,
  });

  final int id;
  final String name;
  final Map<String, double> channels;
  final DateTime? updatedAt;

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
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }
}

class AppUserProfile {
  const AppUserProfile({
    required this.id,
    required this.name,
    required this.email,
  });

  final int id;
  final String name;
  final String email;

  factory AppUserProfile.fromJson(Map<String, dynamic> json) {
    return AppUserProfile(
      id: _toInt(json['id']),
      name: '${json['name'] ?? ''}',
      email: '${json['email'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'email': email,
    };
  }
}

class AuthResult {
  const AuthResult({
    required this.token,
    required this.user,
  });

  final String token;
  final AppUserProfile user;
}

class SavedContentItem {
  const SavedContentItem({
    required this.id,
    required this.itemType,
    required this.itemRef,
    required this.title,
    this.subtitle,
    this.meta = const <String, dynamic>{},
    this.updatedAt,
  });

  final int id;
  final String itemType;
  final String itemRef;
  final String title;
  final String? subtitle;
  final Map<String, dynamic> meta;
  final DateTime? updatedAt;

  factory SavedContentItem.fromJson(Map<String, dynamic> json) {
    final meta = json['meta'] is Map<String, dynamic>
        ? json['meta'] as Map<String, dynamic>
        : <String, dynamic>{};
    return SavedContentItem(
      id: _toInt(json['id']),
      itemType: '${json['item_type'] ?? 'track'}',
      itemRef: '${json['item_ref'] ?? ''}',
      title: '${json['title'] ?? ''}',
      subtitle: json['subtitle']?.toString(),
      meta: meta,
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }
}

class AdPlacementConfig {
  const AdPlacementConfig({
    required this.screen,
    required this.slotKey,
    required this.enabled,
  });

  final String screen;
  final String slotKey;
  final bool enabled;

  factory AdPlacementConfig.fromJson(Map<String, dynamic> json) {
    return AdPlacementConfig(
      screen: '${json['screen'] ?? ''}',
      slotKey: '${json['slot_key'] ?? ''}',
      enabled: json['enabled'] == true || json['enabled'] == 1,
    );
  }
}

class HomeSectionContent {
  const HomeSectionContent({
    required this.sectionKey,
    required this.title,
    required this.subtitle,
    required this.sectionType,
    required this.items,
  });

  final String sectionKey;
  final String? title;
  final String? subtitle;
  final String sectionType;
  final List<HomeItemContent> items;

  factory HomeSectionContent.fromJson(
    Map<String, dynamic> json, {
    required String apiBaseUrl,
  }) {
    final rawItems = (json['items'] as List<dynamic>? ?? <dynamic>[]);
    return HomeSectionContent(
      sectionKey: '${json['section_key'] ?? ''}',
      title: json['title']?.toString(),
      subtitle: json['subtitle']?.toString(),
      sectionType: '${json['section_type'] ?? 'horizontal'}',
      items: rawItems
          .whereType<Map<String, dynamic>>()
          .map((item) => HomeItemContent.fromJson(item, apiBaseUrl: apiBaseUrl))
          .toList(),
    );
  }
}

class HomeItemContent {
  const HomeItemContent({
    required this.title,
    this.subtitle,
    this.tag,
    this.imageUrl,
    this.iconUrl,
    this.ctaLabel,
    this.meta = const <String, dynamic>{},
  });

  final String title;
  final String? subtitle;
  final String? tag;
  final String? imageUrl;
  final String? iconUrl;
  final String? ctaLabel;
  final Map<String, dynamic> meta;

  int get rank => _toInt(meta['rank']);
  String? get emoji => meta['emoji']?.toString();

  factory HomeItemContent.fromJson(
    Map<String, dynamic> json, {
    required String apiBaseUrl,
  }) {
    final rawMeta = (json['meta'] is Map<String, dynamic>)
        ? json['meta'] as Map<String, dynamic>
        : <String, dynamic>{};

    final imageRaw = json['image_url']?.toString();
    final iconRaw = json['icon_url']?.toString();

    return HomeItemContent(
      title: '${json['title'] ?? ''}',
      subtitle: json['subtitle']?.toString(),
      tag: json['tag']?.toString(),
      imageUrl: imageRaw == null || imageRaw.isEmpty
          ? null
          : _normalizeMediaUrl(imageRaw, apiBaseUrl: apiBaseUrl),
      iconUrl: iconRaw == null || iconRaw.isEmpty
          ? null
          : _normalizeMediaUrl(iconRaw, apiBaseUrl: apiBaseUrl),
      ctaLabel: json['cta_label']?.toString(),
      meta: rawMeta,
    );
  }
}

class OnboardingStepContent {
  const OnboardingStepContent({
    required this.stepKey,
    required this.screenType,
    required this.title,
    required this.subtitle,
    required this.options,
    this.imageUrl,
    required this.ctaLabel,
    required this.skippable,
  });

  final String stepKey;
  final String screenType;
  final String title;
  final String? subtitle;
  final Map<String, dynamic> options;
  final String? imageUrl;
  final String ctaLabel;
  final bool skippable;

  List<OnboardingChoice> get choiceItems {
    final value = options['choices'];
    if (value is List) {
      return value.map((item) => OnboardingChoice.fromDynamic(item)).toList();
    }
    return const <OnboardingChoice>[];
  }

  int get sliderMin => _toInt(options['min']).clamp(1, 24);
  int get sliderMax => _toInt(options['max']).clamp(sliderMin, 24);
  int get sliderDefault => _toInt(options['default']).clamp(sliderMin, sliderMax);

  factory OnboardingStepContent.fromJson(Map<String, dynamic> json) {
    return OnboardingStepContent(
      stepKey: '${json['step_key'] ?? ''}',
      screenType: '${json['screen_type'] ?? 'single_choice'}',
      title: '${json['title'] ?? ''}',
      subtitle: json['subtitle']?.toString(),
      options: (json['options'] is Map<String, dynamic>)
          ? json['options'] as Map<String, dynamic>
          : <String, dynamic>{},
      imageUrl: json['image_url']?.toString(),
      ctaLabel: '${json['cta_label'] ?? 'Continue'}',
      skippable: json['skippable'] == true || json['skippable'] == 1,
    );
  }
}

class OnboardingChoice {
  const OnboardingChoice({
    required this.label,
    this.emoji,
    this.iconUrl,
  });

  final String label;
  final String? emoji;
  final String? iconUrl;

  factory OnboardingChoice.fromDynamic(dynamic item) {
    if (item is Map<String, dynamic>) {
      return OnboardingChoice(
        label: '${item['label'] ?? ''}',
        emoji: item['emoji']?.toString(),
        iconUrl: item['icon_url']?.toString(),
      );
    }
    return OnboardingChoice(label: '$item');
  }
}

class OnboardingStatCard {
  const OnboardingStatCard({
    required this.headline,
    required this.subline,
  });

  final String headline;
  final String subline;
}

OnboardingStatCard _coerceStatCard(dynamic item) {
  if (item is Map<String, dynamic>) {
    return OnboardingStatCard(
      headline: '${item['headline'] ?? item['title'] ?? item['value'] ?? 'Metric'}',
      subline: '${item['subline'] ?? item['subtitle'] ?? item['description'] ?? ''}',
    );
  }
  final text = '$item';
  return OnboardingStatCard(headline: text, subline: '');
}

const String _fallbackAudioUrl = 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3';
const Map<String, String> _mixerChannelUrls = <String, String>{
  'Rain': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-2.mp3',
  'Wind': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-3.mp3',
  'White Noise': 'https://www.soundhelix.com/examples/mp3/SoundHelix-Song-4.mp3',
};
const List<OnboardingStepContent> _fallbackOnboardingScreens = <OnboardingStepContent>[
  OnboardingStepContent(
    stepKey: 'welcome',
    screenType: 'welcome',
    title: 'Welcome',
    subtitle: "Let's begin your journey to peaceful sleep",
    options: <String, dynamic>{},
    ctaLabel: 'Start',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'help_goal',
    screenType: 'multi_choice',
    title: 'What can we help you with?',
    subtitle: 'We are here for you.',
    options: <String, dynamic>{
      'choices': <Map<String, String>>[
        {'label': 'Fall Asleep Faster', 'emoji': '🚀'},
        {'label': 'Sleep All Night', 'emoji': '⏰'},
        {'label': 'Relax & Unwind', 'emoji': '🛌'},
        {'label': 'Snoring Disruptions', 'emoji': '🛏️'},
        {'label': 'Manage Tinnitus', 'emoji': '👂'},
        {'label': 'Help My Kids Sleep', 'emoji': '🧸'},
        {'label': 'Reduce Anxiety', 'emoji': '🪴'},
        {'label': 'Release Stress', 'emoji': '🕊️'},
        {'label': 'Easier Mornings', 'emoji': '🌅'},
        {'label': 'Focus', 'emoji': '🎯'},
      ],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'age_group',
    screenType: 'single_choice',
    title: 'As we age, our sleep needs and challenges change',
    subtitle: 'Please select your age group.',
    options: <String, dynamic>{
      'choices': <String>['18 - 24', '25 - 34', '35 - 44', '45 - 54', '55+'],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'gender',
    screenType: 'single_choice',
    title: 'Hormone levels can influence sleep patterns',
    subtitle: 'Which option best describes you?',
    options: <String, dynamic>{
      'choices': <String>['Female', 'Male', 'Non-binary', 'Other'],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'current_sleep_hours',
    screenType: 'single_choice',
    title: 'How many hours of sleep are you currently getting?',
    subtitle: null,
    options: <String, dynamic>{
      'choices': <String>['Less than 5 hours', '5 hours', '6 hours', 'More than 7 hours'],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'desired_sleep_hours',
    screenType: 'slider',
    title: "Set the amount of hours you'd like to spend sleeping.",
    subtitle: 'Doctors recommend 7 to 9 hours every night to be healthy.',
    options: <String, dynamic>{'min': 5, 'max': 10, 'default': 8},
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'sleep_satisfaction',
    screenType: 'single_choice',
    title: 'How satisfied are you with your sleep?',
    subtitle: null,
    options: <String, dynamic>{
      'choices': <Map<String, String>>[
        {'label': 'Very Satisfied', 'emoji': '😁'},
        {'label': 'Neutral', 'emoji': '😐'},
        {'label': 'Unsatisfied', 'emoji': '🥱'},
        {'label': 'Very unsatisfied', 'emoji': '😔'},
      ],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'social_proof',
    screenType: 'info',
    title: 'Trusted by over 65 million people',
    subtitle: 'Preparing your sleep plan',
    options: <String, dynamic>{
      'stats': <Map<String, String>>[
        {'headline': '91%', 'subline': 'of listeners sleep better'},
        {'headline': '4.8★', 'subline': '600k+ reviews'},
        {'headline': '2B+', 'subline': 'relaxation sessions'},
        {'headline': '65x', 'subline': 'featured in App Store'},
      ],
    },
    ctaLabel: 'Continue',
    skippable: true,
  ),
  OnboardingStepContent(
    stepKey: 'email_capture',
    screenType: 'email',
    title: 'Stay Updated on Your Journey to Restful Nights',
    subtitle: 'Get weekly progress insights and new content to your inbox.',
    options: <String, dynamic>{},
    ctaLabel: 'Continue',
    skippable: true,
  ),
];

const List<HomeSectionContent> _fallbackHomeSections = <HomeSectionContent>[
  HomeSectionContent(
    sectionKey: 'featured_content',
    title: 'Featured content',
    subtitle: null,
    sectionType: 'hero_carousel',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Spring Forward',
        subtitle: 'Let us gently ease your body clock.',
        ctaLabel: 'Listen',
      ),
      HomeItemContent(
        title: 'Unwind Tonight',
        subtitle: 'Drift off with calm evening sessions.',
        ctaLabel: 'Listen',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'explore_grid',
    title: 'Explore more',
    subtitle: null,
    sectionType: 'grid',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Sounds', meta: <String, dynamic>{'emoji': '🔥'}),
      HomeItemContent(title: 'Mixes', meta: <String, dynamic>{'emoji': '🎭'}),
      HomeItemContent(title: 'Music', meta: <String, dynamic>{'emoji': '🎼'}),
      HomeItemContent(title: 'Meditations', meta: <String, dynamic>{'emoji': '🌅'}),
      HomeItemContent(title: 'SleepTales', meta: <String, dynamic>{'emoji': '📖'}),
      HomeItemContent(title: 'Favorites', meta: <String, dynamic>{'emoji': '❤️'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'promo_therapy',
    title: 'Still waking up tired?',
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'You have 50% off your first month of therapy',
        subtitle: 'Take the assessment',
        ctaLabel: 'Take the assessment',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sleep_recorder',
    title: 'Sleep Recorder',
    subtitle: 'Monitor and improve',
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Monitor and improve',
        subtitle: 'Consistency is the best way to improve sleep',
        ctaLabel: 'Start Recorder',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'colored_noises',
    title: 'Colored Noises',
    subtitle: 'A rainbow of noises awaits.',
    sectionType: 'chips',
    items: <HomeItemContent>[
      HomeItemContent(title: 'White Noise'),
      HomeItemContent(title: 'Green Noise'),
      HomeItemContent(title: 'Deep Brown'),
      HomeItemContent(title: 'Violet Noise'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'top_rated',
    title: 'Top 5 rated',
    subtitle: null,
    sectionType: 'top_ranked',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Green Noise Deep Sleep Hypnosis', subtitle: 'Meditation', meta: <String, dynamic>{'rank': 1}),
      HomeItemContent(title: "Rosemary's Quilt of Memories", subtitle: 'SleepTale', meta: <String, dynamic>{'rank': 2}),
      HomeItemContent(title: 'Bedtime Bliss Sleep Hypnosis', subtitle: 'Meditation', meta: <String, dynamic>{'rank': 3}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'quick_topics',
    title: null,
    subtitle: null,
    sectionType: 'chips',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Sleep Faster', meta: <String, dynamic>{'emoji': '🏁'}),
      HomeItemContent(title: 'Hypnosis', meta: <String, dynamic>{'emoji': '🌀'}),
      HomeItemContent(title: 'Napping', meta: <String, dynamic>{'emoji': '😴'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'discover_banner',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(title: 'DISCOVER'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sounds_featured',
    title: 'Sounds',
    subtitle: null,
    sectionType: 'hero_carousel',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Soothing Colored Noise', subtitle: 'Starter Mix'),
      HomeItemContent(title: 'Rain + Piano', subtitle: 'Sleep in 10 minutes'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sounds_my_sounds',
    title: 'My Sounds',
    subtitle: null,
    sectionType: 'grid',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Eternity'),
      HomeItemContent(title: 'Ocean'),
      HomeItemContent(title: 'Birds'),
      HomeItemContent(title: 'River'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sounds_popular',
    title: 'Popular',
    subtitle: null,
    sectionType: 'grid',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Night'),
      HomeItemContent(title: 'Campfire'),
      HomeItemContent(title: 'White Noise'),
      HomeItemContent(title: 'Brown Noise'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'music_hero',
    title: 'Music',
    subtitle: null,
    sectionType: 'hero_carousel',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Peaceful Unwind', subtitle: 'Find stillness and relax to alpha brainwave music.'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'music_top10',
    title: 'Top 10',
    subtitle: 'Enjoy music picked for you by DJ BetterSleep.',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Playlist: Classical Music', subtitle: 'Playlist • 1 h 33 min'),
      HomeItemContent(title: 'Clarity and Alertness', subtitle: 'Music'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'music_layers',
    title: 'Music Layers',
    subtitle: 'Create your own bedtime soundtrack with evolving music loops.',
    sectionType: 'chips',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Droning Bass', subtitle: 'Music Layers'),
      HomeItemContent(title: 'Pulsing Bass', subtitle: 'Music Layers'),
      HomeItemContent(title: 'Echoing Harmony', subtitle: 'Music Layers'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'mixes_favorites',
    title: 'My Favorites Mixes',
    subtitle: 'Unwind with your own personal selection of favorite sounds.',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Your First Mix', subtitle: 'Mix'),
      HomeItemContent(title: 'Create a mix', subtitle: 'Mix'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'mixes_featured',
    title: 'Spring Forward',
    subtitle: 'Let us gently ease you into the time change.',
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Spring Forward', subtitle: 'Let us gently ease your body into easy rest', ctaLabel: 'Listen'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'mixes_sound_escapes',
    title: 'Sound Escapes',
    subtitle: 'Leave stress behind and sink into rich soundscapes.',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Dusk in the Amazon Jungle', subtitle: 'Mix'),
      HomeItemContent(title: 'Rainy Day at Lake Titicaca', subtitle: 'Mix'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'meditation_promoted',
    title: 'Promoted content',
    subtitle: null,
    sectionType: 'hero_carousel',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Discover Meditation: 1 Minute Guide To Your Relaxation Tool', subtitle: 'Video • by Andrew Green'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'meditation_bedtime',
    title: 'Your bedtime wind-downs',
    subtitle: 'Let go of the day and ease into sleep.',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Starlight Bedtime Hypnosis', subtitle: 'Meditation • 35 min'),
      HomeItemContent(title: 'Bedtime Bliss Sleep Hypnosis', subtitle: 'Meditation • 1 h 28 min'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'meditation_new',
    title: 'New releases & popular guidances',
    subtitle: 'Try new guidances and all-time favorites.',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Green Noise Deep Sleep Hypnosis', subtitle: 'Meditation'),
      HomeItemContent(title: 'Back to Sleep Hypnosis', subtitle: 'Meditation'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sleeptales_promoted',
    title: 'Promoted content',
    subtitle: null,
    sectionType: 'hero_carousel',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Discover SleepTales: 1 Minute Guide to Your Bedtime Tool', subtitle: 'Video • by Shogo Miyakita'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sleeptales_popular',
    title: 'Popular SleepTales',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'The Wonderful Wizard of Oz, Part 1', subtitle: 'SleepTale • 52 min'),
      HomeItemContent(title: 'The Underwater City', subtitle: 'SleepTale • 49 min'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'sleeptales_cozy',
    title: 'Get cozy with easy listens',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: '2 a.m. at the Blueberry Hill Diner', subtitle: 'SleepTale • 26 min'),
      HomeItemContent(title: 'Camping at Moonlit Lake', subtitle: 'SleepTale • 28 min'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'routine_habits',
    title: 'HABITS',
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(title: "You don't have any habits. Tap the plus to add one."),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'routine_wind_down',
    title: 'WIND DOWN',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Dropping into the Present Moment', subtitle: 'Meditation • 14 min'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'routine_sleep',
    title: 'SLEEP',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Track your sleep', subtitle: 'Tap to learn more info.', meta: <String, dynamic>{'toggle': true}),
      HomeItemContent(title: 'Night Wind', subtitle: 'Mix • 1 h 0 min'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'routine_recommendation',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Want to try a different routine?',
        subtitle: 'Select a new routine and customize it to suit your sleep needs',
        ctaLabel: 'Explore more',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'insight_sleep_quality',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'No Sleep Quality Yet',
        subtitle: 'Track your sleep tonight and wake up to detailed insights here.',
        meta: <String, dynamic>{'score': 0},
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'insight_snore',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Do you snore?',
        subtitle: "Record your sleep sounds to uncover what's disturbing your rest.",
        ctaLabel: 'Track my sleep',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'insight_phases',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Your Sleep Phases',
        subtitle: 'Learn more about your sleeping patterns and how to improve them.',
        ctaLabel: 'Learn more',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'saved_favorites',
    title: 'Favorites',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Train Your Brain to Sleep Better', subtitle: 'Meditation • 51 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Fall Asleep Faster', subtitle: '6 h 19 min', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Vanquish 3 a.m. Insomnia', subtitle: 'Meditation • 57 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Lucid Dreaming Brainwaves', subtitle: 'Mix • 2 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Sound Meditation: Brown Noise', subtitle: 'Meditation • 30 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Ocean Wave Therapy', subtitle: 'Mix • 3 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'An Evening with Galileo', subtitle: 'SleepTale • 30 min', meta: <String, dynamic>{'action': 'more'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'saved_recently_played',
    title: 'Recently Played',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Dropping into the Present Moment', subtitle: 'Meditation • 14 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Green Noise Deep Sleep Hypnosis', subtitle: 'Meditation • 30 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Your First Mix', subtitle: 'Mix • 3 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Oceanscape', subtitle: 'Mix • 7 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Emotional Release', subtitle: 'Music', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Calming City Rain', subtitle: 'Mix • 3 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'The Underwater City', subtitle: 'SleepTale • 49 min', meta: <String, dynamic>{'action': 'more'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'saved_playlists',
    title: 'Playlists',
    subtitle: 'Created for you',
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Fall Asleep Faster', subtitle: '6 h 19 min', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Deep Sleep', subtitle: '5 h 37 min', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Bilateral Music For Anxiety', subtitle: '21 min', meta: <String, dynamic>{'action': 'arrow'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'saved_find_love',
    title: 'Find something you love',
    subtitle: null,
    sectionType: 'grid',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Create and Save a Mix'),
      HomeItemContent(title: 'Drift off to a SleepTale'),
      HomeItemContent(title: 'Relax to a Guided Meditation'),
      HomeItemContent(title: 'Snooze to curated Music'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'saved_suggestions',
    title: 'Suggestions for you',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Green Noise Deep Sleep Hypnosis', subtitle: 'Meditation • 30 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: 'Oceanscape', subtitle: 'Mix • 7 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Emotional Release', subtitle: 'Music', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'Calming City Rain', subtitle: 'Mix • 3 items', meta: <String, dynamic>{'action': 'heart'}),
      HomeItemContent(title: 'The Underwater City', subtitle: 'SleepTale • 49 min', meta: <String, dynamic>{'action': 'more'}),
      HomeItemContent(title: '3D Rain Narrative', subtitle: 'Meditation • 30 min', meta: <String, dynamic>{'action': 'more'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_top_promo',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'You have 50% off your first month of therapy',
        subtitle: 'Take the assessment',
        ctaLabel: 'Take the assessment →',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_header',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Sleeper'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_chronotype',
    title: null,
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Discover Your Chronotype',
        subtitle: "Find your body's natural sleep schedule.",
        meta: <String, dynamic>{'action': 'arrow'},
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_auth_card',
    title: null,
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Create an account',
        subtitle: 'Save your chronotype, analysis and sleep insights to get personalized recommendations.',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_promo_therapy',
    title: 'Still waking up tired?',
    subtitle: null,
    sectionType: 'promo',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'You have 50% off your first month of therapy',
        subtitle: 'Take the assessment',
        ctaLabel: 'Take the assessment',
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_resources',
    title: 'BetterSleep Resources',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Alarm', meta: <String, dynamic>{'action': 'pill', 'badge': 'SET'}),
      HomeItemContent(title: 'Bedtime', meta: <String, dynamic>{'action': 'pill', 'badge': 'SET'}),
      HomeItemContent(title: 'Sleep Goal', meta: <String, dynamic>{'action': 'arrow', 'value': '8h'}),
      HomeItemContent(title: 'Sleep Tracker Widget', meta: <String, dynamic>{'action': 'pill', 'badge': 'ADD'}),
      HomeItemContent(title: 'Help & Support'),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_account',
    title: 'Account',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(
        title: 'Subscription',
        subtitle: 'Yearly',
        meta: <String, dynamic>{'action': 'pill', 'badge': 'MANAGE'},
      ),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_settings_main',
    title: 'Settings',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Change Language', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'My Data', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(
        title: 'Play with other apps',
        subtitle: 'Allow playing music from other apps alongside BetterSleep.',
        meta: <String, dynamic>{'action': 'toggle', 'enabled': true},
      ),
      HomeItemContent(title: 'Clear Downloads', meta: <String, dynamic>{'action': 'arrow'}),
    ],
  ),
  HomeSectionContent(
    sectionKey: 'profile_settings_more',
    title: 'More',
    subtitle: null,
    sectionType: 'horizontal',
    items: <HomeItemContent>[
      HomeItemContent(title: 'Help & Support', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Rate Our App', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Terms of Service', meta: <String, dynamic>{'action': 'arrow'}),
      HomeItemContent(title: 'Privacy Policy', meta: <String, dynamic>{'action': 'arrow'}),
    ],
  ),
];

class SleepWellApi {
  static const String baseUrl = String.fromEnvironment(
    'SLEEPWELL_API_BASE_URL',
    defaultValue: 'https://cariloker.info/api/v1/sleepwell',
  );

  static String get defaultDeviceId {
    final host = Platform.localHostname.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    return 'sleepwell-${Platform.operatingSystem.toLowerCase()}-$host';
  }

  String? _authToken;

  void setAuthToken(String? value) {
    _authToken = value;
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

  Future<void> submitOnboardingResponses({
    required String deviceId,
    required Map<String, dynamic> answers,
  }) async {
    await _request(
      'POST',
      '/onboarding/responses',
      body: {
        'device_id': deviceId,
        'answers': answers,
      },
    );
  }

  Future<List<OnboardingStepContent>> fetchOnboardingContent() async {
    final json = await _request('GET', '/onboarding/content');
    final raw = (json['screens'] as List<dynamic>? ?? <dynamic>[]);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(OnboardingStepContent.fromJson)
        .toList();
  }

  Future<List<HomeSectionContent>> fetchHomeFeed({
    String? goal,
    String? timeSegment,
    String? deviceId,
  }) async {
    final params = <String>[];
    if (goal != null && goal.isNotEmpty) {
      params.add('goal=${Uri.encodeQueryComponent(goal)}');
    }
    if (timeSegment != null && timeSegment.isNotEmpty) {
      params.add('time_segment=${Uri.encodeQueryComponent(timeSegment)}');
    }
    if (deviceId != null && deviceId.isNotEmpty) {
      params.add('device_id=${Uri.encodeQueryComponent(deviceId)}');
    }
    final suffix = params.isEmpty ? '' : '?${params.join('&')}';
    final json = await _request('GET', '/home-feed$suffix');
    final raw = (json['sections'] as List<dynamic>? ?? <dynamic>[]);
    return raw
        .whereType<Map<String, dynamic>>()
        .map((item) => HomeSectionContent.fromJson(item, apiBaseUrl: baseUrl))
        .toList();
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

  Future<AuthResult> register({
    required String name,
    required String email,
    required String password,
    required String deviceId,
  }) async {
    final json = await _request(
      'POST',
      '/auth/register',
      body: {
        'name': name,
        'email': email,
        'password': password,
        'device_id': deviceId,
      },
    );
    final token = '${json['token'] ?? ''}';
    final user = AppUserProfile.fromJson(
      (json['user'] is Map<String, dynamic>) ? json['user'] as Map<String, dynamic> : <String, dynamic>{},
    );
    return AuthResult(token: token, user: user);
  }

  Future<AuthResult> login({
    required String email,
    required String password,
    required String deviceId,
  }) async {
    final json = await _request(
      'POST',
      '/auth/login',
      body: {
        'email': email,
        'password': password,
        'device_id': deviceId,
      },
    );
    final token = '${json['token'] ?? ''}';
    final user = AppUserProfile.fromJson(
      (json['user'] is Map<String, dynamic>) ? json['user'] as Map<String, dynamic> : <String, dynamic>{},
    );
    return AuthResult(token: token, user: user);
  }

  Future<void> logout() async {
    await _request('POST', '/auth/logout');
  }

  Future<AppUserProfile> fetchMe() async {
    final json = await _request('GET', '/auth/me');
    final userRaw = (json['user'] is Map<String, dynamic>)
        ? json['user'] as Map<String, dynamic>
        : <String, dynamic>{};
    return AppUserProfile.fromJson(userRaw);
  }

  Future<SleepInsights> fetchInsightsForUser() async {
    final json = await _request('GET', '/insights');
    return SleepInsights.fromJson(json);
  }

  Future<List<MixPreset>> fetchMixPresetsForUser() async {
    final json = await _request('GET', '/mix-presets');
    final presetsRaw = (json['presets'] as List<dynamic>? ?? <dynamic>[]);
    return presetsRaw
        .whereType<Map<String, dynamic>>()
        .map(MixPreset.fromJson)
        .toList();
  }

  Future<List<SavedContentItem>> fetchSavedItems({String? type}) async {
    final query = (type == null || type.isEmpty) ? '' : '?type=$type';
    final json = await _request('GET', '/saved-items$query');
    final raw = (json['items'] as List<dynamic>? ?? <dynamic>[]);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SavedContentItem.fromJson)
        .toList();
  }

  Future<void> upsertSavedItem({
    required String itemType,
    required String itemRef,
    required String title,
    String? subtitle,
    Map<String, dynamic> meta = const <String, dynamic>{},
    DateTime? ifUnmodifiedSince,
  }) async {
    await _request(
      'POST',
      '/saved-items',
      body: {
        'item_type': itemType,
        'item_ref': itemRef,
        'title': title,
        'subtitle': subtitle,
        'meta': meta,
        if (ifUnmodifiedSince != null) 'if_unmodified_since': ifUnmodifiedSince.toIso8601String(),
      },
    );
  }

  Future<List<SleepTrack>> searchTracks(
    String query, {
    String? deviceId,
    String? goal,
    String? timeSegment,
  }) async {
    final params = <String>['q=${Uri.encodeQueryComponent(query)}'];
    if (deviceId != null && deviceId.isNotEmpty) {
      params.add('device_id=${Uri.encodeQueryComponent(deviceId)}');
    }
    if (goal != null && goal.isNotEmpty) {
      params.add('goal=${Uri.encodeQueryComponent(goal)}');
    }
    if (timeSegment != null && timeSegment.isNotEmpty) {
      params.add('time_segment=${Uri.encodeQueryComponent(timeSegment)}');
    }
    final json = await _request('GET', '/search?${params.join('&')}');
    final raw = (json['results'] as List<dynamic>? ?? <dynamic>[]);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(SleepTrack.fromJson)
        .toList();
  }

  Future<List<AdPlacementConfig>> fetchAdPlacements() async {
    final json = await _request('GET', '/ad-placements');
    final raw = (json['placements'] as List<dynamic>? ?? <dynamic>[]);
    return raw
        .whereType<Map<String, dynamic>>()
        .map(AdPlacementConfig.fromJson)
        .toList();
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
    if (_authToken != null && _authToken!.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_authToken');
    }
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

String _formatTimeOfDay(TimeOfDay value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}
