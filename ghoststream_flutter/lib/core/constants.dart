const String appVersion = '0.13.0';
const int appVersionCode = 25;

const Map<String, List<String>> dnsPresets = {
  'Google': ['8.8.8.8', '8.8.4.4'],
  'Cloudflare': ['1.1.1.1', '1.0.0.1'],
  'AdGuard': ['94.140.14.14', '94.140.15.15'],
  'Quad9': ['9.9.9.9', '149.112.112.112'],
};

const Map<String, String> countryFlags = {
  'RU': '🇷🇺',
  'US': '🇺🇸',
  'DE': '🇩🇪',
  'NL': '🇳🇱',
  'FI': '🇫🇮',
  'SE': '🇸🇪',
  'GB': '🇬🇧',
  'FR': '🇫🇷',
  'JP': '🇯🇵',
  'SG': '🇸🇬',
  'CA': '🇨🇦',
  'AU': '🇦🇺',
  'CH': '🇨🇭',
  'KZ': '🇰🇿',
  'TR': '🇹🇷',
};

const int quicTunnelMtu = 1350;
const int batchMaxPlaintext = 65536;
const Duration statsPollingInterval = Duration(seconds: 1);
const Duration logsPollingInterval = Duration(milliseconds: 500);
const Duration reconnectBaseDelay = Duration(seconds: 3);
const int reconnectMaxAttempts = 8;
