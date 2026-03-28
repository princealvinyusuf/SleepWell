import 'dart:math';

import 'package:flutter/material.dart';

void main() {
  runApp(const SleepWellApp());
}

class SleepWellApp extends StatefulWidget {
  const SleepWellApp({super.key});

  @override
  State<SleepWellApp> createState() => _SleepWellAppState();
}

class _SleepWellAppState extends State<SleepWellApp> {
  final _state = SleepWellState();

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

  bool isPlaying = false;
  bool loop = true;
  int sleepTimerMinutes = 30;
  SleepTrack? selectedTrack;

  final List<SleepTrack> tracks = <SleepTrack>[
    SleepTrack('Moonlight Whispers', 'whisper', true),
    SleepTrack('Forest Rain Deep Sleep', 'rain', false),
    SleepTrack('No Talking Brown Noise', 'no_talking', false),
    SleepTrack('Night Spa Roleplay', 'roleplay', true),
  ];

  void completeOnboarding({
    required bool talking,
    required int difficulty,
    required List<String> categories,
    required List<String> soundTypes,
  }) {
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
  }

  void startSleepNow() {
    final filtered = tracks.where((t) {
      final matchesTalking = t.talking == prefersTalking;
      final matchesCategory =
          preferredCategories.isEmpty || preferredCategories.contains(t.category);
      return matchesTalking && matchesCategory;
    }).toList();
    final picked = filtered.isEmpty ? tracks : filtered;
    selectedTrack = picked[Random().nextInt(picked.length)];
    isPlaying = true;
    sessions.add(SleepSession(DateTime.now(), 0));
    notifyListeners();
  }

  void stopPlayback() {
    isPlaying = false;
    if (sessions.isNotEmpty) {
      final current = sessions.removeLast();
      sessions.add(current.copyWith(durationMinutes: sleepTimerMinutes));
    }
    notifyListeners();
  }

  void updateMixer(String key, double value) {
    mixer[key] = value;
    notifyListeners();
  }
}

class SleepTrack {
  const SleepTrack(this.title, this.category, this.talking);
  final String title;
  final String category;
  final bool talking;
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
            onPressed: () {
              widget.state.completeOnboarding(
                talking: talking,
                difficulty: difficulty,
                categories: categories.toList(),
                soundTypes: soundTypes.toList(),
              );
            },
            child: const Text('Start Sleeping Better'),
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
      body: pages[index],
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
            const SizedBox(height: 22),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: const Icon(Icons.bedtime),
                label: const Text('Sleep Now'),
                onPressed: () {
                  state.startSleepNow();
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
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Smart ASMR Player', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 12),
        ...state.tracks.map(
          (track) => Card(
            child: ListTile(
              title: Text(track.title),
              subtitle: Text('${track.category} • ${track.talking ? 'talking' : 'no talking'}'),
              trailing: IconButton(
                icon: const Icon(Icons.play_arrow),
                onPressed: () {
                  state.selectedTrack = track;
                  state.isPlaying = true;
                  state.sessions.add(SleepSession(DateTime.now(), 0));
                  state.notifyListeners();
                },
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('Loop playback'),
          value: state.loop,
          onChanged: (value) {
            state.loop = value;
            state.notifyListeners();
          },
        ),
        ListTile(
          title: Text('Sleep timer (${state.sleepTimerMinutes} min)'),
          subtitle: Slider(
            value: state.sleepTimerMinutes.toDouble(),
            min: 10,
            max: 90,
            divisions: 8,
            onChanged: (v) {
              state.sleepTimerMinutes = v.toInt();
              state.notifyListeners();
            },
          ),
        ),
        FilledButton.tonal(
          onPressed: state.isPlaying ? state.stopPlayback : null,
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
      ],
    );
  }
}

class InsightsPage extends StatelessWidget {
  const InsightsPage({super.key, required this.state});
  final SleepWellState state;

  @override
  Widget build(BuildContext context) {
    final sessions = state.sessions;
    final usageFrequency = sessions.length;
    final consistency = min(100, (usageFrequency / 7 * 100).round());
    final avgDuration = sessions.isEmpty
        ? 0
        : sessions.map((s) => s.durationMinutes).reduce((a, b) => a + b) ~/
            sessions.length;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text('Basic Sleep Tracking', style: TextStyle(fontSize: 20)),
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            title: const Text('Usage frequency (7 days)'),
            trailing: Text('$usageFrequency sessions'),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Sleep consistency score'),
            trailing: Text('$consistency/100'),
          ),
        ),
        Card(
          child: ListTile(
            title: const Text('Average duration'),
            trailing: Text('$avgDuration min'),
          ),
        ),
      ],
    );
  }
}
