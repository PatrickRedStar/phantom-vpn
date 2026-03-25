import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/vpn_stats.dart';
import 'vpn_state_provider.dart';

final vpnStatsProvider = StreamProvider<VpnStats>((ref) {
  return ref.watch(vpnBridgeProvider).statsStream;
});
