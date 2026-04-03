import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:just_audio/just_audio.dart';
import 'package:just_audio_background/just_audio_background.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';

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

enum TrackPlayerKind {
  meditation,
  sound,
  music,
  brainwave,
  other,
}

Widget _playerPageForTrack({
  required SleepWellState state,
  required SleepTrack track,
}) {
  return NowPlayingPage(state: state, track: track);
}

Future<void> openSleepRecorderFlow(
  BuildContext context,
  SleepWellState state, {
  SleepTrack? preferredTrack,
  String entryPoint = 'track_my_sleep',
}) async {
  if (state.selectedTrack == null && preferredTrack != null) {
    await state.playTrack(preferredTrack);
  } else if (state.selectedTrack == null && state.tracks.isNotEmpty) {
    await state.playTrack(state.tracks.first);
  }
  if (!context.mounted) {
    return;
  }
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => SleepRecorderFlowPage(
        state: state,
        preferredTrack: preferredTrack ?? state.selectedTrack,
        entryPoint: entryPoint,
      ),
    ),
  );
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
  static const double savedMiniPlayerBottomGap = 10;

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
  AudioRecorder? _recorder;
  final Map<String, AudioPlayer> _mixerPlayers = <String, AudioPlayer>{};
  SharedPreferences? _prefs;
  StreamSubscription<Duration>? _positionSubscription;
  StreamSubscription<PlayerState>? _playerStateSubscription;
  Timer? _sleepTimer;
  Timer? _sleepTimerTicker;
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
  final List<SavedContentItem> localMixItems = <SavedContentItem>[];
  final Set<String> localFavoriteRefs = <String>{};
  final Set<String> localDownloadRefs = <String>{};
  final Set<String> _activeMixKinds = <String>{};
  final List<Map<String, dynamic>> _queuedEvents = <Map<String, dynamic>>[];
  List<AdPlacementConfig> adPlacements = <AdPlacementConfig>[];
  final Map<String, bool> settingsToggles = <String, bool>{};
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
  final List<TrackedSleepNight> trackedNights = <TrackedSleepNight>[];
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
  bool wakeAlarmEnabled = false;
  TimeOfDay wakeAlarmTime = const TimeOfDay(hour: 8, minute: 0);
  int smartAlarmWindowMinutes = 30;
  String appLanguage = 'en';
  int sleepGoalHours = 8;
  bool microphonePermissionGranted = false;
  bool hasUsedSleepRecorder = false;
  bool sleepRecorderActive = false;
  DateTime? sleepRecorderStartedAt;
  DateTime? _lastBedtimeTriggerAt;
  int sleepTimerMinutes = 30;
  DateTime? _sleepTimerEndsAt;
  String? selectedInsightNightId;
  int insightsTabIndex = 0;
  DateTime insightsCalendarMonth = DateTime.now();
  Duration currentPosition = Duration.zero;
  Duration currentDuration = Duration.zero;
  double mainPlayerVolume = 1.0;
  SleepTrack? selectedTrack;
  int? _activeSessionId;
  DateTime? _sessionStartedAt;
  String? _activeTrackedNightId;
  String? _activeRecordingPath;
  SleepInsights insights = const SleepInsights(
    usageFrequencyLast7Days: 0,
    consistencyScore: 0,
    averageDurationMinutes: 0,
    nights: <TrackedSleepNight>[],
    availableDates: <DateTime>[],
  );
  List<OnboardingStepContent> onboardingScreens = <OnboardingStepContent>[];

  bool get isAuthenticated => authToken != null && currentUser != null;

  List<SleepTrack> tracks = <SleepTrack>[
    const SleepTrack(
      title: 'Moonlight Whispers',
      subtitle: 'Gentle sleep story',
      category: 'whisper',
      talking: true,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'Forest Rain Deep Sleep',
      subtitle: 'Steady rain ambience',
      category: 'rain',
      talking: false,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'No Talking Brown Noise',
      subtitle: 'My Favorite Mix',
      category: 'no_talking',
      talking: false,
      streamUrl: _fallbackAudioUrl,
      durationSeconds: 3600,
    ),
    const SleepTrack(
      title: 'Night Spa Roleplay',
      subtitle: 'Guided wind-down session',
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

    if (selectedTrack != null) {
      _seedActiveMixKindsForTrack(selectedTrack!);
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
    _seedActiveMixKindsForTrack(track);
    sessions.add(SleepSession(DateTime.now(), 0));
    await _startSession(mode: 'player', entryPoint: 'player_track_tap');
    await _playSelectedTrack();
    await _logEvent('play');
    if (isAuthenticated) {
      final playedAt = DateTime.now();
      unawaited(
        upsertSavedItem(
          itemType: 'recently_played',
          itemRef: '${track.id ?? track.title}',
          title: track.title,
          subtitle: track.displaySubtitle,
          lastPlayedAt: playedAt,
          meta: <String, dynamic>{
            'track_id': track.id,
            'track_subtitle': track.subtitle,
          },
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
    _activeMixKinds.clear();
    sleepRecorderActive = false;
    sleepRecorderStartedAt = null;
    await _persistLocalState();
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

  List<SavedContentItem> get savedMixItems {
    final items = <SavedContentItem>[...localMixItems];
    final refs = items.map((item) => item.itemRef).toSet();
    for (final item in savedCloudItems.where((saved) => saved.itemType == 'mix')) {
      if (refs.add(item.itemRef)) {
        items.add(item);
      }
    }
    items.sort((a, b) => (b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0))
        .compareTo(a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0)));
    return items;
  }

  bool isMixSaved({
    SleepTrack? track,
    TrackPlayerKind? activeKind,
  }) {
    return savedMixFor(track: track, activeKind: activeKind) != null;
  }

  SavedContentItem? savedMixFor({
    SleepTrack? track,
    TrackPlayerKind? activeKind,
  }) {
    final ref = _mixItemRef(track: track, activeKind: activeKind);
    for (final item in savedMixItems) {
      if (item.itemRef == ref) {
        return item;
      }
    }
    return null;
  }

  Future<SavedContentItem> saveNamedMix({
    required String name,
    SleepTrack? track,
    TrackPlayerKind? activeKind,
  }) async {
    final baseTrack = track ?? selectedTrack;
    if (baseTrack == null) {
      throw StateError('No track selected.');
    }
    final normalizedKind = _normalizedTrackKind(activeKind ?? baseTrack.playerKind);
    final includedKinds = _currentMixKinds(normalizedKind);
    final itemCount = max(1, includedKinds.length);
    final now = DateTime.now();
    final mixItem = SavedContentItem(
      id: -now.microsecondsSinceEpoch,
      itemType: 'mix',
      itemRef: _mixItemRef(track: baseTrack, activeKind: normalizedKind),
      title: name,
      subtitle: 'Mix • $itemCount ${itemCount == 1 ? 'item' : 'items'}',
      meta: <String, dynamic>{
        'track_id': baseTrack.id,
        'track_title': baseTrack.title,
        'track_kind': normalizedKind.name,
        'channels': _normalizedMixerChannels(),
        'included_types': includedKinds,
        'item_count': itemCount,
      },
      updatedAt: now,
    );

    localMixItems.removeWhere((item) => item.itemRef == mixItem.itemRef);
    localMixItems.insert(0, mixItem);
    await _persistLocalState();

    if (isAuthenticated) {
      try {
        await _api.upsertSavedItem(
          itemType: 'mix',
          itemRef: mixItem.itemRef,
          title: mixItem.title,
          subtitle: mixItem.subtitle,
          meta: mixItem.meta,
        );
        await refreshCloudSavedItems();
        apiConnected = true;
      } catch (_) {
        apiConnected = false;
      }
    }
    notifyListeners();
    return mixItem;
  }

  Future<void> deleteMix({
    SleepTrack? track,
    TrackPlayerKind? activeKind,
  }) async {
    final item = savedMixFor(track: track, activeKind: activeKind);
    if (item == null) {
      return;
    }
    await deleteMixByRef(item.itemRef);
  }

  Future<void> deleteMixByRef(String itemRef) async {
    localMixItems.removeWhere((saved) => saved.itemRef == itemRef);
    if (isAuthenticated) {
      final cloudItems = savedCloudItems
          .where((saved) => saved.itemType == 'mix' && saved.itemRef == itemRef)
          .toList();
      for (final cloud in cloudItems) {
        try {
          await _api.deleteSavedItem(cloud.id);
        } catch (_) {
          apiConnected = false;
        }
      }
      await refreshCloudSavedItems();
    }
    await _persistLocalState();
    notifyListeners();
  }

  Future<void> playSavedMix(SavedContentItem item) async {
    final meta = item.meta;
    SleepTrack? target;
    final trackId = _nullableInt(meta['track_id']);
    final trackTitle = meta['track_title']?.toString();
    if (trackId != null) {
      for (final track in tracks) {
        if (track.id == trackId) {
          target = track;
          break;
        }
      }
    }
    if (target == null && trackTitle != null && trackTitle.isNotEmpty) {
      for (final track in tracks) {
        if (track.title.toLowerCase() == trackTitle.toLowerCase()) {
          target = track;
          break;
        }
      }
    }
    target ??= selectedTrack ?? (tracks.isNotEmpty ? tracks.first : null);
    if (target == null) {
      return;
    }

    await playTrack(target);

    final channelsRaw = meta['channels'] is Map<String, dynamic>
        ? meta['channels'] as Map<String, dynamic>
        : <String, dynamic>{};
    for (final entry in channelsRaw.entries) {
      final value = _toDouble(entry.value).clamp(0.0, 1.0);
      mixer[entry.key] = value;
      if (_enableAudio && isMixerPlaying && _mixerPlayers[entry.key] != null) {
        await _mixerPlayers[entry.key]!.setVolume(value);
      }
    }

    final includedRaw = meta['included_types'] is List
        ? (meta['included_types'] as List).map((value) => '$value').toList()
        : <String>[];
    _activeMixKinds
      ..clear()
      ..addAll(includedRaw.where((value) => value.isNotEmpty));
    if (_activeMixKinds.isEmpty) {
      _seedActiveMixKindsForTrack(target);
    }
    await _persistLocalState();
    notifyListeners();
  }

  void enableMixKind(TrackPlayerKind kind) {
    final normalized = _normalizedTrackKind(kind);
    if (_activeMixKinds.add(normalized.name)) {
      unawaited(_persistLocalState());
      notifyListeners();
    }
  }

  TrackPlayerKind _normalizedTrackKind(TrackPlayerKind kind) {
    return kind == TrackPlayerKind.other ? TrackPlayerKind.meditation : kind;
  }

  void _seedActiveMixKindsForTrack(SleepTrack track) {
    _activeMixKinds
      ..clear()
      ..add(_normalizedTrackKind(track.playerKind).name);
    unawaited(_persistLocalState());
  }

  List<String> _currentMixKinds(TrackPlayerKind fallbackKind) {
    final kinds = _activeMixKinds.isEmpty ? <String>[fallbackKind.name] : _activeMixKinds.toList();
    kinds.sort();
    return kinds;
  }

  Map<String, double> _normalizedMixerChannels() {
    final channels = <String, double>{};
    final keys = mixer.keys.toList()..sort();
    for (final key in keys) {
      channels[key] = mixer[key]!.clamp(0.0, 1.0);
    }
    return channels;
  }

  String _mixItemRef({
    SleepTrack? track,
    TrackPlayerKind? activeKind,
  }) {
    final baseTrack = track ?? selectedTrack;
    final fallbackKind = activeKind ??
        (baseTrack == null ? TrackPlayerKind.meditation : _normalizedTrackKind(baseTrack.playerKind));
    final payload = <String, dynamic>{
      'track_id': baseTrack?.id,
      'track_title': baseTrack?.title ?? '',
      'track_kind': fallbackKind.name,
      'included_types': _currentMixKinds(fallbackKind),
      'channels': _normalizedMixerChannels(),
    };
    return base64Url.encode(utf8.encode(jsonEncode(payload)));
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

  void setSleepGoalHours(int hours) {
    sleepGoalHours = hours.clamp(6, 10);
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setSmartAlarmWindowMinutes(int minutes) {
    smartAlarmWindowMinutes = minutes.clamp(0, 60);
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setMicrophonePermissionGranted(bool granted) {
    microphonePermissionGranted = granted;
    if (granted) {
      hasUsedSleepRecorder = true;
    }
    unawaited(_persistLocalState());
    notifyListeners();
  }

  Future<void> startSleepRecorder({SleepTrack? preferredTrack}) async {
    if (preferredTrack != null && selectedTrack == null) {
      selectedTrack = preferredTrack;
    }
    if (selectedTrack == null && tracks.isNotEmpty) {
      await playTrack(tracks.first);
    }
    final permissionGranted = await _ensureRecorderPermission();
    if (!permissionGranted) {
      lastError = 'Microphone permission is required to track sleep.';
      notifyListeners();
      return;
    }
    if (sleepRecorderActive) {
      hasUsedSleepRecorder = true;
      await _persistLocalState();
      notifyListeners();
      return;
    }

    final startedAt = DateTime.now();
    final recordingPath = await _createRecordingFilePath(startedAt);
    final activeKinds = _currentMixKinds(
      selectedTrack == null ? TrackPlayerKind.meditation : _normalizedTrackKind(selectedTrack!.playerKind),
    );
    final metadata = <String, dynamic>{
      'preferred_track_title': selectedTrack?.title,
      'preferred_track_kind': selectedTrack?.playerKind.name,
      'active_mix_kinds': activeKinds,
      'mixer_channels': _normalizedMixerChannels(),
    };
    TrackedSleepNight? startedNight;
    try {
      startedNight = await _api.startTrackedNight(
        deviceId: deviceId,
        sessionId: _activeSessionId,
        preferredTrackId: selectedTrack?.id,
        entryPoint: 'track_my_sleep',
        startedAt: startedAt,
        trackedDate: startedAt,
        sleepGoalMinutes: sleepGoalHours * 60,
        smartAlarmWindowMinutes: smartAlarmWindowMinutes,
        wakeAlarmTime: _formatTimeOfDay(wakeAlarmTime),
        mixSnapshot: <String, dynamic>{
          'included_types': activeKinds,
          'channels': _normalizedMixerChannels(),
        },
        metadata: metadata,
      );
      apiConnected = true;
    } catch (_) {
      apiConnected = false;
      startedNight = TrackedSleepNight.active(
        nightId: 'local-${startedAt.microsecondsSinceEpoch}',
        trackedDate: DateTime(startedAt.year, startedAt.month, startedAt.day),
        bedtime: startedAt,
        sleepGoalMinutes: sleepGoalHours * 60,
        localRecordingPath: recordingPath,
        wakeAlarmLabel: _formatTimeOfDay(wakeAlarmTime),
        metadata: metadata,
      );
    }

    try {
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000,
          sampleRate: 44100,
        ),
        path: recordingPath,
      );
      microphonePermissionGranted = true;
    } catch (_) {
      lastError = 'Sleep recorder could not start.';
      notifyListeners();
      return;
    }

    hasUsedSleepRecorder = true;
    sleepRecorderActive = true;
    sleepRecorderStartedAt = startedAt;
    _activeRecordingPath = recordingPath;
    _activeTrackedNightId = startedNight.nightId;
    _upsertTrackedNight(
      startedNight.copyWith(
        localRecordingPath: recordingPath,
        wakeAlarmLabel: _formatTimeOfDay(wakeAlarmTime),
      ),
    );
    if (!wakeAlarmEnabled) {
      wakeAlarmEnabled = true;
    }
    await _persistLocalState();
    await logUiAction('sleep_recorder_start');
    notifyListeners();
  }

  Future<void> stopSleepRecorder() async {
    if (!sleepRecorderActive) {
      return;
    }
    final endedAt = DateTime.now();
    String? recordedPath;
    try {
      recordedPath = await _audioRecorder.stop();
    } catch (_) {
      recordedPath = _activeRecordingPath;
    }
    TrackedSleepNight? trackedNight;
    for (final night in trackedNights) {
      if (night.nightId == _activeTrackedNightId) {
        trackedNight = night;
        break;
      }
    }
    if (trackedNight != null) {
      await _finalizeTrackedNight(
        trackedNight,
        endedAt: endedAt,
        recordingPath: recordedPath ?? _activeRecordingPath,
      );
    }
    sleepRecorderActive = false;
    sleepRecorderStartedAt = null;
    _activeRecordingPath = null;
    _activeTrackedNightId = null;
    await stopPlayback();
    await logUiAction('sleep_recorder_stop');
    await _persistLocalState();
    await refreshInsights();
    notifyListeners();
  }

  Future<bool> _ensureRecorderPermission() async {
    try {
      final granted = await _audioRecorder.hasPermission();
      setMicrophonePermissionGranted(granted);
      return granted;
    } catch (_) {
      return false;
    }
  }

  Future<String> _createRecordingFilePath(DateTime startedAt) async {
    final directory = await getApplicationDocumentsDirectory();
    final recordingsDir = Directory('${directory.path}/sleep_recordings');
    if (!await recordingsDir.exists()) {
      await recordingsDir.create(recursive: true);
    }
    final name = 'night-${startedAt.millisecondsSinceEpoch}.m4a';
    return '${recordingsDir.path}/$name';
  }

  Future<void> _finalizeTrackedNight(
    TrackedSleepNight trackedNight, {
    required DateTime endedAt,
    required String? recordingPath,
  }) async {
    final durationMinutes = max(
      1,
      endedAt.difference(trackedNight.bedtime ?? endedAt).inMinutes,
    );
    final durationSeconds = max(
      60,
      endedAt.difference(trackedNight.bedtime ?? endedAt).inSeconds,
    );
    var updatedNight = trackedNight.copyWith(
      status: 'completed',
      wakeTime: endedAt,
      timeAsleepMinutes: durationMinutes,
      localRecordingPath: recordingPath,
    );

    try {
      if (!updatedNight.isLocalOnly && recordingPath != null && File(recordingPath).existsSync()) {
        await _api.uploadTrackedNightRecording(
          nightId: updatedNight.nightId,
          deviceId: deviceId,
          recordingPath: recordingPath,
          durationSeconds: durationSeconds,
        );
      }
      if (!updatedNight.isLocalOnly) {
        updatedNight = await _api.completeTrackedNight(
          nightId: updatedNight.nightId,
          deviceId: deviceId,
          endedAt: endedAt,
          recordingDurationSeconds: durationSeconds,
          metadata: <String, dynamic>{
            'sleep_goal_hours': sleepGoalHours,
            'smart_alarm_window_minutes': smartAlarmWindowMinutes,
          },
        );
        apiConnected = true;
      } else {
        updatedNight = _buildLocalTrackedNightSummary(updatedNight);
        apiConnected = false;
      }
    } catch (_) {
      updatedNight = _buildLocalTrackedNightSummary(updatedNight);
      apiConnected = false;
    }

    _upsertTrackedNight(updatedNight);
    insights = _buildLocalInsights();
    await _persistLocalState();
  }

  TrackedSleepNight _buildLocalTrackedNightSummary(TrackedSleepNight trackedNight) {
    final durationMinutes = max(1, trackedNight.timeAsleepMinutes);
    final goalMinutes = max(360, min(600, trackedNight.sleepGoalMinutes));
    final qualityScore = max(
      48,
      min(96, 92 - (durationMinutes - goalMinutes).abs() ~/ 14),
    );
    final awake = max(0, (durationMinutes * 0.05).round());
    final dream = max(20, (durationMinutes * 0.15).round());
    final deep = max(30, (durationMinutes * 0.12).round());
    final light = max(0, durationMinutes - awake - dream - deep);
    final totals = <String, int>{
      'awake': awake,
      'dream': dream,
      'light': light,
      'deep': deep,
    };
    final timeline = <SleepPhaseTimelinePoint>[];
    var minuteOffset = 0;
    for (final phase in <MapEntry<String, int>>[
      MapEntry<String, int>('light', max(1, light ~/ 4)),
      MapEntry<String, int>('deep', max(1, deep ~/ 2)),
      MapEntry<String, int>('light', max(1, light ~/ 4)),
      MapEntry<String, int>('dream', max(1, dream ~/ 2)),
      MapEntry<String, int>('light', max(1, light - (light ~/ 2))),
      MapEntry<String, int>('dream', max(1, dream - (dream ~/ 2))),
      MapEntry<String, int>('awake', max(1, awake)),
    ]) {
      timeline.add(
        SleepPhaseTimelinePoint(
          minuteOffset: minuteOffset,
          minutes: phase.value,
          phase: phase.key,
        ),
      );
      minuteOffset += phase.value;
    }

    final soundDetections = <SoundDetectionData>[
      SoundDetectionData(
        key: 'snoring',
        label: 'Snoring',
        emoji: '😴',
        count: durationMinutes > 360 ? 1 : 0,
        status: durationMinutes > 360 ? '1 clip' : 'None',
        minutes: durationMinutes > 360 ? 2 : 0,
        confidenceScore: durationMinutes > 360 ? 68 : 0,
      ),
      const SoundDetectionData(
        key: 'noise',
        label: 'Noise',
        emoji: '💥',
        count: 0,
        status: 'None',
        minutes: 0,
        confidenceScore: 0,
      ),
      const SoundDetectionData(
        key: 'music',
        label: 'Music',
        emoji: '💿',
        count: 0,
        status: 'None',
        minutes: 0,
        confidenceScore: 0,
      ),
      const SoundDetectionData(
        key: 'traffic',
        label: 'Traffic',
        emoji: '🚦',
        count: 0,
        status: 'None',
        minutes: 0,
        confidenceScore: 0,
      ),
      const SoundDetectionData(
        key: 'talking',
        label: 'Talking',
        emoji: '💬',
        count: 0,
        status: 'None',
        minutes: 0,
        confidenceScore: 0,
      ),
    ];

    final recordings = trackedNight.localRecordingPath == null
        ? const <NightRecordingData>[]
        : <NightRecordingData>[
            NightRecordingData(
              id: '${trackedNight.nightId}-1',
              label: 'Snoring',
              description: 'Detected once during the night.',
              detectionKey: 'snoring',
              startSecond: 180,
              durationSeconds: 24,
              confidenceScore: 68,
              occurredAt: (trackedNight.bedtime ?? trackedNight.trackedDate)
                  .add(const Duration(minutes: 12)),
              sourceUrl: trackedNight.localRecordingPath,
            ),
          ];

    final recommendedTracks = tracks
        .take(3)
        .map(
          (track) => RecommendedTrackData(
            id: track.id,
            title: track.title,
            subtitle: track.displaySubtitle,
          ),
        )
        .toList();

    return trackedNight.copyWith(
      status: 'analyzed',
      qualityScore: qualityScore,
      summaryCards: <InsightSummaryCardData>[
        InsightSummaryCardData(
          key: 'quality',
          eyebrow: 'SLEEP QUALITY',
          title: qualityScore >= 85 ? 'Nailed it!' : 'A restorative night',
          subtitle: "Swipe left to see last night's highlights",
          metric: '$qualityScore',
        ),
        InsightSummaryCardData(
          key: 'total_sleep',
          eyebrow: '${_formatInsightHours(durationMinutes)} OUT OF ${_formatInsightHours(goalMinutes)}',
          title: 'Total Sleep Time',
          subtitle: 'Another night, another win. You are building steadier sleep habits.',
          metric: _formatInsightHours(durationMinutes),
        ),
        InsightSummaryCardData(
          key: 'movement',
          eyebrow: 'QUIET NIGHT',
          title: recordings.isEmpty ? 'Movement / Noises' : 'Some sound detected',
          subtitle: recordings.isEmpty
              ? 'Your environment stayed mostly calm while you slept.'
              : 'A few sleep sounds were detected while you rested.',
          metric: '${recordings.length}',
        ),
      ],
      sleepPhases: SleepPhaseInsightData(
        timeline: timeline,
        totals: totals,
        focusKey: 'light',
        focusTitle: 'Light',
        focusBody: 'Light sleep made up the biggest part of the night, keeping a steady recovery rhythm.',
        keyInsights: 'Your night stayed close to your goal, with a balanced spread across sleep phases.',
      ),
      soundDetections: soundDetections,
      recordings: recordings,
      recommendedTracks: recommendedTracks,
      isLocalOnly: true,
    );
  }

  String get smartAlarmRangeLabel {
    final end = _timeOfDayToDateTime(wakeAlarmTime);
    final start = end.subtract(Duration(minutes: smartAlarmWindowMinutes));
    return '${_formatWakeLabel(start)} - ${_formatWakeLabel(end)}';
  }

  DateTime _timeOfDayToDateTime(TimeOfDay value) {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day, value.hour, value.minute);
  }

  String _formatWakeLabel(DateTime value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final period = value.hour >= 12 ? 'PM' : 'AM';
    return '$hour:$minute $period';
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

  bool isFavoriteTrack(SleepTrack track) {
    final ref = '${track.id ?? track.title}';
    if (localFavoriteRefs.contains(ref)) {
      return true;
    }
    for (final item in savedCloudItems) {
      if (item.itemType == 'favorites' && item.itemRef == ref) {
        return true;
      }
    }
    return false;
  }

  Future<void> toggleFavoriteTrack(SleepTrack track) async {
    final ref = '${track.id ?? track.title}';
    final subtitle = track.displaySubtitle;
    if (isFavoriteTrack(track)) {
      localFavoriteRefs.remove(ref);
      if (isAuthenticated) {
        final existing = savedCloudItems
            .where((item) => item.itemType == 'favorites' && item.itemRef == ref)
            .toList();
        for (final item in existing) {
          try {
            await _api.deleteSavedItem(item.id);
          } catch (_) {
            apiConnected = false;
          }
        }
        await refreshCloudSavedItems();
      }
      await _logEvent('favorite_remove');
      await _persistLocalState();
      notifyListeners();
      return;
    }

    localFavoriteRefs.add(ref);
    await _logEvent('favorite_add');
    if (isAuthenticated) {
      await upsertSavedItem(
        itemType: 'favorites',
        itemRef: ref,
        title: track.title,
        subtitle: subtitle,
        meta: <String, dynamic>{
          'track_id': track.id,
          'track_subtitle': track.subtitle,
        },
        refreshAfter: false,
      );
      await refreshCloudSavedItems();
    }
    await _persistLocalState();
    notifyListeners();
  }

  bool isDownloadedTrack(SleepTrack track) {
    final ref = '${track.id ?? track.title}';
    if (localDownloadRefs.contains(ref)) {
      return true;
    }
    for (final item in savedCloudItems) {
      if (item.itemType == 'downloads' && item.itemRef == ref) {
        return true;
      }
    }
    return false;
  }

  Future<void> saveDownloadTrack(SleepTrack track) async {
    final ref = '${track.id ?? track.title}';
    localDownloadRefs.add(ref);
    if (isAuthenticated) {
      await upsertSavedItem(
        itemType: 'downloads',
        itemRef: ref,
        title: track.title,
        subtitle: track.displaySubtitle,
        refreshAfter: false,
      );
      await refreshCloudSavedItems();
    }
    await _logEvent('download_save');
    await _persistLocalState();
    notifyListeners();
  }

  Future<void> clearDownloads() async {
    localDownloadRefs.clear();
    if (isAuthenticated) {
      final toDelete = savedCloudItems
          .where((item) => item.itemType == 'downloads')
          .map((item) => item.id)
          .toList();
      for (final id in toDelete) {
        try {
          await _api.deleteSavedItem(id);
        } catch (_) {
          // keep best effort deletion
        }
      }
      await refreshCloudSavedItems();
    }
    await _persistLocalState();
    notifyListeners();
  }

  Future<void> playRelativeTrack(int delta) async {
    if (tracks.isEmpty) {
      return;
    }
    final current = selectedTrack;
    final currentIndex = current == null ? 0 : max(0, tracks.indexWhere((t) => (t.id ?? t.title) == (current.id ?? current.title)));
    final nextIndex = (currentIndex + delta) % tracks.length;
    final normalizedIndex = nextIndex < 0 ? nextIndex + tracks.length : nextIndex;
    await playTrack(tracks[normalizedIndex]);
    await _logEvent(delta > 0 ? 'skip_next' : 'skip_previous');
  }

  bool settingToggleValue(String key, {bool fallback = false}) {
    return settingsToggles[key] ?? fallback;
  }

  Future<void> setSettingToggle(String key, bool value) async {
    settingsToggles[key] = value;
    await _persistLocalState();
    notifyListeners();
  }

  Future<void> logUiAction(String eventType) async {
    await _logEvent(eventType);
  }

  void setSleepNowMixerEnabled(bool enabled) {
    enableMixerInSleepNow = enabled;
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setSelectedSleepGoal(String goal) {
    selectedSleepGoal = goal;
    unawaited(_persistLocalState());
    unawaited(fetchHomeFeed());
    notifyListeners();
  }

  List<SavedContentItem> cloudSavedByType(String itemType) {
    final filtered = savedCloudItems
        .where((item) => item.itemType == itemType)
        .toList();
    filtered.sort((a, b) {
      final aPlayed = a.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bPlayed = b.lastPlayedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final byPlayed = bPlayed.compareTo(aPlayed);
      if (byPlayed != 0) {
        return byPlayed;
      }
      final aUpdated = a.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bUpdated = b.updatedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bUpdated.compareTo(aUpdated);
    });
    return filtered;
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

  void setWakeAlarmEnabled(bool enabled) {
    wakeAlarmEnabled = enabled;
    lastError = enabled
        ? 'Wake-up alarm set for ${_formatTimeOfDay(wakeAlarmTime)}.'
        : 'Wake-up alarm disabled.';
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setWakeAlarmTime(TimeOfDay value) {
    wakeAlarmTime = value;
    wakeAlarmEnabled = true;
    lastError = 'Wake-up alarm updated to ${_formatTimeOfDay(value)}.';
    unawaited(_persistLocalState());
    notifyListeners();
  }

  void setAppLanguage(String code) {
    appLanguage = code;
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
      final latestInsights = isAuthenticated
          ? await _api.fetchInsightsForUser()
          : await _api.fetchInsights(deviceId: deviceId);
      insights = latestInsights;
      _mergeTrackedNights(latestInsights.nights);
      _selectDefaultInsightNight();
      apiConnected = true;
      lastError = null;
    } catch (_) {
      insights = _buildLocalInsights();
      apiConnected = false;
      lastError = 'Insights are currently local.';
    }
    notifyListeners();
  }

  TrackedSleepNight? get selectedInsightsNight {
    if (trackedNights.isEmpty) {
      return null;
    }

    if (selectedInsightNightId != null) {
      for (final night in trackedNights) {
        if (night.nightId == selectedInsightNightId) {
          return night;
        }
      }
    }

    return trackedNights.first;
  }

  List<DateTime> get insightAvailableDates {
    final values = <DateTime>{};
    for (final date in insights.availableDates) {
      values.add(DateTime(date.year, date.month, date.day));
    }
    for (final night in trackedNights) {
      values.add(DateTime(night.trackedDate.year, night.trackedDate.month, night.trackedDate.day));
    }
    final sorted = values.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  void setInsightsTabIndex(int index) {
    insightsTabIndex = index.clamp(0, 2);
    notifyListeners();
  }

  void setInsightsCalendarMonth(DateTime value) {
    insightsCalendarMonth = DateTime(value.year, value.month);
    notifyListeners();
  }

  void selectInsightNightById(String nightId) {
    selectedInsightNightId = nightId;
    notifyListeners();
  }

  void selectInsightNightByDate(DateTime date) {
    final normalized = DateTime(date.year, date.month, date.day);
    for (final night in trackedNights) {
      final trackedDate = DateTime(
        night.trackedDate.year,
        night.trackedDate.month,
        night.trackedDate.day,
      );
      if (trackedDate == normalized) {
        selectedInsightNightId = night.nightId;
        insightsCalendarMonth = DateTime(date.year, date.month);
        notifyListeners();
        return;
      }
    }
  }

  SleepInsights _buildLocalInsights() {
    final completedNights = trackedNights
        .where((night) => night.timeAsleepMinutes > 0)
        .toList();
    final recentWindowStart = DateTime.now().subtract(const Duration(days: 7));
    final recentDates = <String>{};
    for (final night in completedNights) {
      if (!night.trackedDate.isBefore(recentWindowStart)) {
        recentDates.add(night.trackedDate.toIso8601String().split('T').first);
      }
    }
    final localUsage = recentDates.length;
    final localConsistency = min(100, (localUsage / 7 * 100).round());
    final localAvg = completedNights.isEmpty
        ? (sessions.isEmpty
            ? 0
            : sessions.map((s) => s.durationMinutes).reduce((a, b) => a + b) ~/ sessions.length)
        : completedNights.map((night) => night.timeAsleepMinutes).reduce((a, b) => a + b) ~/
            completedNights.length;
    return SleepInsights(
      usageFrequencyLast7Days: localUsage,
      consistencyScore: localConsistency,
      averageDurationMinutes: localAvg,
      nights: List<TrackedSleepNight>.unmodifiable(trackedNights),
      availableDates: insightAvailableDates,
    );
  }

  void _mergeTrackedNights(List<TrackedSleepNight> remoteNights) {
    final preservedLocal = trackedNights
        .where((night) => night.isLocalOnly || night.isActive)
        .toList();
    trackedNights
      ..clear()
      ..addAll(remoteNights);
    for (final localNight in preservedLocal) {
      final exists = trackedNights.any((night) => night.nightId == localNight.nightId);
      if (!exists) {
        trackedNights.add(localNight);
      }
    }
    trackedNights.sort((a, b) => b.trackedDate.compareTo(a.trackedDate));
  }

  void _upsertTrackedNight(TrackedSleepNight night) {
    trackedNights.removeWhere((item) => item.nightId == night.nightId);
    trackedNights.add(night);
    trackedNights.sort((a, b) {
      final dateCompare = b.trackedDate.compareTo(a.trackedDate);
      if (dateCompare != 0) {
        return dateCompare;
      }
      return (b.bedtime ?? DateTime.fromMillisecondsSinceEpoch(0))
          .compareTo(a.bedtime ?? DateTime.fromMillisecondsSinceEpoch(0));
    });
    _selectDefaultInsightNight();
  }

  void _selectDefaultInsightNight() {
    if (trackedNights.isEmpty) {
      selectedInsightNightId = null;
      return;
    }
    if (selectedInsightNightId == null ||
        trackedNights.every((night) => night.nightId != selectedInsightNightId)) {
      selectedInsightNightId = trackedNights.first.nightId;
    }
    final selected = selectedInsightsNight;
    if (selected != null) {
      insightsCalendarMonth = DateTime(selected.trackedDate.year, selected.trackedDate.month);
    }
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
    wakeAlarmEnabled = prefs.getBool('wake_alarm_enabled') ?? false;
    final wakeHour = prefs.getInt('wake_alarm_hour') ?? wakeAlarmTime.hour;
    final wakeMinute = prefs.getInt('wake_alarm_minute') ?? wakeAlarmTime.minute;
    wakeAlarmTime = TimeOfDay(hour: wakeHour, minute: wakeMinute);
    smartAlarmWindowMinutes = prefs.getInt('smart_alarm_window_minutes') ?? smartAlarmWindowMinutes;
    sleepGoalHours = prefs.getInt('sleep_goal_hours') ?? sleepGoalHours;
    microphonePermissionGranted =
        prefs.getBool('microphone_permission_granted') ?? microphonePermissionGranted;
    hasUsedSleepRecorder = prefs.getBool('has_used_sleep_recorder') ?? hasUsedSleepRecorder;
    sleepRecorderActive = prefs.getBool('sleep_recorder_active') ?? sleepRecorderActive;
    final sleepRecorderStartedAtRaw = prefs.getString('sleep_recorder_started_at');
    if (sleepRecorderStartedAtRaw != null && sleepRecorderStartedAtRaw.isNotEmpty) {
      sleepRecorderStartedAt = DateTime.tryParse(sleepRecorderStartedAtRaw);
    }
    _activeTrackedNightId = prefs.getString('active_tracked_night_id');
    _activeRecordingPath = prefs.getString('active_recording_path');
    selectedInsightNightId = prefs.getString('selected_insight_night_id');
    insightsTabIndex = (prefs.getInt('insights_tab_index') ?? insightsTabIndex).clamp(0, 2);
    final insightsMonthRaw = prefs.getString('insights_calendar_month');
    if (insightsMonthRaw != null && insightsMonthRaw.isNotEmpty) {
      final parsedMonth = DateTime.tryParse(insightsMonthRaw);
      if (parsedMonth != null) {
        insightsCalendarMonth = DateTime(parsedMonth.year, parsedMonth.month);
      }
    }
    appLanguage = prefs.getString('app_language') ?? appLanguage;
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
    localFavoriteRefs
      ..clear()
      ..addAll(prefs.getStringList('local_favorites') ?? const <String>[]);
    localDownloadRefs
      ..clear()
      ..addAll(prefs.getStringList('local_downloads') ?? const <String>[]);
    final localMixesRaw = prefs.getString('local_mix_items');
    if (localMixesRaw != null && localMixesRaw.isNotEmpty) {
      final decoded = jsonDecode(localMixesRaw);
      if (decoded is List) {
        localMixItems
          ..clear()
          ..addAll(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(SavedContentItem.fromJson),
          );
      }
    }
    final activeMixKindsRaw = prefs.getStringList('active_mix_kinds') ?? const <String>[];
    _activeMixKinds
      ..clear()
      ..addAll(activeMixKindsRaw);
    final trackedNightsRaw = prefs.getString('tracked_sleep_nights');
    if (trackedNightsRaw != null && trackedNightsRaw.isNotEmpty) {
      final decoded = jsonDecode(trackedNightsRaw);
      if (decoded is List) {
        trackedNights
          ..clear()
          ..addAll(
            decoded
                .whereType<Map<String, dynamic>>()
                .map(TrackedSleepNight.fromJson),
          );
      }
    }

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
    final settingsRaw = prefs.getString('settings_toggles');
    if (settingsRaw != null && settingsRaw.isNotEmpty) {
      final decoded = jsonDecode(settingsRaw);
      if (decoded is Map<String, dynamic>) {
        settingsToggles
          ..clear()
          ..addAll(decoded.map((key, value) => MapEntry(key, value == true || value == 1)));
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
    await prefs.setBool('wake_alarm_enabled', wakeAlarmEnabled);
    await prefs.setInt('wake_alarm_hour', wakeAlarmTime.hour);
    await prefs.setInt('wake_alarm_minute', wakeAlarmTime.minute);
    await prefs.setInt('smart_alarm_window_minutes', smartAlarmWindowMinutes);
    await prefs.setInt('sleep_goal_hours', sleepGoalHours);
    await prefs.setBool('microphone_permission_granted', microphonePermissionGranted);
    await prefs.setBool('has_used_sleep_recorder', hasUsedSleepRecorder);
    await prefs.setBool('sleep_recorder_active', sleepRecorderActive);
    if (sleepRecorderStartedAt != null) {
      await prefs.setString('sleep_recorder_started_at', sleepRecorderStartedAt!.toIso8601String());
    } else {
      await prefs.remove('sleep_recorder_started_at');
    }
    if (_activeTrackedNightId != null) {
      await prefs.setString('active_tracked_night_id', _activeTrackedNightId!);
    } else {
      await prefs.remove('active_tracked_night_id');
    }
    if (_activeRecordingPath != null) {
      await prefs.setString('active_recording_path', _activeRecordingPath!);
    } else {
      await prefs.remove('active_recording_path');
    }
    if (selectedInsightNightId != null) {
      await prefs.setString('selected_insight_night_id', selectedInsightNightId!);
    } else {
      await prefs.remove('selected_insight_night_id');
    }
    await prefs.setInt('insights_tab_index', insightsTabIndex);
    await prefs.setString(
      'insights_calendar_month',
      DateTime(insightsCalendarMonth.year, insightsCalendarMonth.month).toIso8601String(),
    );
    await prefs.setString('app_language', appLanguage);
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
    await prefs.setStringList('local_favorites', localFavoriteRefs.toList());
    await prefs.setStringList('local_downloads', localDownloadRefs.toList());
    await prefs.setString(
      'local_mix_items',
      jsonEncode(localMixItems.map((item) => item.toJson()).toList()),
    );
    await prefs.setStringList('active_mix_kinds', _activeMixKinds.toList());
    await prefs.setString(
      'tracked_sleep_nights',
      jsonEncode(trackedNights.map((night) => night.toJson()).toList()),
    );
    await prefs.setString('settings_toggles', jsonEncode(settingsToggles));
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
    await refreshSavedPersonalization();
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
    await refreshSavedPersonalization();
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

  Future<void> refreshSavedPersonalization() async {
    if (!isAuthenticated) {
      return;
    }
    await refreshCloudSavedItems();
    await fetchHomeFeed();
  }

  Future<void> upsertSavedItem({
    required String itemType,
    required String itemRef,
    required String title,
    String? subtitle,
    Map<String, dynamic> meta = const <String, dynamic>{},
    DateTime? lastPlayedAt,
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
    try {
      await _api.upsertSavedItem(
        itemType: itemType,
        itemRef: itemRef,
        title: title,
        subtitle: subtitle,
        meta: meta,
        ifUnmodifiedSince: guardTime,
        lastPlayedAt: lastPlayedAt,
      );
    } on ApiRequestException catch (error) {
      if (error.statusCode != 409) {
        rethrow;
      }
      final current = error.responseBody['current'];
      if (current is Map<String, dynamic>) {
        final serverItem = SavedContentItem.fromJson(current);
        savedCloudItems.removeWhere(
          (item) => item.itemType == serverItem.itemType && item.itemRef == serverItem.itemRef,
        );
        savedCloudItems.add(serverItem);
      }
      await _api.upsertSavedItem(
        itemType: itemType,
        itemRef: itemRef,
        title: title,
        subtitle: subtitle,
        meta: meta,
        lastPlayedAt: lastPlayedAt,
      );
    }
    if (refreshAfter) {
      await refreshCloudSavedItems();
    }
  }

  Future<void> updateProfile({
    String? name,
    String? headline,
    String? phone,
    String? bio,
  }) async {
    if (!isAuthenticated) {
      return;
    }
    final updatedUser = await _api.updateMe(
      name: name,
      headline: headline,
      phone: phone,
      bio: bio,
    );
    currentUser = updatedUser;
    await _persistLocalState();
    await fetchHomeFeed();
    notifyListeners();
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

  Future<void> deleteSavedItem(int savedItemId) async {
    await _api.deleteSavedItem(savedItemId);
  }

  Future<LegalContentDocument> fetchLegalDocument(String slug) {
    return _api.fetchLegalDocument(slug);
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
    _sleepTimerEndsAt = DateTime.now().add(Duration(minutes: sleepTimerMinutes));
    _sleepTimerTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_sleepTimerEndsAt == null) {
        return;
      }
      if (DateTime.now().isAfter(_sleepTimerEndsAt!)) {
        return;
      }
      notifyListeners();
    });
    notifyListeners();
    _sleepTimer = Timer(Duration(minutes: sleepTimerMinutes), () async {
      await _logEvent('timer_completed');
      await stopPlayback();
    });
  }

  Future<void> _cancelSleepTimer() async {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepTimerTicker?.cancel();
    _sleepTimerTicker = null;
    _sleepTimerEndsAt = null;
    notifyListeners();
  }

  bool get hasActiveSleepTimer {
    return remainingSleepTimer > Duration.zero;
  }

  Duration get remainingSleepTimer {
    final endsAt = _sleepTimerEndsAt;
    if (endsAt == null) {
      return Duration.zero;
    }
    final remaining = endsAt.difference(DateTime.now());
    if (remaining.isNegative) {
      return Duration.zero;
    }
    return remaining;
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
    _sleepTimerTicker?.cancel();
    _bedtimeTicker?.cancel();
    _positionSubscription?.cancel();
    _playerStateSubscription?.cancel();
    _recorder?.dispose();
    _player.dispose();
    for (final player in _mixerPlayers.values) {
      player.dispose();
    }
    super.dispose();
  }

  AudioRecorder get _audioRecorder => _recorder ??= AudioRecorder();
}

class SleepTrack {
  const SleepTrack({
    this.id,
    required this.title,
    this.subtitle,
    required this.category,
    required this.talking,
    this.streamUrl,
    this.durationSeconds = 1800,
  });

  final int? id;
  final String title;
  final String? subtitle;
  final String category;
  final bool talking;
  final String? streamUrl;
  final int durationSeconds;

  String get displaySubtitle {
    final value = subtitle?.trim() ?? '';
    if (value.isNotEmpty) {
      return value;
    }
    return '$category • ${talking ? 'Talking' : 'No talking'}';
  }

  TrackPlayerKind get playerKind {
    final value = (subtitle ?? '').trim().toLowerCase();
    if (value == 'meditation') {
      return TrackPlayerKind.meditation;
    }
    if (value == 'sound') {
      return TrackPlayerKind.sound;
    }
    if (value == 'music') {
      return TrackPlayerKind.music;
    }
    if (value == 'brainwave') {
      return TrackPlayerKind.brainwave;
    }
    return TrackPlayerKind.other;
  }

  factory SleepTrack.fromJson(Map<String, dynamic> json) {
    return SleepTrack(
      id: json['id'] is int ? json['id'] as int : int.tryParse('${json['id']}'),
      title: '${json['title'] ?? 'Untitled'}',
      subtitle: json['subtitle']?.toString(),
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

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  int index = 0;
  bool showProfile = false;
  bool showSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed || !widget.state.isAuthenticated) {
      return;
    }
    unawaited(widget.state.refreshSavedPersonalization());
    unawaited(widget.state.hydrateProfile());
  }

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
        onAction: _handleContentAction,
      ),
      PlayerPage(state: widget.state),
      RoutinePage(state: widget.state, onAction: _handleContentAction),
      InsightsPage(state: widget.state, onAction: _handleContentAction),
      SavedPage(state: widget.state, onAction: _handleContentAction),
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
                                onAction: _handleContentAction,
                              )
                            : ProfilePage(
                                state: widget.state,
                                onBack: () => setState(() => showProfile = false),
                                onOpenSettings: () => setState(() => showSettings = true),
                                onAction: _handleContentAction,
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
                        builder: (_) => _playerPageForTrack(state: widget.state, track: track),
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
                  subtitle: Text(
                    widget.state.selectedTrack!.displaySubtitle,
                    style: const TextStyle(color: Colors.white70),
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

  Future<void> _handleContentAction(
    BuildContext context,
    HomeItemContent item,
    String source,
  ) async {
    final action = (item.meta['action']?.toString() ?? '').toLowerCase();
    final target = item.meta['target']?.toString();
    final targetTab = _nullableInt(item.meta['target_tab']);
    final deepLink = item.meta['deep_link']?.toString();
    final analyticsEvent = item.meta['analytics_event']?.toString();
    if (analyticsEvent != null && analyticsEvent.isNotEmpty) {
      await widget.state.logUiAction(analyticsEvent);
    }

    final isTrackMySleepAction = source == 'insight_snore' ||
        (item.ctaLabel ?? '').trim().toLowerCase() == 'track my sleep';
    if (isTrackMySleepAction) {
      final track = widget.state.selectedTrack ?? _findTrackByText(widget.state, item.title);
      if (!context.mounted) {
        return;
      }
      await openSleepRecorderFlow(
        context,
        widget.state,
        preferredTrack: track,
        entryPoint: source,
      );
      return;
    }

    if (action == 'navigate_tab' && targetTab != null) {
      setState(() {
        index = targetTab.clamp(0, 4);
        showProfile = false;
        showSettings = false;
      });
      return;
    }
    if (action == 'open_profile') {
      setState(() => showProfile = true);
      return;
    }
    if (action == 'open_settings') {
      setState(() {
        showProfile = true;
        showSettings = true;
      });
      return;
    }
    if (action == 'start_sleep_now') {
      await widget.state.startSleepNow(entryPoint: source);
      return;
    }
    if (action == 'play_track') {
      final term = (deepLink?.isNotEmpty == true) ? deepLink! : item.title;
      final track = _findTrackByText(widget.state, term);
      if (track != null) {
        await widget.state.playTrack(track);
      }
      return;
    }
    if (action == 'open_legal' && target != null && target.isNotEmpty) {
      if (!context.mounted) {
        return;
      }
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LegalContentPage(
            state: widget.state,
            slug: target,
            title: item.title,
          ),
        ),
      );
      return;
    }
    if (action == 'rate_app') {
      final uri = Uri.parse('https://play.google.com/store/apps/details?id=com.sleepwell.sleepwell');
      await launchUrl(uri, mode: LaunchMode.externalApplication);
      return;
    }
    if (action == 'refresh_insights') {
      setState(() {
        index = 3;
        showProfile = false;
        showSettings = false;
      });
      await widget.state.refreshInsights();
      return;
    }
    if (action == 'open_auth') {
      setState(() => showProfile = true);
      return;
    }
    if (action == 'clear_downloads') {
      await widget.state.clearDownloads();
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Downloads cleared.')),
      );
      return;
    }
    if (action == 'change_language') {
      if (!context.mounted) {
        return;
      }
      final selected = await showModalBottomSheet<String>(
        context: context,
        backgroundColor: const Color(0xFF121A2D),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) {
          return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: const Text('English'),
                  trailing: widget.state.appLanguage == 'en'
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop('en'),
                ),
                ListTile(
                  title: const Text('Bahasa Indonesia'),
                  trailing: widget.state.appLanguage == 'id'
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop('id'),
                ),
              ],
            ),
          );
        },
      );
      if (selected != null && selected.isNotEmpty) {
        widget.state.setAppLanguage(selected);
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              selected == 'id'
                  ? 'Bahasa Indonesia selected.'
                  : 'English selected.',
            ),
          ),
        );
      }
      return;
    }
    if (action == 'heart') {
      final track = _findTrackByText(widget.state, item.title);
      if (track != null) {
        await widget.state.toggleFavoriteTrack(track);
      }
      return;
    }
    if (action == 'arrow' || action == 'more' || action == 'pill' || action == 'badge') {
      final title = item.title.toLowerCase();
      if (title.contains('alarm') || title.contains('bedtime') || title.contains('sleep goal')) {
        setState(() {
          index = 2;
          showProfile = false;
          showSettings = false;
        });
        return;
      }
      final track = _findTrackByText(widget.state, item.title);
      if (track != null) {
        await widget.state.playTrack(track);
      }
      return;
    }

    if (targetTab != null) {
      setState(() {
        index = targetTab.clamp(0, 4);
        showProfile = false;
        showSettings = false;
      });
      return;
    }
  }

  SleepTrack? _findTrackByText(SleepWellState state, String text) {
    final needle = text.toLowerCase();
    for (final track in state.tracks) {
      if (track.title.toLowerCase().contains(needle) || needle.contains(track.title.toLowerCase())) {
        return track;
      }
    }
    return state.tracks.isEmpty ? null : state.tracks.first;
  }
}

class HomeHubPage extends StatefulWidget {
  const HomeHubPage({
    super.key,
    required this.state,
    required this.onOpenProfile,
    required this.onNavigateTab,
    required this.onAction,
  });
  final SleepWellState state;
  final VoidCallback onOpenProfile;
  final ValueChanged<int> onNavigateTab;
  final ContentActionHandler onAction;

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
                  style: TextStyle(fontSize: 34, fontWeight: FontWeight.w800),
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
              onTap: () => widget.onAction(
                context,
                const HomeItemContent(
                  title: 'Recorder',
                  meta: <String, dynamic>{
                    'action': 'navigate_tab',
                    'target_tab': 3,
                    'analytics_event': 'open_insights_recorder',
                  },
                ),
                'home_recorder_chip',
              ),
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
          const Text('My mixes', style: TextStyle(fontSize: 27, fontWeight: FontWeight.w700)),
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
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Current mixer levels saved as preset.')),
                    );
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
                    if (!context.mounted) {
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(state.isMixerPlaying ? 'Mixer started.' : 'Mixer stopped.'),
                      ),
                    );
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
                onTap: () => widget.onAction(context, item, 'home_explore_grid'),
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
              onPressed: () => widget.onAction(
                context,
                _withDefaultPlayAction(
                  sleepRecorder.items.first,
                  source: 'home_sleep_recorder',
                ),
                'home_sleep_recorder',
              ),
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
                      onPressed: () => widget.onAction(context, item, 'home_colored_noise'),
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
                onTap: () => widget.onAction(context, item, 'home_top_rated'),
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
                onTap: () => widget.onAction(context, item, 'home_try_something'),
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
              onTap: () => widget.onAction(
                context,
                const HomeItemContent(
                  title: 'Discover',
                  meta: <String, dynamic>{
                    'action': 'navigate_tab',
                    'target_tab': 1,
                    'analytics_event': 'open_sounds_discover',
                  },
                ),
                'home_discover_banner',
              ),
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
    return Text(text, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.2));
  }

  Widget _heroCard({required HomeItemContent item}) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
                onTap: () => widget.onAction(context, item, 'home_curated_playlist'),
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
              onPressed: () => widget.onAction(
                context,
                _withDefaultPlayAction(item, source: 'home_hero_cta'),
                'home_hero_cta',
              ),
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
                onTap: () => widget.onAction(context, item, 'home_sleep_hypnosis'),
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
          subtitle: Text(track.displaySubtitle),
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
  const SavedPage({super.key, required this.state, required this.onAction});
  final SleepWellState state;
  final ContentActionHandler onAction;

  @override
  State<SavedPage> createState() => _SavedPageState();
}

class _SavedPageState extends State<SavedPage> {
  int _tabIndex = 0;

  static const List<String> _tabs = <String>['Favorites', 'Recently Played', 'Playlists'];

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        final state = widget.state;
        final savedMixes = state.savedMixItems;
        final favorites = state.sectionByKey('saved_favorites');
        final recentlyPlayed = state.sectionByKey('saved_recently_played');
        final playlists = state.sectionByKey('saved_playlists');
        final findLove = state.sectionByKey('saved_find_love');
        final suggestions = state.sectionByKey('saved_suggestions');
        final cloudFavorites = state.cloudSavedByType('favorites');
        final cloudRecent = state.cloudSavedByType('recently_played');
        final cloudPlaylists = state.cloudSavedByType('playlists');
        final cloudItemsByTab = switch (_tabIndex) {
          0 => cloudFavorites,
          1 => cloudRecent,
          _ => cloudPlaylists,
        };
        final cloudSectionTitle = switch (_tabIndex) {
          0 => 'Favorites',
          1 => 'Recently Played',
          _ => 'Playlists',
        };
        final activeSection = cloudItemsByTab.isNotEmpty
            ? HomeSectionContent(
                sectionKey: 'saved_cloud_${cloudSectionTitle.toLowerCase().replaceAll(' ', '_')}',
                title: cloudSectionTitle,
                subtitle: null,
                sectionType: 'horizontal',
                items: cloudItemsByTab.map(_savedItemAsHomeItem).toList(),
              )
            : switch (_tabIndex) {
                0 => _localFavoritesSection(state) ?? favorites,
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
                if (_tabIndex == 0 && savedMixes.isNotEmpty) ...[
                  Text(
                    'Mixes (${savedMixes.length})',
                    style: const TextStyle(fontSize: _UiBaseline.savedSectionTitleSize, fontWeight: FontWeight.w800, letterSpacing: -0.5),
                  ),
                  const SizedBox(height: 8),
                  ...savedMixes.map((item) => _mixLibraryRow(item: item, state: state)),
                  const SizedBox(height: 10),
                ],
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
                    state.currentUser?.headline?.trim().isNotEmpty == true
                        ? '${state.currentUser!.headline} picks'
                        : (suggestions.title ?? 'Suggestions for you'),
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
                    itemBuilder: (_, idx) => _suggestionCard(findLove.items[idx]),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _libraryRow({
    required HomeItemContent item,
    required int tabIndex,
    required SleepWellState state,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => widget.onAction(
        context,
        _withDefaultPlayAction(item, source: 'saved_library_row'),
        'saved_library_row',
      ),
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

  HomeItemContent _savedItemAsHomeItem(SavedContentItem item) {
    final itemType = item.itemType.toLowerCase();
    final mergedMeta = <String, dynamic>{
      ...item.meta,
      'source_item_type': itemType,
      'source_item_ref': item.itemRef,
      'updated_at': item.updatedAt?.toIso8601String(),
      if (item.lastPlayedAt != null) 'last_played_at': item.lastPlayedAt!.toIso8601String(),
    };
    if ((mergedMeta['action']?.toString() ?? '').isEmpty) {
      mergedMeta['action'] = itemType == 'playlists' ? 'arrow' : 'more';
    }
    return HomeItemContent(
      title: item.title,
      subtitle: item.subtitle,
      meta: mergedMeta,
    );
  }

  HomeSectionContent? _localFavoritesSection(SleepWellState state) {
    if (state.localFavoriteRefs.isEmpty) {
      return null;
    }
    final items = <HomeItemContent>[];
    for (final ref in state.localFavoriteRefs) {
      for (final track in state.tracks) {
        final trackRef = '${track.id ?? track.title}';
        if (trackRef != ref) {
          continue;
        }
        items.add(
          HomeItemContent(
            title: track.title,
            subtitle: track.displaySubtitle,
            meta: <String, dynamic>{
              'action': 'more',
              'source_item_type': 'favorites_local',
              'source_item_ref': ref,
            },
          ),
        );
        break;
      }
    }
    if (items.isEmpty) {
      return null;
    }
    return HomeSectionContent(
      sectionKey: 'saved_local_favorites',
      title: 'Favorites',
      subtitle: null,
      sectionType: 'horizontal',
      items: items,
    );
  }

  Widget _trailingAction({required HomeItemContent item, required int tabIndex}) {
    final action = (item.meta['action']?.toString() ?? '').toLowerCase();
    final sourceType = (item.meta['source_item_type']?.toString() ?? '').toLowerCase();
    if (sourceType == 'playlists') {
      return const Icon(Icons.chevron_right_rounded, size: 24);
    }
    if (sourceType == 'favorites' ||
        sourceType == 'favorites_local' ||
        sourceType == 'mix') {
      return const Icon(Icons.favorite_border_rounded, size: 22);
    }
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

  Widget _mixLibraryRow({
    required SavedContentItem item,
    required SleepWellState state,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () async {
        await state.playSavedMix(item);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: _UiBaseline.savedThumbSize,
                height: _UiBaseline.savedThumbSize,
                child: _savedArtworkThumb(item.title, compact: true),
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
            IconButton(
              icon: const Icon(Icons.more_horiz_rounded),
              onPressed: () async {
                final shouldDelete = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => Dialog(
                    backgroundColor: const Color(0xFF242657),
                    insetPadding: const EdgeInsets.symmetric(horizontal: 22),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Align(
                            alignment: Alignment.topRight,
                            child: IconButton(
                              onPressed: () => Navigator.of(dialogContext).pop(false),
                              icon: const Icon(Icons.close_rounded),
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Delete',
                            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 14),
                          const Text(
                            'Are you sure you want to delete this mix?',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 16, color: Colors.white70),
                          ),
                          const SizedBox(height: 26),
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              style: FilledButton.styleFrom(
                                backgroundColor: const Color(0xFFE55A54),
                                foregroundColor: Colors.white,
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                                minimumSize: const Size.fromHeight(56),
                              ),
                              onPressed: () => Navigator.of(dialogContext).pop(true),
                              child: const Text('Delete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
                if (shouldDelete == true) {
                  await state.deleteMixByRef(item.itemRef);
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _suggestionCard(HomeItemContent item) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: () => widget.onAction(
        context,
        _withDefaultPlayAction(item, source: 'saved_suggestion_card'),
        'saved_suggestion_card',
      ),
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
    required this.onAction,
  });

  final SleepWellState state;
  final VoidCallback onBack;
  final VoidCallback onOpenSettings;
  final ContentActionHandler onAction;

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
                    context: context,
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
                        context: context,
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
                        context: context,
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
    required BuildContext context,
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
        InkWell(
          onTap: () => onAction(context, item, 'profile_row'),
          borderRadius: BorderRadius.circular(14),
          child: Padding(
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
    required this.onAction,
  });

  final SleepWellState state;
  final VoidCallback onBack;
  final ContentActionHandler onAction;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
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
    final current = widget.state.settingToggleValue(
      item.title,
      fallback: item.meta['enabled'] == true,
    );

    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: isToggle ? null : () => widget.onAction(context, item, 'settings_row'),
      child: Padding(
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
                onChanged: (value) => widget.state.setSettingToggle(item.title, value),
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

class LegalContentPage extends StatefulWidget {
  const LegalContentPage({
    super.key,
    required this.state,
    required this.slug,
    required this.title,
  });

  final SleepWellState state;
  final String slug;
  final String title;

  @override
  State<LegalContentPage> createState() => _LegalContentPageState();
}

class _LegalContentPageState extends State<LegalContentPage> {
  late Future<LegalContentDocument> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.state.fetchLegalDocument(widget.slug);
  }

  void _retry() {
    setState(() {
      _future = widget.state.fetchLegalDocument(widget.slug);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B1020),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1020),
        title: Text(widget.title),
      ),
      body: FutureBuilder<LegalContentDocument>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError || !snapshot.hasData) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'Unable to load this page right now.',
                      style: TextStyle(fontSize: 16, color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: _retry,
                      child: const Text('Try again'),
                    ),
                  ],
                ),
              ),
            );
          }

          final doc = snapshot.data!;
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 18, 16, 22),
            children: [
              Text(
                doc.title.isEmpty ? widget.title : doc.title,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if ((doc.updatedAt ?? '').isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  'Last updated: ${doc.updatedAt}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12.5),
                ),
              ],
              const SizedBox(height: 16),
              ...doc.blocks.map((block) {
                return Container(
                  margin: const EdgeInsets.only(bottom: 12),
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        block.heading,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        block.body,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 14.5,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}

class RoutinePage extends StatefulWidget {
  const RoutinePage({super.key, required this.state, required this.onAction});
  final SleepWellState state;
  final ContentActionHandler onAction;

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
                    time: _formatTimeOfDay(state.wakeAlarmTime),
                    enabled: state.wakeAlarmEnabled,
                    onTap: () async {
                      final picked = await showTimePicker(
                        context: context,
                        initialTime: state.wakeAlarmTime,
                      );
                      if (picked != null) {
                        state.setWakeAlarmTime(picked);
                        state.setWakeAlarmEnabled(true);
                      }
                    },
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
                      onPressed: () => widget.onAction(
                        context,
                        recommendation.items.first,
                        'routine_recommendation',
                      ),
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
      onTap: () => _openTrack(item),
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
                childAspectRatio: isSoundsGrid ? 0.56 : 0.78,
              ),
              itemCount: items.length,
              itemBuilder: (_, i) {
                final item = items[i];
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => _openTrack(item),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      AspectRatio(
                        aspectRatio: 1,
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
                      SizedBox(
                        height: 42,
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: const TextStyle(height: 1.15),
                        ),
                      ),
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
                      onTap: () => _openTrack(item),
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
                    onTap: () => _openTrack(item),
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

  Future<void> _openTrack(HomeItemContent item) async {
    SleepTrack? selected;
    final query = item.title.toLowerCase();
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
    final subtitleType = (item.subtitle ?? '').trim().toLowerCase();
    TrackPlayerKind kind;
    switch (subtitleType) {
      case 'meditation':
        kind = TrackPlayerKind.meditation;
        break;
      case 'sound':
        kind = TrackPlayerKind.sound;
        break;
      case 'music':
        kind = TrackPlayerKind.music;
        break;
      case 'brainwave':
        kind = TrackPlayerKind.brainwave;
        break;
      default:
        kind = selected.playerKind;
        break;
    }
    if (kind == TrackPlayerKind.meditation) {
      if (!context.mounted) {
        return;
      }
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => TrackDetailPage(state: widget.state, track: selected!),
        ),
      );
      return;
    }

    await widget.state.playTrack(selected);
  }
}

class LayeredPlayerPage extends StatefulWidget {
  const LayeredPlayerPage({
    super.key,
    required this.state,
    required this.seedTrack,
    required this.initialKind,
  });

  final SleepWellState state;
  final SleepTrack seedTrack;
  final TrackPlayerKind initialKind;

  @override
  State<LayeredPlayerPage> createState() => _LayeredPlayerPageState();
}

class _LayeredPlayerPageState extends State<LayeredPlayerPage> {
  SleepTrack? _soundTrack;
  SleepTrack? _musicTrack;
  SleepTrack? _brainwaveTrack;
  TrackPlayerKind _activeKind = TrackPlayerKind.sound;

  double _soundVolume = 0.58;
  double _musicVolume = 0.58;
  double _brainwaveVolume = 0.58;

  @override
  void initState() {
    super.initState();
    final kind = widget.initialKind;
    _activeKind = (kind == TrackPlayerKind.other || kind == TrackPlayerKind.meditation)
        ? TrackPlayerKind.sound
        : kind;
    _setSelectedTrack(_activeKind, widget.seedTrack);
  }

  @override
  Widget build(BuildContext context) {
    final activeTrack = _selectedTrack(_activeKind);
    final orderedKinds = <TrackPlayerKind>[
      _activeKind,
      ...TrackPlayerKind.values.where(
        (kind) =>
            kind != _activeKind &&
            kind != TrackPlayerKind.meditation &&
            kind != TrackPlayerKind.other,
      ),
    ];

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1D244B), Color(0xFF151A38), Color(0xFF11162C)],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              activeTrack?.title ?? 'Layered Player',
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                            ),
                            Text(
                              activeTrack == null ? '0 item' : '1 item',
                              style: const TextStyle(color: Colors.white60),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.ios_share_rounded),
                      ),
                      IconButton(
                        onPressed: () => _openTrackPicker(_activeKind),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      ...orderedKinds.map((kind) => _layerSection(kind)),
                      const SizedBox(height: 6),
                      Center(
                        child: OutlinedButton(
                          onPressed: _clearAllLayers,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                          ),
                          child: const Text('Clear all'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4A3D83), Color(0xFF6A4FA8)],
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _footerAction(
                            icon: Icons.timer_outlined,
                            label: widget.state.hasActiveSleepTimer
                                ? _formatTimerCountdown(widget.state.remainingSleepTimer)
                                : 'Set Timer',
                            onTap: _setTimer,
                            active: widget.state.hasActiveSleepTimer,
                          ),
                          _footerAction(
                            icon: widget.state.isPlaying ? Icons.pause : Icons.play_arrow,
                            label: '',
                            emphasized: true,
                            onTap: () async => widget.state.togglePlayPause(),
                          ),
                          _footerAction(
                            icon: Icons.favorite_border_rounded,
                            label: 'Save Mix',
                            onTap: () async => widget.state.saveCurrentMixPreset(),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.white.withValues(alpha: 0.2),
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () async => widget.state.startSleepNow(entryPoint: 'layered_player_track_sleep'),
                          child: const Text('Track My Sleep'),
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

  Widget _layerSection(TrackPlayerKind kind) {
    final selected = _selectedTrack(kind);
    final counter = selected == null ? 0 : 1;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.02),
          border: Border.all(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${_kindLabel(kind)} ($counter/${_kindMax(kind)})',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 2),
              Text(
                _kindDescription(kind),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 10),
              if (selected != null)
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () {
                          setState(() => _setSelectedTrack(kind, null));
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(selected.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Slider(
                            value: _volumeFor(kind),
                            onChanged: (value) => setState(() => _setVolumeFor(kind, value)),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else
                const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                  ),
                  onPressed: () => _openTrackPicker(kind),
                  child: Text('Add ${_kindLabel(kind)}'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _footerAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool emphasized = false,
    bool active = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: emphasized ? 32 : 22,
            backgroundColor: active
                ? Colors.white
                : Colors.white.withValues(alpha: emphasized ? 0.95 : 0.2),
            child: Icon(
              icon,
              color: emphasized || active ? Colors.black : Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }

  Future<void> _openTrackPicker(TrackPlayerKind kind) async {
    final options = _filteredTracksFor(kind);
    if (options.isEmpty) {
      return;
    }
    final selected = await showModalBottomSheet<SleepTrack>(
      context: context,
      backgroundColor: const Color(0xFF151C34),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: ListView.separated(
            itemCount: options.length,
            separatorBuilder: (_, __) => const Divider(height: 1, color: Colors.white12),
            itemBuilder: (_, idx) {
              final track = options[idx];
              return ListTile(
                title: Text(track.title),
                subtitle: Text(track.displaySubtitle),
                onTap: () => Navigator.of(sheetContext).pop(track),
              );
            },
          ),
        );
      },
    );

    if (selected == null) {
      return;
    }
    await widget.state.playTrack(selected);
    await widget.state.logUiAction('layer_add_${kind.name}');
    if (!mounted) {
      return;
    }
    setState(() {
      _activeKind = kind;
      _setSelectedTrack(kind, selected);
    });
  }

  Future<void> _setTimer() async {
    final options = <int>[15, 30, 45, 60];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF151C34),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map(
                  (minutes) => ListTile(
                    title: Text('Sleep timer: $minutes min'),
                    onTap: () => Navigator.of(sheetContext).pop(minutes),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
    if (selected != null) {
      await widget.state.setSleepTimerMinutes(selected);
    }
  }

  void _clearAllLayers() {
    setState(() {
      _soundTrack = null;
      _musicTrack = null;
      _brainwaveTrack = null;
    });
  }

  List<SleepTrack> _filteredTracksFor(TrackPlayerKind kind) {
    final all = widget.state.tracks;
    final byKind = all.where((track) => track.playerKind == kind).toList();
    if (byKind.isNotEmpty) {
      return byKind;
    }

    switch (kind) {
      case TrackPlayerKind.sound:
        return all.where((track) => !track.talking).toList();
      case TrackPlayerKind.music:
        return all
            .where((track) =>
                track.title.toLowerCase().contains('music') ||
                track.title.toLowerCase().contains('sonata'))
            .toList();
      case TrackPlayerKind.brainwave:
        return all
            .where((track) =>
                track.title.toLowerCase().contains('brainwave') ||
                (track.subtitle ?? '').toLowerCase().contains('brainwave'))
            .toList();
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        return all;
    }
  }

  SleepTrack? _selectedTrack(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return _soundTrack;
      case TrackPlayerKind.music:
        return _musicTrack;
      case TrackPlayerKind.brainwave:
        return _brainwaveTrack;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        return null;
    }
  }

  void _setSelectedTrack(TrackPlayerKind kind, SleepTrack? track) {
    switch (kind) {
      case TrackPlayerKind.sound:
        _soundTrack = track;
        break;
      case TrackPlayerKind.music:
        _musicTrack = track;
        break;
      case TrackPlayerKind.brainwave:
        _brainwaveTrack = track;
        break;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        break;
    }
  }

  int _kindMax(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 15;
      case TrackPlayerKind.music:
      case TrackPlayerKind.brainwave:
        return 1;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        return 1;
    }
  }

  String _kindLabel(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Sounds';
      case TrackPlayerKind.music:
        return 'Music';
      case TrackPlayerKind.brainwave:
        return 'Brainwaves';
      case TrackPlayerKind.meditation:
        return 'Meditation';
      case TrackPlayerKind.other:
        return 'Tracks';
    }
  }

  String _kindDescription(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Include relaxing sounds.';
      case TrackPlayerKind.music:
        return 'Enhance your mix with music.';
      case TrackPlayerKind.brainwave:
        return 'Elevate your mix.';
      case TrackPlayerKind.meditation:
        return 'Guided session layer.';
      case TrackPlayerKind.other:
        return 'General track layer.';
    }
  }

  double _volumeFor(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return _soundVolume;
      case TrackPlayerKind.music:
        return _musicVolume;
      case TrackPlayerKind.brainwave:
        return _brainwaveVolume;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        return 0.58;
    }
  }

  void _setVolumeFor(TrackPlayerKind kind, double value) {
    switch (kind) {
      case TrackPlayerKind.sound:
        _soundVolume = value;
        break;
      case TrackPlayerKind.music:
        _musicVolume = value;
        break;
      case TrackPlayerKind.brainwave:
        _brainwaveVolume = value;
        break;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        break;
    }
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
  @override
  Widget build(BuildContext context) {
    final isFavorite = widget.state.isFavoriteTrack(widget.track);
    final isDownloaded = widget.state.isDownloadedTrack(widget.track);
    final closeAfter = widget.state.settingToggleValue('Close app after ending', fallback: true);
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
                    IconButton(
                      icon: Icon(
                        isDownloaded ? Icons.download_done_rounded : Icons.cloud_download_outlined,
                      ),
                      onPressed: () async {
                        await widget.state.saveDownloadTrack(widget.track);
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Saved to downloads')),
                        );
                      },
                    ),
                    const SizedBox(width: 18),
                    IconButton(
                      icon: Icon(isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded),
                      onPressed: () async {
                        await widget.state.toggleFavoriteTrack(widget.track);
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              widget.state.isFavoriteTrack(widget.track)
                                  ? 'Added to favorites'
                                  : 'Removed from favorites',
                            ),
                          ),
                        );
                      },
                    ),
                    const SizedBox(width: 18),
                    IconButton(
                      icon: const Icon(Icons.add),
                      onPressed: () async {
                        await widget.state.upsertSavedItem(
                          itemType: 'playlists',
                          itemRef: '${widget.track.id ?? widget.track.title}',
                          title: widget.track.title,
                          subtitle: 'Saved from track detail',
                          refreshAfter: false,
                        );
                        if (!context.mounted) {
                          return;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(content: Text('Added to playlists')),
                        );
                      },
                    ),
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
                              await widget.state.logUiAction('track_detail_play');
                              await widget.state.playTrack(widget.track);
                              if (!context.mounted) {
                                return;
                              }
                              Navigator.of(context).pop();
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
                _toggleRow(
                  icon: Icons.repeat,
                  title: 'Repeat meditation',
                  value: widget.state.loop,
                  onChanged: (v) async => widget.state.setLoopEnabled(v),
                ),
                _toggleRow(
                  icon: Icons.exit_to_app_outlined,
                  title: 'Close app after ending',
                  value: closeAfter,
                  onChanged: (v) async => widget.state.setSettingToggle('Close app after ending', v),
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
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final isFavorite = state.isFavoriteTrack(track);
        final activeKind = track.playerKind == TrackPlayerKind.other
            ? TrackPlayerKind.meditation
            : track.playerKind;
        if (activeKind == TrackPlayerKind.sound ||
            activeKind == TrackPlayerKind.brainwave) {
          return _buildAmbientStylePlayer(context, activeKind);
        }
        final currentSectionLabel = _primarySectionLabel(activeKind);
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final artworkHeight = (constraints.maxHeight * 0.28).clamp(160.0, 220.0).toDouble();
                    return ListView(
                      physics: const BouncingScrollPhysics(),
                      padding: const EdgeInsets.only(bottom: 12),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                          child: Row(
                            children: [
                              IconButton(
                                onPressed: () => _minimizePlayer(context),
                                icon: const Icon(Icons.keyboard_arrow_down),
                              ),
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
                          height: artworkHeight,
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
                                  onChangeEnd: (_) async {
                                    await state.logUiAction('seek_track_position');
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
                                  IconButton(
                                    icon: const Icon(Icons.skip_previous_rounded, size: 34),
                                    onPressed: () async {
                                      await state.playRelativeTrack(-1);
                                      if (!context.mounted) {
                                        return;
                                      }
                                      Navigator.of(context).pushReplacement(
                                        MaterialPageRoute<void>(
                                          builder: (_) => _playerPageForTrack(
                                            state: state,
                                            track: state.selectedTrack ?? track,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
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
                                  IconButton(
                                    icon: const Icon(Icons.skip_next_rounded, size: 34),
                                    onPressed: () async {
                                      await state.playRelativeTrack(1);
                                      if (!context.mounted) {
                                        return;
                                      }
                                      Navigator.of(context).pushReplacement(
                                        MaterialPageRoute<void>(
                                          builder: (_) => _playerPageForTrack(
                                            state: state,
                                            track: state.selectedTrack ?? track,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                  IconButton(
                                    icon: Icon(
                                      isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                                      size: 30,
                                    ),
                                    onPressed: () async {
                                      await state.toggleFavoriteTrack(track);
                                      if (!context.mounted) {
                                        return;
                                      }
                                      ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(
                                          content: Text(
                                            state.isFavoriteTrack(track)
                                                ? 'Added to favorites'
                                                : 'Removed from favorites',
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),
                              Center(
                                child: _buildTrackSleepButton(
                                  context,
                                  track: track,
                                  activeKind: activeKind,
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
                              Text(currentSectionLabel, style: const TextStyle(fontWeight: FontWeight.w700)),
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                leading: const CircleAvatar(child: Icon(Icons.volume_up_rounded)),
                                title: Text(track.title),
                                subtitle: Slider(
                                  value: state.mainPlayerVolume,
                                  onChanged: (v) async => state.setMainPlayerVolume(v),
                                ),
                              ),
                              if (activeKind != TrackPlayerKind.sound) ...[
                                const Divider(color: Colors.white12),
                                _adjustRow(
                                  title: 'Sounds',
                                  subtitle: 'Include relaxing sounds.',
                                  button: 'Add Sounds',
                                  onPressed: () async {
                                    state.enableMixKind(TrackPlayerKind.sound);
                                    if (!state.isMixerPlaying) {
                                      await state.toggleMixerPlayback();
                                    }
                                    await state.logUiAction('add_sounds_now_playing');
                                    if (!context.mounted) {
                                      return;
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Relaxing sounds added to mix.')),
                                    );
                                  },
                                ),
                              ],
                              if (activeKind != TrackPlayerKind.music) ...[
                                const Divider(color: Colors.white12),
                                _adjustRow(
                                  title: 'Music',
                                  subtitle: 'Enhance your mix with music.',
                                  button: 'Add Music',
                                  onPressed: () async {
                                    state.enableMixKind(TrackPlayerKind.music);
                                    final boosted = min(1.0, state.mainPlayerVolume + 0.1);
                                    await state.setMainPlayerVolume(boosted);
                                    await state.logUiAction('add_music_now_playing');
                                    if (!context.mounted) {
                                      return;
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Music level boosted.')),
                                    );
                                  },
                                ),
                              ],
                              if (activeKind != TrackPlayerKind.brainwave) ...[
                                const Divider(color: Colors.white12),
                                _adjustRow(
                                  title: 'Brainwaves',
                                  subtitle: 'Elevate your mix.',
                                  button: 'Add Brainwave',
                                  onPressed: () async {
                                    state.enableMixKind(TrackPlayerKind.brainwave);
                                    await state.logUiAction('add_brainwave_now_playing');
                                    if (!context.mounted) {
                                      return;
                                    }
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      const SnackBar(content: Text('Brainwave added to mix.')),
                                    );
                                  },
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildAmbientStylePlayer(BuildContext context, TrackPlayerKind activeKind) {
    final selectedTrack = state.selectedTrack ?? track;
    final isSavedMix = state.isMixSaved(track: selectedTrack, activeKind: activeKind);
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF201E3D), Color(0xFF171A34), Color(0xFF12162E)],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      IconButton(
                            onPressed: () => _minimizePlayer(context),
                            icon: const Icon(Icons.keyboard_arrow_down_rounded),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Column(
                          children: [
                            Text(
                              selectedTrack.title,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
                            ),
                            const Text(
                              '1 item',
                              style: TextStyle(color: Colors.white60),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () {},
                        icon: const Icon(Icons.ios_share_rounded),
                      ),
                      IconButton(
                        onPressed: () async {
                          await state.logUiAction('ambient_player_add_pressed');
                          if (!context.mounted) {
                            return;
                          }
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Use the section buttons below to add more layers.')),
                          );
                        },
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                ),
                const Divider(color: Colors.white12, height: 1),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                    physics: const BouncingScrollPhysics(),
                    children: [
                      _ambientSection(
                        context,
                        sectionKind: TrackPlayerKind.sound,
                        activeKind: activeKind,
                      ),
                      _ambientSection(
                        context,
                        sectionKind: TrackPlayerKind.music,
                        activeKind: activeKind,
                      ),
                      _ambientSection(
                        context,
                        sectionKind: TrackPlayerKind.brainwave,
                        activeKind: activeKind,
                      ),
                      const SizedBox(height: 6),
                      Center(
                        child: OutlinedButton(
                          onPressed: () async {
                            await state.stopPlayback();
                            if (!context.mounted) {
                              return;
                            }
                            Navigator.of(context).pop();
                          },
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: Colors.white24),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                          ),
                          child: const Text('Clear all'),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                ),
                Container(
                  margin: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                  padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF4A3D83), Color(0xFF6A4FA8)],
                    ),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceAround,
                        children: [
                          _ambientFooterAction(
                            icon: Icons.timer_outlined,
                            label: state.hasActiveSleepTimer
                                ? _formatTimerCountdown(state.remainingSleepTimer)
                                : 'Set Timer',
                            onTap: () => _showSleepTimerSheet(context),
                            active: state.hasActiveSleepTimer,
                          ),
                          _ambientFooterAction(
                            icon: state.isPlaying ? Icons.pause : Icons.play_arrow,
                            label: '',
                            emphasized: true,
                            onTap: () async => state.togglePlayPause(),
                          ),
                          _ambientFooterAction(
                            icon: isSavedMix ? Icons.favorite_rounded : Icons.favorite_border_rounded,
                            label: isSavedMix ? 'Saved Mix' : 'Save Mix',
                            active: isSavedMix,
                            onTap: () async => _handleSaveMixPressed(
                              context,
                              track: selectedTrack,
                              activeKind: activeKind,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      SizedBox(
                        width: double.infinity,
                        child: _buildTrackSleepButton(
                          context,
                          track: selectedTrack,
                          activeKind: activeKind,
                          compactGradient: true,
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

  String _primarySectionLabel(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Sounds';
      case TrackPlayerKind.music:
        return 'Music';
      case TrackPlayerKind.brainwave:
        return 'Brainwaves';
      case TrackPlayerKind.meditation:
        return 'Meditation';
      case TrackPlayerKind.other:
        return 'Track';
    }
  }

  Widget _ambientSection(
    BuildContext context, {
    required TrackPlayerKind sectionKind,
    required TrackPlayerKind activeKind,
  }) {
    final selected = sectionKind == activeKind ? (state.selectedTrack ?? track) : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Colors.white.withValues(alpha: 0.02),
          border: Border.all(color: Colors.white12),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${_ambientSectionLabel(sectionKind)} (${selected == null ? 0 : 1}/${_ambientSectionLimit(sectionKind)})',
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (sectionKind == TrackPlayerKind.sound)
                    FilledButton.tonal(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.1),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                      onPressed: () async {
                        await state.logUiAction('ambient_player_all_sounds');
                      },
                      child: const Text('ALL'),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                _ambientSectionDescription(sectionKind),
                style: const TextStyle(color: Colors.white70),
              ),
              const SizedBox(height: 10),
              if (selected != null)
                Row(
                  children: [
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      child: IconButton(
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close_rounded, size: 16),
                        onPressed: () async {
                          await state.stopPlayback();
                          if (!context.mounted) {
                            return;
                          }
                          Navigator.of(context).pop();
                        },
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(selected.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                          Slider(
                            value: state.mainPlayerVolume,
                            onChanged: (value) async => state.setMainPlayerVolume(value),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    CircleAvatar(
                      radius: 18,
                      backgroundColor: Colors.white.withValues(alpha: 0.12),
                      child: const Icon(Icons.bolt_rounded, size: 18),
                    ),
                  ],
                )
              else
                Align(
                  alignment: Alignment.centerRight,
                  child: FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      backgroundColor: Colors.white.withValues(alpha: 0.14),
                      foregroundColor: Colors.white,
                    ),
                    onPressed: () async {
                      await _handleAmbientAddAction(context, sectionKind);
                    },
                    child: Text(_ambientSectionButton(sectionKind)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _ambientFooterAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool emphasized = false,
    bool active = false,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(999),
      onTap: onTap,
      child: Column(
        children: [
          CircleAvatar(
            radius: emphasized ? 32 : 22,
            backgroundColor: active
                ? const Color(0xFFFF7BA5).withValues(alpha: 0.92)
                : Colors.white.withValues(alpha: emphasized ? 0.95 : 0.2),
            child: Icon(
              icon,
              color: emphasized ? Colors.black : (active ? Colors.white : Colors.white),
            ),
          ),
          if (label.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showSleepTimerSheet(BuildContext context) async {
    final options = <int>[15, 30, 45, 60];
    final selected = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF151C34),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: options
                .map(
                  (minutes) => ListTile(
                    title: Text('Sleep timer: $minutes min'),
                    onTap: () => Navigator.of(sheetContext).pop(minutes),
                  ),
                )
                .toList(),
          ),
        );
      },
    );
    if (selected != null) {
      await state.setSleepTimerMinutes(selected);
    }
  }

  void _minimizePlayer(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
  }

  Future<void> _handleSaveMixPressed(
    BuildContext context, {
    required SleepTrack track,
    required TrackPlayerKind activeKind,
  }) async {
    if (state.isMixSaved(track: track, activeKind: activeKind)) {
      final shouldDelete = await _showDeleteMixDialog(context);
      if (shouldDelete == true) {
        await state.deleteMix(track: track, activeKind: activeKind);
      }
      return;
    }

    final name = await _showSaveMixDialog(context);
    if (name == null || name.trim().isEmpty) {
      return;
    }
    await state.saveNamedMix(
      name: name.trim(),
      track: track,
      activeKind: activeKind,
    );
    if (!context.mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('"${name.trim()}" saved to your library.')),
    );
  }

  Widget _buildTrackSleepButton(
    BuildContext context, {
    required SleepTrack track,
    required TrackPlayerKind activeKind,
    bool compactGradient = false,
  }) {
    if (state.sleepRecorderActive) {
      return Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(999),
          gradient: const LinearGradient(
            colors: [Color(0xFFFFA24E), Color(0xFF6B32FF)],
          ),
        ),
        child: FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            foregroundColor: Colors.white,
            minimumSize: Size(double.infinity, compactGradient ? 52 : 50),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
          ),
          onPressed: () async {
            await openSleepRecorderFlow(
              context,
              state,
              preferredTrack: track,
              entryPoint: 'open_sleep_recorder_button',
            );
          },
          child: const Text(
            'Open Sleep Recorder',
            style: TextStyle(fontWeight: FontWeight.w700),
          ),
        ),
      );
    }

    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        minimumSize: const Size(220, 50),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      ),
      onPressed: () async {
        await state.logUiAction('track_my_sleep_now_playing');
        if (!context.mounted) {
          return;
        }
        await openSleepRecorderFlow(
          context,
          state,
          preferredTrack: track,
          entryPoint: 'track_my_sleep_now_playing',
        );
      },
      child: const Text('Track My Sleep'),
    );
  }

  Future<String?> _showSaveMixDialog(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF242657),
          insetPadding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              24,
              24,
              24,
              24 + MediaQuery.of(dialogContext).viewInsets.bottom,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'Name your mix',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 30),
                TextField(
                  controller: controller,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  decoration: const InputDecoration(
                    hintText: 'Enter mix name',
                    enabledBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white54),
                    ),
                    focusedBorder: UnderlineInputBorder(
                      borderSide: BorderSide(color: Colors.white),
                    ),
                  ),
                  onSubmitted: (value) => Navigator.of(dialogContext).pop(value),
                ),
                const SizedBox(height: 28),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(controller.text),
                    child: const Text('Save', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<bool?> _showDeleteMixDialog(BuildContext context) {
    return showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF242657),
          insetPadding: const EdgeInsets.symmetric(horizontal: 18),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 26),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: IconButton(
                    onPressed: () => Navigator.of(dialogContext).pop(false),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Delete',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Are you sure you want to delete this mix?',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 16, color: Colors.white70),
                ),
                const SizedBox(height: 26),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE55A54),
                      foregroundColor: Colors.white,
                      minimumSize: const Size.fromHeight(56),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    onPressed: () => Navigator.of(dialogContext).pop(true),
                    child: const Text('Delete', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleAmbientAddAction(BuildContext context, TrackPlayerKind sectionKind) async {
    switch (sectionKind) {
      case TrackPlayerKind.sound:
        state.enableMixKind(TrackPlayerKind.sound);
        if (!state.isMixerPlaying) {
          await state.toggleMixerPlayback();
        }
        await state.logUiAction('ambient_add_sounds');
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Relaxing sounds added to mix.')),
        );
        break;
      case TrackPlayerKind.music:
        state.enableMixKind(TrackPlayerKind.music);
        final boosted = min(1.0, state.mainPlayerVolume + 0.1);
        await state.setMainPlayerVolume(boosted);
        await state.logUiAction('ambient_add_music');
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Music level boosted.')),
        );
        break;
      case TrackPlayerKind.brainwave:
        state.enableMixKind(TrackPlayerKind.brainwave);
        await state.logUiAction('ambient_add_brainwave');
        if (!context.mounted) {
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Brainwave added to mix.')),
        );
        break;
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        break;
    }
  }

  String _ambientSectionLabel(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Sounds';
      case TrackPlayerKind.music:
        return 'Music';
      case TrackPlayerKind.brainwave:
        return 'Brainwaves';
      case TrackPlayerKind.meditation:
        return 'Meditation';
      case TrackPlayerKind.other:
        return 'Track';
    }
  }

  String _ambientSectionDescription(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Include relaxing sounds.';
      case TrackPlayerKind.music:
        return 'Enhance your mix with music.';
      case TrackPlayerKind.brainwave:
        return 'Elevate your mix.';
      case TrackPlayerKind.meditation:
        return 'Keep your guided session focused.';
      case TrackPlayerKind.other:
        return 'Adjust your playback.';
    }
  }

  String _ambientSectionButton(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 'Add Sounds';
      case TrackPlayerKind.music:
        return 'Add Music';
      case TrackPlayerKind.brainwave:
        return 'Add Brainwave';
      case TrackPlayerKind.meditation:
        return 'Add Meditation';
      case TrackPlayerKind.other:
        return 'Add Track';
    }
  }

  int _ambientSectionLimit(TrackPlayerKind kind) {
    switch (kind) {
      case TrackPlayerKind.sound:
        return 15;
      case TrackPlayerKind.music:
      case TrackPlayerKind.brainwave:
      case TrackPlayerKind.meditation:
      case TrackPlayerKind.other:
        return 1;
    }
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

class SleepRecorderFlowPage extends StatefulWidget {
  const SleepRecorderFlowPage({
    super.key,
    required this.state,
    required this.entryPoint,
    this.preferredTrack,
  });

  final SleepWellState state;
  final SleepTrack? preferredTrack;
  final String entryPoint;

  @override
  State<SleepRecorderFlowPage> createState() => _SleepRecorderFlowPageState();
}

class _SleepRecorderFlowPageState extends State<SleepRecorderFlowPage> {
  late int _step;
  late double _goalHours;
  int _activeRecorderTabIndex = 0;
  Timer? _clockTicker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _goalHours = widget.state.sleepGoalHours.toDouble();
    _step = widget.state.hasUsedSleepRecorder ? 5 : 0;
    _clockTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) {
        return;
      }
      setState(() => _now = DateTime.now());
    });
    if (_step == 5) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await widget.state.startSleepRecorder(preferredTrack: widget.preferredTrack);
      });
    }
  }

  @override
  void dispose() {
    _clockTicker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.state,
      builder: (context, _) {
        return Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Container(
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF2B2668), Color(0xFF19143B), Color(0xFF0F1121)],
                    ),
                  ),
                ),
              ),
              SafeArea(child: _buildCurrentStep(context)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCurrentStep(BuildContext context) {
    switch (_step) {
      case 0:
        return _welcomeStep(context);
      case 1:
        return _goalStep(context);
      case 2:
        return _smartAlarmIntroStep(context);
      case 3:
        return _smartAlarmConfigStep(context);
      case 4:
        return _readyForBedStep(context);
      case 5:
      default:
        return _activeRecorderStep(context);
    }
  }

  Widget _welcomeStep(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        children: [
          const Spacer(),
          const CircleAvatar(
            radius: 42,
            backgroundColor: Colors.white12,
            child: Text('🌙', style: TextStyle(fontSize: 34)),
          ),
          const SizedBox(height: 24),
          const Text(
            'Welcome to your\nSleep Recorder',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 34),
          _recorderBenefit(icon: Icons.bed_rounded, title: 'Unlock more insights', body: 'Record your sleep length, debt, and patterns'),
          const SizedBox(height: 22),
          _recorderBenefit(icon: Icons.mic_rounded, title: 'Record sleep sounds', body: 'Observe the noises that happen in your sleep'),
          const SizedBox(height: 22),
          _recorderBenefit(icon: Icons.alarm_on_rounded, title: 'Wake up refreshed', body: 'Start your day with a personalized soothing alarm'),
          const Spacer(),
          _primaryRecorderButton(
            label: 'Continue',
            onPressed: () async {
              final granted = await _showMicrophonePrompt(context);
              widget.state.setMicrophonePermissionGranted(granted);
              if (!mounted) {
                return;
              }
              setState(() => _step = 1);
            },
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Not Now', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _goalStep(BuildContext context) {
    final hours = _goalHours.round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        children: [
          const Spacer(),
          const Text(
            'How many hours do you aim\nfor each night?',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 28),
          const Text(
            'Getting 7 to 9 hours of sleep can\nimprove your health, mood and overall\nwell-being.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 42),
          Text('$hours h', style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w800)),
          Slider(
            value: _goalHours,
            min: 6,
            max: 10,
            divisions: 4,
            onChanged: (value) => setState(() => _goalHours = value),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('6', style: TextStyle(color: Colors.white54)),
              Text('7', style: TextStyle(color: Colors.white54)),
              Text('8', style: TextStyle(color: Colors.white54)),
              Text('9', style: TextStyle(color: Colors.white54)),
              Text('10', style: TextStyle(color: Colors.white54)),
            ],
          ),
          const Spacer(),
          _primaryRecorderButton(
            label: 'Save Sleep Goal',
            onPressed: () {
              widget.state.setSleepGoalHours(hours);
              setState(() => _step = 2);
            },
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => setState(() => _step = 2),
            child: const Text('Not Now', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _smartAlarmIntroStep(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        children: [
          const Spacer(),
          Container(
            height: 220,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(colors: [Color(0xFF6927D1), Color(0xFF30145C)]),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.alarm_on_rounded, size: 84, color: Colors.white),
          ),
          const SizedBox(height: 30),
          const Text(
            'Then, set your smart alarm',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          const Text(
            'Smart alarm uses sleep tracking for\noptimal wake up, providing a natural and\nrefreshing start to your day.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const Spacer(),
          _primaryRecorderButton(
            label: 'Set Smart Alarm',
            onPressed: () => setState(() => _step = 3),
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => setState(() => _step = 4),
            child: const Text('Not Now', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _smartAlarmConfigStep(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconButton(
            onPressed: () => setState(() => _step = 2),
            icon: const Icon(Icons.arrow_back_ios_new_rounded),
          ),
          const SizedBox(height: 18),
          const Text(
            'Wake up gently at',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.alarm_rounded, color: Colors.white70),
              const SizedBox(width: 8),
              Text(widget.state.smartAlarmRangeLabel, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 28),
          InkWell(
            borderRadius: BorderRadius.circular(22),
            onTap: () async {
              final picked = await showTimePicker(
                context: context,
                initialTime: widget.state.wakeAlarmTime,
              );
              if (picked != null) {
                widget.state.setWakeAlarmTime(picked);
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: Colors.white12),
                color: Colors.white.withValues(alpha: 0.03),
              ),
              child: Center(
                child: Text(
                  _formatAlarmWheel(widget.state.wakeAlarmTime),
                  style: const TextStyle(fontSize: 38, fontWeight: FontWeight.w800),
                ),
              ),
            ),
          ),
          const SizedBox(height: 22),
          InkWell(
            borderRadius: BorderRadius.circular(18),
            onTap: () async {
              final selected = await _showSmartAlarmWindowPicker(context);
              if (selected != null) {
                widget.state.setSmartAlarmWindowMinutes(selected);
              }
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                color: Colors.white.withValues(alpha: 0.05),
              ),
              child: Row(
                children: [
                  const Text('Wake up window', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${widget.state.smartAlarmWindowMinutes} minutes', style: const TextStyle(color: Colors.white70)),
                  const SizedBox(width: 8),
                  const Icon(Icons.chevron_right_rounded),
                ],
              ),
            ),
          ),
          const Spacer(),
          _primaryRecorderButton(
            label: 'Confirm The Alarm',
            onPressed: () async {
              widget.state.setWakeAlarmEnabled(true);
              if (!mounted) {
                return;
              }
              setState(() => _step = 4);
            },
          ),
          const SizedBox(height: 14),
          Center(
            child: TextButton(
              onPressed: () => setState(() => _step = 4),
              child: const Text('Not Now', style: TextStyle(color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _readyForBedStep(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
      child: Column(
        children: [
          Expanded(
            child: Container(
              width: double.infinity,
              decoration: const BoxDecoration(
                borderRadius: BorderRadius.vertical(bottom: Radius.circular(28)),
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF7B6C68), Color(0xFF312B49)],
                ),
              ),
              alignment: Alignment.topCenter,
              padding: const EdgeInsets.only(top: 70),
              child: const Text('🦋', style: TextStyle(fontSize: 36)),
            ),
          ),
          const SizedBox(height: 28),
          const Text(
            'Ready for bed?',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 16),
          const Text(
            'Plug your phone in and place it close to\nyour bed.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70, fontSize: 16),
          ),
          const SizedBox(height: 28),
          _primaryRecorderButton(
            label: 'Continue',
            onPressed: () async {
              await widget.state.startSleepRecorder(preferredTrack: widget.preferredTrack);
              if (!mounted) {
                return;
              }
              setState(() => _step = 5);
            },
          ),
          const SizedBox(height: 14),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text("Don't Remind Me", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _activeRecorderStep(BuildContext context) {
    final state = widget.state;
    final track = state.selectedTrack ?? widget.preferredTrack;
    final timerText = state.hasActiveSleepTimer ? _formatTimerCountdown(state.remainingSleepTimer) : null;
    final tabLabels = <String>['Recent', 'Favorites', 'Recommended', 'Mixes'];
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 18, 14, 18),
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 18),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              color: Colors.black.withValues(alpha: 0.18),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    ),
                    const Spacer(),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('🌙', style: TextStyle(fontSize: 48)),
                const SizedBox(height: 10),
                Text(
                  _formatRecorderClock(_now),
                  style: const TextStyle(fontSize: 48, fontWeight: FontWeight.w800),
                ),
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(999),
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  child: Text(
                    '⏰ ${state.smartAlarmRangeLabel}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: List<Widget>.generate(tabLabels.length, (idx) {
                    final selected = idx == _activeRecorderTabIndex;
                    return Expanded(
                      child: InkWell(
                        onTap: () => setState(() => _activeRecorderTabIndex = idx),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Column(
                            children: [
                              Text(
                                tabLabels[idx],
                                style: TextStyle(
                                  fontWeight: FontWeight.w800,
                                  color: selected ? Colors.white : Colors.white54,
                                ),
                              ),
                              const SizedBox(height: 6),
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 180),
                                height: 3,
                                width: selected ? 34 : 0,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(999),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  height: 176,
                  child: ListView(
                    scrollDirection: Axis.horizontal,
                    physics: const BouncingScrollPhysics(),
                    children: _recorderTabCards(
                      context,
                      state: state,
                      currentTrack: track,
                      timerText: timerText,
                    ),
                  ),
                ),
                const SizedBox(height: 22),
                _primaryRecorderButton(
                  label: 'Stop',
                  onPressed: () async {
                    final navigator = Navigator.of(context);
                    await state.stopSleepRecorder();
                    navigator.pop();
                  },
                ),
                const SizedBox(height: 12),
                const Text('Tracking in progress...', style: TextStyle(color: Colors.white70, fontWeight: FontWeight.w700)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _recorderBenefit({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Row(
      children: [
        CircleAvatar(
          radius: 24,
          backgroundColor: Colors.white.withValues(alpha: 0.08),
          child: Icon(icon),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text(body, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _primaryRecorderButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        style: FilledButton.styleFrom(
          backgroundColor: Colors.white,
          foregroundColor: Colors.black,
          minimumSize: const Size.fromHeight(58),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        ),
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ),
    );
  }

  Widget _recorderCurrentSelectionCard({
    required String title,
    required String subtitle,
    required Duration duration,
    required Duration position,
    required String? timerText,
    required bool isPlaying,
    required VoidCallback onToggle,
    required VoidCallback onFavorite,
  }) {
    final maxMs = max(duration.inMilliseconds, 1);
    final progress = min(position.inMilliseconds / maxMs, 1.0);
    return Container(
      width: 232,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        gradient: const LinearGradient(colors: [Color(0xFF2B5AB8), Color(0xFF1A234A)]),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(subtitle, style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          Row(
            children: [
              Text(_formatDuration(position), style: const TextStyle(fontSize: 12)),
              const Spacer(),
              Text(_formatDuration(duration), style: const TextStyle(fontSize: 12)),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              minHeight: 4,
              value: progress,
              backgroundColor: Colors.white24,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              Column(
                children: [
                  const Icon(Icons.timer_outlined),
                  if (timerText != null) ...[
                    const SizedBox(height: 4),
                    Text(timerText, style: const TextStyle(fontWeight: FontWeight.w700)),
                  ],
                ],
              ),
              IconButton(
                onPressed: onToggle,
                icon: Icon(isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 36),
              ),
              IconButton(
                onPressed: onFavorite,
                icon: const Icon(Icons.favorite_border_rounded, size: 30),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _recorderMiniMixCard({required SavedContentItem item}) {
    return Container(
      width: 156,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(item.title, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 4),
          Text(item.subtitle ?? 'Mix', style: const TextStyle(color: Colors.white70)),
          const Spacer(),
          const Icon(Icons.timer_outlined, color: Colors.white54),
        ],
      ),
    );
  }

  List<Widget> _recorderTabCards(
    BuildContext context, {
    required SleepWellState state,
    required SleepTrack? currentTrack,
    required String? timerText,
  }) {
    switch (_activeRecorderTabIndex) {
      case 0:
        final recentTracks = <SleepTrack>[
          if (currentTrack != null) currentTrack,
          ...state.tracks.where((item) => currentTrack == null || item.title != currentTrack.title).take(3),
        ];
        return [
          if (currentTrack != null)
            _recorderCurrentSelectionCard(
              title: currentTrack.title,
              subtitle: 'Mix',
              duration: state.currentDuration,
              position: state.currentPosition,
              timerText: timerText,
              isPlaying: state.isPlaying,
              onToggle: () async => state.togglePlayPause(),
              onFavorite: () async {
                await state.toggleFavoriteTrack(currentTrack);
              },
            ),
          ...recentTracks.skip(currentTrack == null ? 0 : 1).map(
                (item) => Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: _recorderTrackCard(
                    track: item,
                    subtitle: item.displaySubtitle,
                    onTap: () async => state.playTrack(item),
                  ),
                ),
              ),
        ];
      case 1:
        final favorites = state.tracks.where(state.isFavoriteTrack).toList();
        if (favorites.isEmpty) {
          return <Widget>[_recorderEmptyCard('No favorites yet', 'Favorite a track to see it here.')];
        }
        return favorites.take(4).map((item) {
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _recorderTrackCard(
              track: item,
              subtitle: item.displaySubtitle,
              onTap: () async => state.playTrack(item),
            ),
          );
        }).toList();
      case 2:
        final recommended = state.tracks
            .where((item) => currentTrack == null || item.title != currentTrack.title)
            .take(4)
            .toList();
        return recommended.map((item) {
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: _recorderTrackCard(
              track: item,
              subtitle: item.displaySubtitle,
              onTap: () async => state.playTrack(item),
            ),
          );
        }).toList();
      case 3:
      default:
        final mixes = state.savedMixItems.take(4).toList();
        if (mixes.isEmpty) {
          return <Widget>[_recorderEmptyCard('No mixes yet', 'Save a mix and it will show up here.')];
        }
        return mixes.map((item) {
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: InkWell(
              borderRadius: BorderRadius.circular(18),
              onTap: () async => state.playSavedMix(item),
              child: _recorderMiniMixCard(item: item),
            ),
          );
        }).toList();
    }
  }

  Widget _recorderTrackCard({
    required SleepTrack track,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: 156,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          color: Colors.white.withValues(alpha: 0.05),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const CircleAvatar(
              backgroundColor: Colors.white12,
              child: Icon(Icons.music_note_rounded),
            ),
            const Spacer(),
            Text(
              track.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white70),
            ),
          ],
        ),
      ),
    );
  }

  Widget _recorderEmptyCard(String title, String body) {
    return Container(
      width: 232,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: Colors.white.withValues(alpha: 0.05),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.nights_stay_rounded, size: 30, color: Colors.white70),
          const Spacer(),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          const SizedBox(height: 8),
          Text(body, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Future<bool> _showMicrophonePrompt(BuildContext context) async {
    final granted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        return Dialog(
          backgroundColor: const Color(0xFF22213F),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          child: Padding(
            padding: const EdgeInsets.all(22),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircleAvatar(
                  radius: 28,
                  backgroundColor: Color(0xFFFFA04B),
                  child: Icon(Icons.mic_rounded, color: Colors.white, size: 28),
                ),
                const SizedBox(height: 18),
                const Text(
                  '"SleepWell" would like to access the Microphone.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 10),
                const Text(
                  'Turn on your microphone to learn about your sleep habits and nightly patterns.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.white70),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.of(dialogContext).pop(false),
                        child: const Text("Don't Allow"),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.tonal(
                        onPressed: () => Navigator.of(dialogContext).pop(true),
                        child: const Text('Allow'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    return granted ?? false;
  }

  Future<int?> _showSmartAlarmWindowPicker(BuildContext context) async {
    final options = <int>[0, 15, 30, 45, 60];
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: const Color(0xFF1A1A1A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                const Text(
                  'Select the time frame you\nwant to wake up',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 18),
                ...options.map(
                  (value) => ListTile(
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(18),
                      side: BorderSide(
                        color: widget.state.smartAlarmWindowMinutes == value ? Colors.white70 : Colors.transparent,
                      ),
                    ),
                    leading: const Icon(Icons.alarm_on_rounded),
                    title: Text(value == 0 ? 'None' : '$value minutes'),
                    trailing: widget.state.smartAlarmWindowMinutes == value
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () => Navigator.of(sheetContext).pop(value),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _formatAlarmWheel(TimeOfDay value) {
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final period = value.hour >= 12 ? 'pm' : 'am';
    return '${hour.toString().padLeft(2, '0')} : $minute $period';
  }

  String _formatRecorderClock(DateTime value) {
    final hour = value.hour.toString().padLeft(2, '0');
    final minute = value.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class InsightsPage extends StatefulWidget {
  const InsightsPage({super.key, required this.state, required this.onAction});
  final SleepWellState state;
  final ContentActionHandler onAction;

  @override
  State<InsightsPage> createState() => _InsightsPageState();
}

class _InsightsPageState extends State<InsightsPage> {
  late final PageController _summaryController;
  int _summaryIndex = 0;

  @override
  void initState() {
    super.initState();
    _summaryController = PageController(viewportFraction: 0.74);
  }

  @override
  void dispose() {
    _summaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final night = state.selectedInsightsNight;
        final availableDates = state.insightAvailableDates;
        final isEmpty = night == null;
        final summaryCards = isEmpty
            ? const <InsightSummaryCardData>[]
            : (night.summaryCards.isEmpty ? _fallbackSummaryCards(night) : night.summaryCards);

        if (_summaryIndex >= max(1, summaryCards.length)) {
          _summaryIndex = 0;
        }

        return ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 180),
          children: [
            _headerRow(context, night),
            const SizedBox(height: 14),
            _topDateStrip(availableDates, night),
            const SizedBox(height: 14),
            _segmentedTabs(),
            if (state.sleepRecorderActive) ...[
              const SizedBox(height: 16),
              _surfaceCard(
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Tracking in progress',
                            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'Recorder is active now. Smart alarm: ${state.smartAlarmRangeLabel}',
                            style: const TextStyle(color: Colors.white70),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => widget.onAction(
                        context,
                        const HomeItemContent(title: 'Track my sleep', ctaLabel: 'Track my sleep'),
                        'insight_snore',
                      ),
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                      ),
                      child: const Text('Open'),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            if (isEmpty)
              _emptyInsightsState(context)
            else if (state.insightsTabIndex == 0)
              _buildSummaryTab(night, summaryCards)
            else if (state.insightsTabIndex == 1)
              _buildPhasesTab(night)
            else
              _buildRecordingsTab(context, night),
          ],
        );
      },
    );
  }

  Widget _headerRow(BuildContext context, TrackedSleepNight? night) {
    final date = night?.trackedDate ?? DateTime.now();
    return Row(
      children: [
        Expanded(
          child: Text(
            _formatInsightHeaderDate(date),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
          ),
        ),
        InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _showCalendarSheet(context),
          child: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white12),
              color: Colors.white.withValues(alpha: 0.04),
            ),
            child: const Icon(Icons.calendar_month_outlined),
          ),
        ),
      ],
    );
  }

  Widget _topDateStrip(List<DateTime> dates, TrackedSleepNight? night) {
    if (dates.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 46,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: min(dates.length, 10),
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, index) {
          final date = dates[index];
          final selected = night != null &&
              date.year == night.trackedDate.year &&
              date.month == night.trackedDate.month &&
              date.day == night.trackedDate.day;
          return GestureDetector(
            onTap: () => widget.state.selectInsightNightByDate(date),
            child: Container(
              width: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: selected ? Colors.white : Colors.white.withValues(alpha: 0.05),
                border: Border.all(
                  color: selected ? Colors.white : Colors.white10,
                  width: selected ? 2 : 1,
                ),
              ),
              alignment: Alignment.center,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  color: selected ? Colors.black : Colors.white70,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _segmentedTabs() {
    const tabs = <String>['Summary', 'Sleep Phases', 'Recordings'];
    return Row(
      children: List<Widget>.generate(tabs.length, (index) {
        final selected = widget.state.insightsTabIndex == index;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: index == tabs.length - 1 ? 0 : 8),
            child: GestureDetector(
              onTap: () => widget.state.setInsightsTabIndex(index),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                height: 48,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  color: selected ? Colors.white : Colors.white.withValues(alpha: 0.04),
                  border: Border.all(color: selected ? Colors.white : Colors.white12),
                ),
                alignment: Alignment.center,
                child: Text(
                  tabs[index],
                  style: TextStyle(
                    color: selected ? Colors.black : Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _emptyInsightsState(BuildContext context) {
    return _surfaceCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          children: [
            const Text(
              '😴💨🥱💬😪',
              style: TextStyle(fontSize: 30),
            ),
            const SizedBox(height: 14),
            const Text(
              'No sounds recorded',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 10),
            const Text(
              'Track your sleep and get all the data and recordings of what happens throughout the night using our Sleep Tracker',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => widget.onAction(
                context,
                const HomeItemContent(title: 'Track my sleep', ctaLabel: 'Track my sleep'),
                'insight_snore',
              ),
              style: FilledButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                minimumSize: const Size(200, 52),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
              ),
              child: const Text('Track My Sleep'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryTab(
    TrackedSleepNight night,
    List<InsightSummaryCardData> summaryCards,
  ) {
    return Column(
      children: [
        SizedBox(
          height: 340,
          child: PageView.builder(
            controller: _summaryController,
            itemCount: summaryCards.length,
            onPageChanged: (value) {
              setState(() => _summaryIndex = value);
            },
            itemBuilder: (_, index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: _summaryCard(summaryCards[index]),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List<Widget>.generate(
            summaryCards.length,
            (index) => Container(
              width: 7,
              height: 7,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: index == _summaryIndex ? Colors.white : Colors.white24,
              ),
            ),
          ),
        ),
        const SizedBox(height: 18),
        _surfaceCard(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(child: _statCell(Icons.nightlight_round, 'Bedtime', _formatInsightTime(night.bedtime))),
                  const SizedBox(width: 12),
                  Expanded(child: _statCell(Icons.wb_sunny_outlined, 'Wake up', _formatInsightTime(night.wakeTime))),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: _statCell(
                      Icons.bedtime_outlined,
                      'Time asleep',
                      _formatInsightHours(night.timeAsleepMinutes),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _statCell(
                      Icons.alarm_on_rounded,
                      'Sleep Goal',
                      _formatInsightHours(night.sleepGoalMinutes),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),
        _buildPhasesPreview(night),
      ],
    );
  }

  Widget _buildPhasesPreview(TrackedSleepNight night) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Sleep Phases', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 12),
        _surfaceCard(
          child: SizedBox(
            height: 190,
            child: CustomPaint(
              painter: _SleepPhasesChartPainter(night.sleepPhases.timeline),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPhasesTab(TrackedSleepNight night) {
    final totals = night.sleepPhases.totals;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _surfaceCard(
          child: Column(
            children: [
              SizedBox(
                height: 180,
                child: CustomPaint(
                  painter: _SleepPhasesChartPainter(night.sleepPhases.timeline),
                  child: const SizedBox.expand(),
                ),
              ),
              const SizedBox(height: 18),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    _phaseTotalCard('Awake', totals['awake'] ?? 0, const Color(0xFFFFB7A0), selected: night.sleepPhases.focusKey == 'awake'),
                    const SizedBox(width: 10),
                    _phaseTotalCard('Dream', totals['dream'] ?? 0, const Color(0xFFF48AC3), selected: night.sleepPhases.focusKey == 'dream'),
                    const SizedBox(width: 10),
                    _phaseTotalCard('Light', totals['light'] ?? 0, const Color(0xFFB96CFF), selected: night.sleepPhases.focusKey == 'light'),
                    const SizedBox(width: 10),
                    _phaseTotalCard('Deep', totals['deep'] ?? 0, const Color(0xFF5D8CFF), selected: night.sleepPhases.focusKey == 'deep'),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Text(
          night.sleepPhases.focusTitle,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: 8),
        Text(
          night.sleepPhases.focusBody,
          style: const TextStyle(color: Colors.white70, height: 1.35),
        ),
        const SizedBox(height: 18),
        Container(height: 1, color: Colors.white12),
        const SizedBox(height: 18),
        const Text('Sleep all night', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(
          night.sleepPhases.keyInsights,
          style: const TextStyle(color: Colors.white70, height: 1.35),
        ),
        const SizedBox(height: 14),
        if (night.recommendedTracks.isNotEmpty)
          _recommendedTrackRow(night.recommendedTracks.first)
        else
          const SizedBox.shrink(),
        const SizedBox(height: 18),
        Container(height: 1, color: Colors.white12),
        const SizedBox(height: 18),
        const Text('Key insights', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
        const SizedBox(height: 10),
        Text(
          night.sleepPhases.keyInsights,
          style: const TextStyle(color: Colors.white70, height: 1.35),
        ),
      ],
    );
  }

  Widget _buildRecordingsTab(BuildContext context, TrackedSleepNight night) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _surfaceCard(
          child: Column(
            children: [
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: night.soundDetections
                    .map((detection) => _detectionChip(detection))
                    .toList(),
              ),
              const SizedBox(height: 18),
              if (night.recordings.isEmpty)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    color: Colors.white.withValues(alpha: 0.03),
                    border: Border.all(color: Colors.white10),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.graphic_eq_rounded, color: Colors.white54),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'No recordings available for this night yet.',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    ],
                  ),
                )
              else
                Column(
                  children: night.recordings
                      .map((recording) => _recordingRow(recording))
                      .toList(),
                ),
            ],
          ),
        ),
        if (night.recordings.isEmpty) ...[
          const SizedBox(height: 18),
          _surfaceCard(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                children: [
                  const Text('😴💨🥱💬😪', style: TextStyle(fontSize: 30)),
                  const SizedBox(height: 12),
                  const Text(
                    'No sounds recorded',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Track your sleep and get all the data and recordings of what happens throughout the night using our Sleep Tracker',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 20),
                  FilledButton(
                    onPressed: () => widget.onAction(
                      context,
                      const HomeItemContent(title: 'Track my sleep', ctaLabel: 'Track my sleep'),
                      'insight_snore',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.black,
                      minimumSize: const Size(200, 52),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
                    ),
                    child: const Text('Track My Sleep'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _summaryCard(InsightSummaryCardData card) {
    final theme = _insightTheme(card.key);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(28),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: theme,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Align(
            alignment: Alignment.topRight,
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.15),
              ),
              child: const Icon(Icons.info_outline, size: 16),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            card.metric,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 42, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 10),
          Text(
            card.eyebrow,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white70),
          ),
          const SizedBox(height: 14),
          Text(
            card.title,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Text(
            card.subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 14, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _statCell(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: const Color(0xFFD2D0FF)),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              const SizedBox(height: 2),
              Text(label, style: const TextStyle(color: Colors.white70)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _phaseTotalCard(String label, int minutes, Color color, {bool selected = false}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      width: 104,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: selected ? Colors.white.withValues(alpha: 0.12) : Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: selected ? Colors.white24 : Colors.white10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(4)),
          ),
          const SizedBox(height: 10),
          Text(_formatInsightMinutes(minutes), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ),
    );
  }

  Widget _recommendedTrackRow(RecommendedTrackData recommendation) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 62,
            height: 62,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(colors: [Color(0xFF21447A), Color(0xFF472E8A)]),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  recommendation.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: 4),
                Text(
                  recommendation.subtitle,
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _detectionChip(SoundDetectionData detection) {
    return SizedBox(
      width: 94,
      child: Column(
        children: [
          Text(detection.emoji, style: const TextStyle(fontSize: 30)),
          const SizedBox(height: 6),
          Text(
            detection.status,
            style: const TextStyle(fontWeight: FontWeight.w700),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            detection.label,
            style: const TextStyle(color: Colors.white70),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _recordingRow(NightRecordingData recording) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: Colors.white.withValues(alpha: 0.04),
        border: Border.all(color: Colors.white10),
      ),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.08),
            ),
            alignment: Alignment.center,
            child: const Icon(Icons.graphic_eq_rounded),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(recording.label, style: const TextStyle(fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '${recording.description} • ${_formatInsightClip(recording.durationSeconds)}',
                  style: const TextStyle(color: Colors.white70),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _surfaceCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        color: Colors.white.withValues(alpha: 0.06),
      ),
      child: child,
    );
  }

  List<Color> _insightTheme(String key) {
    switch (key) {
      case 'quality':
        return const [Color(0xFF0E5A53), Color(0xFF123E3A)];
      case 'total_sleep':
        return const [Color(0xFF7E6CCF), Color(0xFFC48898)];
      case 'snoring':
        return const [Color(0xFF366EAF), Color(0xFF2A4E86)];
      case 'movement':
        return const [Color(0xFFC2774E), Color(0xFFAF8A5D)];
      default:
        return const [Color(0xFF5E64C5), Color(0xFF3F4C9A)];
    }
  }

  List<InsightSummaryCardData> _fallbackSummaryCards(TrackedSleepNight night) {
    return <InsightSummaryCardData>[
      InsightSummaryCardData(
        key: 'quality',
        eyebrow: 'SLEEP QUALITY',
        title: night.qualityScore >= 85 ? 'Nailed it!' : 'A restorative night',
        subtitle: "Swipe left to see last night's highlights",
        metric: '${night.qualityScore}',
      ),
      InsightSummaryCardData(
        key: 'total_sleep',
        eyebrow: '${_formatInsightHours(night.timeAsleepMinutes)} OUT OF ${_formatInsightHours(night.sleepGoalMinutes)}',
        title: 'Total Sleep Time',
        subtitle: 'Another night, another win. You are building steadier sleep habits.',
        metric: _formatInsightHours(night.timeAsleepMinutes),
      ),
    ];
  }

  Future<void> _showCalendarSheet(BuildContext context) async {
    final state = widget.state;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF23285A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (sheetContext) => AnimatedBuilder(
        animation: state,
        builder: (_, __) {
          final month = state.insightsCalendarMonth;
          final firstDay = DateTime(month.year, month.month, 1);
          final startWeekday = firstDay.weekday % 7;
          final daysInMonth = DateTime(month.year, month.month + 1, 0).day;
          final available = state.insightAvailableDates
              .map((date) => '${date.year}-${date.month}-${date.day}')
              .toSet();
          final selected = state.selectedInsightsNight?.trackedDate;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 22),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        onPressed: () => state.setInsightsCalendarMonth(DateTime(month.year, month.month - 1)),
                        icon: const Icon(Icons.chevron_left_rounded),
                      ),
                      Expanded(
                        child: Text(
                          _formatInsightMonth(month),
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800),
                        ),
                      ),
                      IconButton(
                        onPressed: () => state.setInsightsCalendarMonth(DateTime(month.year, month.month + 1)),
                        icon: const Icon(Icons.chevron_right_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Row(
                    children: [
                      Expanded(child: Center(child: Text('Sun', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Mon', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Tue', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Wed', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Thu', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Fri', style: TextStyle(color: Colors.white70)))),
                      Expanded(child: Center(child: Text('Sat', style: TextStyle(color: Colors.white70)))),
                    ],
                  ),
                  const SizedBox(height: 10),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: startWeekday + daysInMonth,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 7,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemBuilder: (_, index) {
                      if (index < startWeekday) {
                        return const SizedBox.shrink();
                      }
                      final day = index - startWeekday + 1;
                      final date = DateTime(month.year, month.month, day);
                      final key = '${date.year}-${date.month}-${date.day}';
                      final isAvailable = available.contains(key);
                      final isSelected = selected != null &&
                          selected.year == date.year &&
                          selected.month == date.month &&
                          selected.day == date.day;
                      return GestureDetector(
                        onTap: !isAvailable
                            ? null
                            : () {
                                state.selectInsightNightByDate(date);
                                Navigator.of(sheetContext).pop();
                              },
                        child: Container(
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: isSelected ? Colors.white : Colors.transparent,
                              width: 2,
                            ),
                            color: isAvailable ? Colors.transparent : Colors.white.withValues(alpha: 0.02),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            '$day',
                            style: TextStyle(
                              color: isAvailable ? Colors.white : Colors.white38,
                              fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _SleepPhasesChartPainter extends CustomPainter {
  _SleepPhasesChartPainter(this.timeline);

  final List<SleepPhaseTimelinePoint> timeline;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..strokeWidth = 3
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..shader = const LinearGradient(
        colors: [Color(0xFF5D8CFF), Color(0xFFB96CFF), Color(0xFFF48AC3)],
      ).createShader(Offset.zero & size);
    final grid = Paint()
      ..color = Colors.white.withValues(alpha: 0.08)
      ..strokeWidth = 1;

    final panel = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(20));
    canvas.drawRRect(panel, background);

    for (var i = 1; i < 6; i++) {
      final dx = size.width * (i / 6);
      canvas.drawLine(Offset(dx, 10), Offset(dx, size.height - 10), grid);
    }

    if (timeline.isEmpty) {
      return;
    }

    final totalMinutes = timeline.fold<int>(0, (sum, point) => sum + point.minutes);
    if (totalMinutes <= 0) {
      return;
    }

    double yForPhase(String phase) {
      switch (phase) {
        case 'awake':
          return size.height * 0.24;
        case 'dream':
          return size.height * 0.38;
        case 'deep':
          return size.height * 0.76;
        case 'light':
        default:
          return size.height * 0.56;
      }
    }

    final path = Path();
    var currentMinute = 0.0;
    for (var index = 0; index < timeline.length; index++) {
      final point = timeline[index];
      final startX = (currentMinute / totalMinutes) * size.width;
      final endX = ((currentMinute + point.minutes) / totalMinutes) * size.width;
      final y = yForPhase(point.phase);
      if (index == 0) {
        path.moveTo(startX, y);
      } else {
        path.lineTo(startX, y);
      }
      path.lineTo(endX, y);
      currentMinute += point.minutes;
    }

    canvas.drawPath(path, stroke);
  }

  @override
  bool shouldRepaint(covariant _SleepPhasesChartPainter oldDelegate) {
    return oldDelegate.timeline != timeline;
  }
}

class SleepInsights {
  const SleepInsights({
    required this.usageFrequencyLast7Days,
    required this.consistencyScore,
    required this.averageDurationMinutes,
    this.nights = const <TrackedSleepNight>[],
    this.availableDates = const <DateTime>[],
  });

  final int usageFrequencyLast7Days;
  final int consistencyScore;
  final int averageDurationMinutes;
  final List<TrackedSleepNight> nights;
  final List<DateTime> availableDates;

  factory SleepInsights.fromJson(Map<String, dynamic> json) {
    final nightsRaw = json['nights'] is List ? json['nights'] as List : const <dynamic>[];
    final availableDatesRaw = json['available_dates'] is List
        ? json['available_dates'] as List
        : const <dynamic>[];
    return SleepInsights(
      usageFrequencyLast7Days: _toInt(json['usage_frequency_last_7_days']),
      consistencyScore: _toInt(json['consistency_score']),
      averageDurationMinutes: _toInt(json['average_duration_minutes']),
      nights: nightsRaw
          .whereType<Map<String, dynamic>>()
          .map(TrackedSleepNight.fromJson)
          .toList(),
      availableDates: availableDatesRaw
          .map((value) => DateTime.tryParse('$value'))
          .whereType<DateTime>()
          .map((value) => DateTime(value.year, value.month, value.day))
          .toList(),
    );
  }
}

class TrackedSleepNight {
  const TrackedSleepNight({
    required this.nightId,
    required this.status,
    required this.trackedDate,
    this.bedtime,
    this.wakeTime,
    required this.timeAsleepMinutes,
    required this.sleepGoalMinutes,
    required this.qualityScore,
    required this.summaryCards,
    required this.sleepPhases,
    required this.soundDetections,
    required this.recordings,
    required this.recommendedTracks,
    this.localRecordingPath,
    this.wakeAlarmLabel,
    this.metadata = const <String, dynamic>{},
    this.isLocalOnly = false,
  });

  final String nightId;
  final String status;
  final DateTime trackedDate;
  final DateTime? bedtime;
  final DateTime? wakeTime;
  final int timeAsleepMinutes;
  final int sleepGoalMinutes;
  final int qualityScore;
  final List<InsightSummaryCardData> summaryCards;
  final SleepPhaseInsightData sleepPhases;
  final List<SoundDetectionData> soundDetections;
  final List<NightRecordingData> recordings;
  final List<RecommendedTrackData> recommendedTracks;
  final String? localRecordingPath;
  final String? wakeAlarmLabel;
  final Map<String, dynamic> metadata;
  final bool isLocalOnly;

  factory TrackedSleepNight.active({
    required String nightId,
    required DateTime trackedDate,
    required DateTime bedtime,
    required int sleepGoalMinutes,
    String? localRecordingPath,
    String? wakeAlarmLabel,
    Map<String, dynamic> metadata = const <String, dynamic>{},
  }) {
    return TrackedSleepNight(
      nightId: nightId,
      status: 'active',
      trackedDate: trackedDate,
      bedtime: bedtime,
      timeAsleepMinutes: 0,
      sleepGoalMinutes: sleepGoalMinutes,
      qualityScore: 0,
      summaryCards: const <InsightSummaryCardData>[],
      sleepPhases: SleepPhaseInsightData.empty(),
      soundDetections: const <SoundDetectionData>[],
      recordings: const <NightRecordingData>[],
      recommendedTracks: const <RecommendedTrackData>[],
      localRecordingPath: localRecordingPath,
      wakeAlarmLabel: wakeAlarmLabel,
      metadata: metadata,
      isLocalOnly: true,
    );
  }

  factory TrackedSleepNight.fromJson(Map<String, dynamic> json) {
    final bedtime = DateTime.tryParse('${json['bedtime'] ?? ''}');
    final trackedDate = DateTime.tryParse('${json['tracked_date'] ?? ''}') ??
        bedtime ??
        DateTime.now();
    final summaryCardsRaw = json['summary_cards'] is List
        ? json['summary_cards'] as List
        : const <dynamic>[];
    final soundDetectionsRaw = json['sound_detections'] is List
        ? json['sound_detections'] as List
        : const <dynamic>[];
    final recordingsRaw = json['recordings'] is List
        ? json['recordings'] as List
        : const <dynamic>[];
    final recommendedRaw = json['recommended_tracks'] is List
        ? json['recommended_tracks'] as List
        : const <dynamic>[];
    final phasesRaw = json['sleep_phases'] is Map<String, dynamic>
        ? json['sleep_phases'] as Map<String, dynamic>
        : <String, dynamic>{};

    return TrackedSleepNight(
      nightId: '${json['night_id'] ?? json['id'] ?? ''}',
      status: '${json['status'] ?? 'analyzed'}',
      trackedDate: DateTime(trackedDate.year, trackedDate.month, trackedDate.day),
      bedtime: bedtime,
      wakeTime: DateTime.tryParse('${json['wake_time'] ?? ''}'),
      timeAsleepMinutes: _toInt(json['time_asleep_minutes']),
      sleepGoalMinutes: _toInt(json['sleep_goal_minutes']),
      qualityScore: _toInt(json['quality_score']),
      summaryCards: summaryCardsRaw
          .whereType<Map<String, dynamic>>()
          .map(InsightSummaryCardData.fromJson)
          .toList(),
      sleepPhases: SleepPhaseInsightData.fromJson(phasesRaw),
      soundDetections: soundDetectionsRaw
          .whereType<Map<String, dynamic>>()
          .map(SoundDetectionData.fromJson)
          .toList(),
      recordings: recordingsRaw
          .whereType<Map<String, dynamic>>()
          .map(NightRecordingData.fromJson)
          .toList(),
      recommendedTracks: recommendedRaw
          .whereType<Map<String, dynamic>>()
          .map(RecommendedTrackData.fromJson)
          .toList(),
      localRecordingPath: json['local_recording_path']?.toString(),
      wakeAlarmLabel: json['wake_alarm_label']?.toString(),
      metadata: json['metadata'] is Map<String, dynamic>
          ? json['metadata'] as Map<String, dynamic>
          : <String, dynamic>{},
      isLocalOnly: json['is_local_only'] == true || '${json['night_id'] ?? ''}'.startsWith('local-'),
    );
  }

  bool get isActive => status == 'active';
  bool get hasAnalysis => summaryCards.isNotEmpty || recordings.isNotEmpty || qualityScore > 0;
  int get totalDetectedSounds =>
      soundDetections.fold<int>(0, (sum, detection) => sum + detection.count);

  TrackedSleepNight copyWith({
    String? status,
    DateTime? trackedDate,
    DateTime? bedtime,
    DateTime? wakeTime,
    int? timeAsleepMinutes,
    int? sleepGoalMinutes,
    int? qualityScore,
    List<InsightSummaryCardData>? summaryCards,
    SleepPhaseInsightData? sleepPhases,
    List<SoundDetectionData>? soundDetections,
    List<NightRecordingData>? recordings,
    List<RecommendedTrackData>? recommendedTracks,
    String? localRecordingPath,
    String? wakeAlarmLabel,
    Map<String, dynamic>? metadata,
    bool? isLocalOnly,
  }) {
    return TrackedSleepNight(
      nightId: nightId,
      status: status ?? this.status,
      trackedDate: trackedDate ?? this.trackedDate,
      bedtime: bedtime ?? this.bedtime,
      wakeTime: wakeTime ?? this.wakeTime,
      timeAsleepMinutes: timeAsleepMinutes ?? this.timeAsleepMinutes,
      sleepGoalMinutes: sleepGoalMinutes ?? this.sleepGoalMinutes,
      qualityScore: qualityScore ?? this.qualityScore,
      summaryCards: summaryCards ?? this.summaryCards,
      sleepPhases: sleepPhases ?? this.sleepPhases,
      soundDetections: soundDetections ?? this.soundDetections,
      recordings: recordings ?? this.recordings,
      recommendedTracks: recommendedTracks ?? this.recommendedTracks,
      localRecordingPath: localRecordingPath ?? this.localRecordingPath,
      wakeAlarmLabel: wakeAlarmLabel ?? this.wakeAlarmLabel,
      metadata: metadata ?? this.metadata,
      isLocalOnly: isLocalOnly ?? this.isLocalOnly,
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'night_id': nightId,
      'status': status,
      'tracked_date': trackedDate.toIso8601String(),
      'bedtime': bedtime?.toIso8601String(),
      'wake_time': wakeTime?.toIso8601String(),
      'time_asleep_minutes': timeAsleepMinutes,
      'sleep_goal_minutes': sleepGoalMinutes,
      'quality_score': qualityScore,
      'summary_cards': summaryCards.map((card) => card.toJson()).toList(),
      'sleep_phases': sleepPhases.toJson(),
      'sound_detections': soundDetections.map((item) => item.toJson()).toList(),
      'recordings': recordings.map((item) => item.toJson()).toList(),
      'recommended_tracks': recommendedTracks.map((item) => item.toJson()).toList(),
      'local_recording_path': localRecordingPath,
      'wake_alarm_label': wakeAlarmLabel,
      'metadata': metadata,
      'is_local_only': isLocalOnly,
    };
  }
}

class InsightSummaryCardData {
  const InsightSummaryCardData({
    required this.key,
    required this.eyebrow,
    required this.title,
    required this.subtitle,
    required this.metric,
  });

  final String key;
  final String eyebrow;
  final String title;
  final String subtitle;
  final String metric;

  factory InsightSummaryCardData.fromJson(Map<String, dynamic> json) {
    return InsightSummaryCardData(
      key: '${json['key'] ?? 'quality'}',
      eyebrow: '${json['eyebrow'] ?? ''}',
      title: '${json['title'] ?? ''}',
      subtitle: '${json['subtitle'] ?? ''}',
      metric: '${json['metric'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'eyebrow': eyebrow,
        'title': title,
        'subtitle': subtitle,
        'metric': metric,
      };
}

class SleepPhaseInsightData {
  const SleepPhaseInsightData({
    required this.timeline,
    required this.totals,
    required this.focusKey,
    required this.focusTitle,
    required this.focusBody,
    required this.keyInsights,
  });

  final List<SleepPhaseTimelinePoint> timeline;
  final Map<String, int> totals;
  final String focusKey;
  final String focusTitle;
  final String focusBody;
  final String keyInsights;

  factory SleepPhaseInsightData.empty() {
    return const SleepPhaseInsightData(
      timeline: <SleepPhaseTimelinePoint>[],
      totals: <String, int>{'awake': 0, 'dream': 0, 'light': 0, 'deep': 0},
      focusKey: 'light',
      focusTitle: 'Light',
      focusBody: '',
      keyInsights: '',
    );
  }

  factory SleepPhaseInsightData.fromJson(Map<String, dynamic> json) {
    final timelineRaw = json['timeline'] is List ? json['timeline'] as List : const <dynamic>[];
    final totalsRaw = json['totals'] is Map<String, dynamic>
        ? json['totals'] as Map<String, dynamic>
        : <String, dynamic>{};
    return SleepPhaseInsightData(
      timeline: timelineRaw
          .whereType<Map<String, dynamic>>()
          .map(SleepPhaseTimelinePoint.fromJson)
          .toList(),
      totals: <String, int>{
        'awake': _toInt(totalsRaw['awake']),
        'dream': _toInt(totalsRaw['dream']),
        'light': _toInt(totalsRaw['light']),
        'deep': _toInt(totalsRaw['deep']),
      },
      focusKey: '${json['focus_key'] ?? 'light'}',
      focusTitle: '${json['focus_title'] ?? 'Light'}',
      focusBody: '${json['focus_body'] ?? ''}',
      keyInsights: '${json['key_insights'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'timeline': timeline.map((point) => point.toJson()).toList(),
        'totals': totals,
        'focus_key': focusKey,
        'focus_title': focusTitle,
        'focus_body': focusBody,
        'key_insights': keyInsights,
      };
}

class SleepPhaseTimelinePoint {
  const SleepPhaseTimelinePoint({
    required this.minuteOffset,
    required this.minutes,
    required this.phase,
  });

  final int minuteOffset;
  final int minutes;
  final String phase;

  factory SleepPhaseTimelinePoint.fromJson(Map<String, dynamic> json) {
    return SleepPhaseTimelinePoint(
      minuteOffset: _toInt(json['minute_offset']),
      minutes: _toInt(json['minutes']),
      phase: '${json['phase'] ?? 'light'}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'minute_offset': minuteOffset,
        'minutes': minutes,
        'phase': phase,
      };
}

class SoundDetectionData {
  const SoundDetectionData({
    required this.key,
    required this.label,
    required this.emoji,
    required this.count,
    required this.status,
    required this.minutes,
    required this.confidenceScore,
  });

  final String key;
  final String label;
  final String emoji;
  final int count;
  final String status;
  final int minutes;
  final int confidenceScore;

  factory SoundDetectionData.fromJson(Map<String, dynamic> json) {
    return SoundDetectionData(
      key: '${json['key'] ?? ''}',
      label: '${json['label'] ?? ''}',
      emoji: '${json['emoji'] ?? ''}',
      count: _toInt(json['count']),
      status: '${json['status'] ?? 'None'}',
      minutes: _toInt(json['minutes']),
      confidenceScore: _toInt(json['confidence_score']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'key': key,
        'label': label,
        'emoji': emoji,
        'count': count,
        'status': status,
        'minutes': minutes,
        'confidence_score': confidenceScore,
      };
}

class NightRecordingData {
  const NightRecordingData({
    required this.id,
    required this.label,
    required this.description,
    required this.detectionKey,
    required this.startSecond,
    required this.durationSeconds,
    required this.confidenceScore,
    this.occurredAt,
    this.sourceUrl,
  });

  final String id;
  final String label;
  final String description;
  final String detectionKey;
  final int startSecond;
  final int durationSeconds;
  final int confidenceScore;
  final DateTime? occurredAt;
  final String? sourceUrl;

  factory NightRecordingData.fromJson(Map<String, dynamic> json) {
    return NightRecordingData(
      id: '${json['id'] ?? ''}',
      label: '${json['label'] ?? ''}',
      description: '${json['description'] ?? ''}',
      detectionKey: '${json['detection_key'] ?? ''}',
      startSecond: _toInt(json['start_second']),
      durationSeconds: _toInt(json['duration_seconds']),
      confidenceScore: _toInt(json['confidence_score']),
      occurredAt: DateTime.tryParse('${json['occurred_at'] ?? ''}'),
      sourceUrl: json['source_url']?.toString(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'label': label,
        'description': description,
        'detection_key': detectionKey,
        'start_second': startSecond,
        'duration_seconds': durationSeconds,
        'confidence_score': confidenceScore,
        'occurred_at': occurredAt?.toIso8601String(),
        'source_url': sourceUrl,
      };
}

class RecommendedTrackData {
  const RecommendedTrackData({
    required this.id,
    required this.title,
    required this.subtitle,
  });

  final int? id;
  final String title;
  final String subtitle;

  factory RecommendedTrackData.fromJson(Map<String, dynamic> json) {
    return RecommendedTrackData(
      id: _nullableInt(json['id']),
      title: '${json['title'] ?? ''}',
      subtitle: '${json['subtitle'] ?? ''}',
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'title': title,
        'subtitle': subtitle,
      };
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
    this.role,
    this.headline,
    this.phone,
    this.bio,
  });

  final int id;
  final String name;
  final String email;
  final String? role;
  final String? headline;
  final String? phone;
  final String? bio;

  factory AppUserProfile.fromJson(Map<String, dynamic> json) {
    return AppUserProfile(
      id: _toInt(json['id']),
      name: '${json['name'] ?? ''}',
      email: '${json['email'] ?? ''}',
      role: json['role']?.toString(),
      headline: json['headline']?.toString(),
      phone: json['phone']?.toString(),
      bio: json['bio']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'name': name,
      'email': email,
      'role': role,
      'headline': headline,
      'phone': phone,
      'bio': bio,
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
    this.lastPlayedAt,
    this.updatedAt,
  });

  final int id;
  final String itemType;
  final String itemRef;
  final String title;
  final String? subtitle;
  final Map<String, dynamic> meta;
  final DateTime? lastPlayedAt;
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
      lastPlayedAt: DateTime.tryParse('${json['last_played_at'] ?? ''}'),
      updatedAt: DateTime.tryParse('${json['updated_at'] ?? ''}'),
    );
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'id': id,
      'item_type': itemType,
      'item_ref': itemRef,
      'title': title,
      'subtitle': subtitle,
      'meta': meta,
      'last_played_at': lastPlayedAt?.toIso8601String(),
      'updated_at': updatedAt?.toIso8601String(),
    };
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

HomeItemContent _withDefaultPlayAction(
  HomeItemContent item, {
  String source = 'content_item',
}) {
  if ((item.meta['action']?.toString() ?? '').isNotEmpty) {
    return item;
  }
  final mergedMeta = <String, dynamic>{
    ...item.meta,
    'action': 'play_track',
    'deep_link': item.title,
    'analytics_event': 'play_track_from_$source',
  };
  return HomeItemContent(
    title: item.title,
    subtitle: item.subtitle,
    tag: item.tag,
    imageUrl: item.imageUrl,
    iconUrl: item.iconUrl,
    ctaLabel: item.ctaLabel,
    meta: mergedMeta,
  );
}

class LegalContentBlock {
  const LegalContentBlock({
    required this.heading,
    required this.body,
    required this.section,
  });

  final String heading;
  final String body;
  final String section;

  factory LegalContentBlock.fromJson(Map<String, dynamic> json) {
    return LegalContentBlock(
      heading: '${json['heading'] ?? ''}',
      body: '${json['body'] ?? ''}',
      section: '${json['section'] ?? ''}',
    );
  }
}

class LegalContentDocument {
  const LegalContentDocument({
    required this.slug,
    required this.title,
    required this.blocks,
    this.updatedAt,
  });

  final String slug;
  final String title;
  final String? updatedAt;
  final List<LegalContentBlock> blocks;

  factory LegalContentDocument.fromJson(Map<String, dynamic> json) {
    final rawBlocks = (json['blocks'] as List<dynamic>? ?? <dynamic>[]);
    return LegalContentDocument(
      slug: '${json['slug'] ?? ''}',
      title: '${json['title'] ?? ''}',
      updatedAt: json['updated_at']?.toString(),
      blocks: rawBlocks
          .whereType<Map<String, dynamic>>()
          .map(LegalContentBlock.fromJson)
          .toList(),
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

typedef ContentActionHandler = Future<void> Function(
  BuildContext context,
  HomeItemContent item,
  String source,
);
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
    String? screen,
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
    if (screen != null && screen.isNotEmpty) {
      params.add('screen=${Uri.encodeQueryComponent(screen)}');
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

  Future<TrackedSleepNight> startTrackedNight({
    required String deviceId,
    required int? sessionId,
    required int? preferredTrackId,
    required String entryPoint,
    required DateTime startedAt,
    required DateTime trackedDate,
    required int sleepGoalMinutes,
    required int smartAlarmWindowMinutes,
    required String wakeAlarmTime,
    required Map<String, dynamic> mixSnapshot,
    required Map<String, dynamic> metadata,
  }) async {
    final json = await _request(
      'POST',
      '/tracked-nights/start',
      body: {
        'device_id': deviceId,
        'session_id': sessionId,
        'preferred_track_id': preferredTrackId,
        'entry_point': entryPoint,
        'started_at': startedAt.toIso8601String(),
        'tracked_date': trackedDate.toIso8601String().split('T').first,
        'sleep_goal_minutes': sleepGoalMinutes,
        'smart_alarm_window_minutes': smartAlarmWindowMinutes,
        'wake_alarm_time': wakeAlarmTime,
        'mix_snapshot': mixSnapshot,
        'metadata': metadata,
      },
    );
    final nightRaw = json['night'] is Map<String, dynamic>
        ? json['night'] as Map<String, dynamic>
        : <String, dynamic>{};
    return TrackedSleepNight.fromJson(nightRaw);
  }

  Future<void> uploadTrackedNightRecording({
    required String nightId,
    required String deviceId,
    required String recordingPath,
    required int durationSeconds,
  }) async {
    await _requestMultipart(
      'POST',
      '/tracked-nights/$nightId/recording',
      fileField: 'recording',
      filePath: recordingPath,
      fields: <String, String>{
        'device_id': deviceId,
        'duration_seconds': '$durationSeconds',
      },
    );
  }

  Future<TrackedSleepNight> completeTrackedNight({
    required String nightId,
    required String deviceId,
    required DateTime endedAt,
    required int recordingDurationSeconds,
    required Map<String, dynamic> metadata,
  }) async {
    final json = await _request(
      'POST',
      '/tracked-nights/$nightId/complete',
      body: {
        'device_id': deviceId,
        'ended_at': endedAt.toIso8601String(),
        'recording_duration_seconds': recordingDurationSeconds,
        'metadata': metadata,
      },
    );
    final nightRaw = json['night'] is Map<String, dynamic>
        ? json['night'] as Map<String, dynamic>
        : <String, dynamic>{};
    return TrackedSleepNight.fromJson(nightRaw);
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
    DateTime? lastPlayedAt,
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
        if (lastPlayedAt != null) 'last_played_at': lastPlayedAt.toIso8601String(),
        if (ifUnmodifiedSince != null) 'if_unmodified_since': ifUnmodifiedSince.toIso8601String(),
      },
    );
  }

  Future<void> deleteSavedItem(int savedItemId) async {
    await _request('DELETE', '/saved-items/$savedItemId');
  }

  Future<AppUserProfile> updateMe({
    String? name,
    String? headline,
    String? phone,
    String? bio,
  }) async {
    final json = await _request(
      'PUT',
      '/auth/me',
      body: <String, dynamic>{
        if (name != null) 'name': name,
        if (headline != null) 'headline': headline,
        if (phone != null) 'phone': phone,
        if (bio != null) 'bio': bio,
      },
    );
    final userRaw = (json['user'] is Map<String, dynamic>)
        ? json['user'] as Map<String, dynamic>
        : <String, dynamic>{};
    return AppUserProfile.fromJson(userRaw);
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

  Future<LegalContentDocument> fetchLegalDocument(String slug) async {
    final json = await _request('GET', '/legal/${Uri.encodeComponent(slug)}');
    return LegalContentDocument.fromJson(json);
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

    final decoded = raw.isEmpty ? null : jsonDecode(raw);
    if (response.statusCode >= 400) {
      throw ApiRequestException(
        statusCode: response.statusCode,
        uri: uri,
        responseBody: decoded is Map<String, dynamic> ? decoded : <String, dynamic>{},
      );
    }

    if (raw.isEmpty) {
      return <String, dynamic>{};
    }
    if (decoded is Map<String, dynamic>) {
      return decoded;
    }
    return <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _requestMultipart(
    String method,
    String path, {
    required String fileField,
    required String filePath,
    Map<String, String> fields = const <String, String>{},
  }) async {
    final client = HttpClient();
    final uri = Uri.parse('$baseUrl$path');
    final request = await client.openUrl(method, uri).timeout(const Duration(seconds: 30));
    final boundary = '----sleepwell-${DateTime.now().microsecondsSinceEpoch}';
    request.headers.set(
      HttpHeaders.contentTypeHeader,
      'multipart/form-data; boundary=$boundary',
    );
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    if (_authToken != null && _authToken!.isNotEmpty) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_authToken');
    }

    for (final entry in fields.entries) {
      request.write('--$boundary\r\n');
      request.write('Content-Disposition: form-data; name="${entry.key}"\r\n\r\n');
      request.write('${entry.value}\r\n');
    }

    final file = File(filePath);
    final filename = file.uri.pathSegments.isEmpty ? 'recording.m4a' : file.uri.pathSegments.last;
    final fileBytes = await file.readAsBytes();
    request.write('--$boundary\r\n');
    request.write(
      'Content-Disposition: form-data; name="$fileField"; filename="$filename"\r\n',
    );
    request.write('Content-Type: audio/mp4\r\n\r\n');
    request.add(fileBytes);
    request.write('\r\n--$boundary--\r\n');

    final response = await request.close().timeout(const Duration(seconds: 60));
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

class ApiRequestException extends HttpException {
  ApiRequestException({
    required this.statusCode,
    required Uri uri,
    this.responseBody = const <String, dynamic>{},
  }) : super('API request failed ($statusCode)', uri: uri);

  final int statusCode;
  final Map<String, dynamic> responseBody;
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

String _formatTimerCountdown(Duration duration) {
  final totalSeconds = max(0, duration.inSeconds);
  final minutes = totalSeconds ~/ 60;
  final seconds = (totalSeconds % 60).toString().padLeft(2, '0');
  return '$minutes:$seconds';
}

String _formatTimeOfDay(TimeOfDay value) {
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatInsightHeaderDate(DateTime value) {
  const weekdays = <String>['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[value.weekday % 7]} ${months[value.month - 1]} ${value.day}';
}

String _formatInsightMonth(DateTime value) {
  const months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  return '${months[value.month - 1]} ${value.year}';
}

String _formatInsightTime(DateTime? value) {
  if (value == null) {
    return '--:--';
  }
  final hour = value.hour.toString().padLeft(2, '0');
  final minute = value.minute.toString().padLeft(2, '0');
  return '$hour:$minute';
}

String _formatInsightHours(int minutes) {
  final safeMinutes = max(0, minutes);
  final hours = safeMinutes ~/ 60;
  final remaining = safeMinutes % 60;
  if (hours == 0) {
    return '${remaining}m';
  }
  if (remaining == 0) {
    return '${hours}h';
  }
  return '${hours}h ${remaining}m';
}

String _formatInsightMinutes(int minutes) {
  return '${max(0, minutes)}m';
}

String _formatInsightClip(int seconds) {
  final duration = Duration(seconds: max(0, seconds));
  final minutes = duration.inMinutes;
  final remaining = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
  return '$minutes:$remaining';
}
