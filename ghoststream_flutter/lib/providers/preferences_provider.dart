import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/repositories/preferences_repository.dart';

final prefsRepoProvider = Provider<PreferencesRepository>((ref) => PreferencesRepository());

class PreferencesState {
  final List<String> dnsServers;
  final bool splitRouting;
  final List<String> directCountries;
  final String perAppMode;
  final List<String> perAppList;
  final bool insecure;
  final String theme;
  final bool initialized;

  const PreferencesState({
    this.dnsServers = const ['8.8.8.8', '1.1.1.1'],
    this.splitRouting = false,
    this.directCountries = const [],
    this.perAppMode = 'none',
    this.perAppList = const [],
    this.insecure = false,
    this.theme = 'system',
    this.initialized = false,
  });

  PreferencesState copyWith({
    List<String>? dnsServers,
    bool? splitRouting,
    List<String>? directCountries,
    String? perAppMode,
    List<String>? perAppList,
    bool? insecure,
    String? theme,
    bool? initialized,
  }) =>
      PreferencesState(
        dnsServers: dnsServers ?? this.dnsServers,
        splitRouting: splitRouting ?? this.splitRouting,
        directCountries: directCountries ?? this.directCountries,
        perAppMode: perAppMode ?? this.perAppMode,
        perAppList: perAppList ?? this.perAppList,
        insecure: insecure ?? this.insecure,
        theme: theme ?? this.theme,
        initialized: initialized ?? this.initialized,
      );
}

class PreferencesNotifier extends StateNotifier<PreferencesState> {
  final PreferencesRepository _repo;

  PreferencesNotifier(this._repo) : super(const PreferencesState());

  Future<void> init() async {
    await _repo.init();
    state = PreferencesState(
      dnsServers: _repo.dnsServers,
      splitRouting: _repo.splitRouting,
      directCountries: _repo.directCountries,
      perAppMode: _repo.perAppMode,
      perAppList: _repo.perAppList,
      insecure: _repo.insecure,
      theme: _repo.theme,
      initialized: true,
    );
  }

  Future<void> setDns(List<String> servers) async {
    await _repo.setDnsServers(servers);
    state = state.copyWith(dnsServers: servers);
  }

  Future<void> setSplit(bool value) async {
    await _repo.setSplitRouting(value);
    state = state.copyWith(splitRouting: value);
  }

  Future<void> setDirectCountries(List<String> countries) async {
    await _repo.setDirectCountries(countries);
    state = state.copyWith(directCountries: countries);
  }

  Future<void> setPerAppMode(String mode) async {
    await _repo.setPerAppMode(mode);
    state = state.copyWith(perAppMode: mode);
  }

  Future<void> togglePerApp(String packageName) async {
    final list = [...state.perAppList];
    if (list.contains(packageName)) {
      list.remove(packageName);
    } else {
      list.add(packageName);
    }
    await _repo.setPerAppList(list);
    state = state.copyWith(perAppList: list);
  }

  Future<void> setInsecure(bool value) async {
    await _repo.setInsecure(value);
    state = state.copyWith(insecure: value);
  }

  Future<void> setTheme(String value) async {
    await _repo.setTheme(value);
    state = state.copyWith(theme: value);
  }
}

final preferencesProvider = StateNotifierProvider<PreferencesNotifier, PreferencesState>((ref) {
  return PreferencesNotifier(ref.watch(prefsRepoProvider));
});

final themeStringProvider = Provider<String>((ref) {
  return ref.watch(preferencesProvider).theme;
});
