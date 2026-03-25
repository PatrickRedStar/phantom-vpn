import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/vpn_profile.dart';
import '../data/repositories/profiles_repository.dart';

final profilesRepoProvider = Provider<ProfilesRepository>((ref) => ProfilesRepository());

class ProfilesState {
  final List<VpnProfile> profiles;
  final String? activeId;
  final bool loaded;

  const ProfilesState({
    this.profiles = const [],
    this.activeId,
    this.loaded = false,
  });

  VpnProfile? get activeProfile {
    if (activeId == null) return profiles.isNotEmpty ? profiles.first : null;
    return profiles.where((p) => p.id == activeId).firstOrNull ?? profiles.firstOrNull;
  }

  ProfilesState copyWith({
    List<VpnProfile>? profiles,
    String? activeId,
    bool? loaded,
  }) =>
      ProfilesState(
        profiles: profiles ?? this.profiles,
        activeId: activeId ?? this.activeId,
        loaded: loaded ?? this.loaded,
      );
}

class ProfilesNotifier extends StateNotifier<ProfilesState> {
  final ProfilesRepository _repo;

  ProfilesNotifier(this._repo) : super(const ProfilesState());

  Future<void> load() async {
    await _repo.load();
    _sync();
  }

  void _sync() {
    state = ProfilesState(
      profiles: _repo.profiles,
      activeId: _repo.activeId,
      loaded: true,
    );
  }

  Future<void> addProfile(VpnProfile profile) async {
    await _repo.addProfile(profile);
    _sync();
  }

  Future<void> deleteProfile(String id) async {
    await _repo.deleteProfile(id);
    _sync();
  }

  Future<void> setActiveId(String id) async {
    await _repo.setActiveId(id);
    _sync();
  }

  Future<VpnProfile> importFromConnString(String input, {String? name}) async {
    final profile = await _repo.importFromConnString(input, name: name);
    _sync();
    return profile;
  }
}

final profilesProvider = StateNotifierProvider<ProfilesNotifier, ProfilesState>((ref) {
  return ProfilesNotifier(ref.watch(profilesRepoProvider));
});

final activeProfileProvider = Provider<VpnProfile?>((ref) {
  return ref.watch(profilesProvider).activeProfile;
});
