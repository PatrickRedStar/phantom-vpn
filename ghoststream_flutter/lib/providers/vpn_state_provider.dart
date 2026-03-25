import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../data/models/vpn_state.dart';
import '../data/services/vpn_service_bridge.dart';

final vpnBridgeProvider = Provider<VpnServiceBridge>((ref) => VpnServiceBridge());

final vpnStateProvider = StreamProvider<VpnState>((ref) {
  return ref.watch(vpnBridgeProvider).stateStream;
});
