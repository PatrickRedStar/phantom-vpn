import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../../core/theme/ghost_colors.dart';

enum _PairingState { starting, ready, received, timeout, error }

class TvPairingScreen extends StatefulWidget {
  final VoidCallback onDone;

  const TvPairingScreen({super.key, required this.onDone});

  @override
  State<TvPairingScreen> createState() => _TvPairingScreenState();
}

class _TvPairingScreenState extends State<TvPairingScreen> {
  _PairingState _state = _PairingState.starting;
  String? _qrContent;
  String? _errorMsg;
  HttpServer? _server;
  String _token = '';
  Timer? _timeoutTimer;

  @override
  void initState() {
    super.initState();
    _startServer();
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _server?.close(force: true);
    super.dispose();
  }

  String _generateToken() {
    final random = DateTime.now().millisecondsSinceEpoch;
    return random.toRadixString(36);
  }

  Future<void> _startServer() async {
    try {
      _token = _generateToken();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _server = server;

      final port = server.port;
      final payload = jsonEncode({
        'type': 'gs-pair',
        'ip': '0.0.0.0',
        'port': port,
        'token': _token,
      });

      setState(() {
        _state = _PairingState.ready;
        _qrContent = payload;
      });

      _timeoutTimer = Timer(const Duration(minutes: 5), () {
        if (mounted && _state == _PairingState.ready) {
          setState(() => _state = _PairingState.timeout);
          _server?.close(force: true);
        }
      });

      await for (final request in server) {
        if (request.method == 'POST' && request.uri.path == '/pair') {
          final auth = request.headers.value('authorization') ?? '';
          if (auth != 'Bearer $_token') {
            request.response.statusCode = 403;
            await request.response.close();
            continue;
          }
          await utf8.decoder.bind(request).join();
          request.response.statusCode = 200;
          await request.response.close();

          if (mounted) {
            setState(() => _state = _PairingState.received);
          }
          _timeoutTimer?.cancel();
          await server.close(force: true);
          break;
        } else {
          request.response.statusCode = 404;
          await request.response.close();
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _PairingState.error;
          _errorMsg = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.ghostColors;

    return Scaffold(
      backgroundColor: gc.pageBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              Row(
                children: [
                  GestureDetector(
                    onTap: widget.onDone,
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: gc.card,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: gc.border),
                      ),
                      child: Icon(Icons.arrow_back, color: gc.textPrimary, size: 20),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'Сопряжение с ТВ',
                    style: TextStyle(
                      color: gc.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 40),
              Expanded(child: _buildContent(gc)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(GhostColors gc) {
    switch (_state) {
      case _PairingState.starting:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(color: gc.accentPurple),
              const SizedBox(height: 16),
              Text('Запуск сервера...', style: TextStyle(color: gc.textSecondary, fontSize: 14)),
            ],
          ),
        );

      case _PairingState.ready:
        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
              ),
              child: QrImageView(
                data: _qrContent ?? '',
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'Отсканируйте QR-код на ТВ',
              style: TextStyle(color: gc.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'Откройте приложение GhostStream на ТВ\nи отсканируйте этот код для сопряжения',
              textAlign: TextAlign.center,
              style: TextStyle(color: gc.textTertiary, fontSize: 12, height: 1.5),
            ),
          ],
        );

      case _PairingState.received:
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: gc.greenConnected.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.check, color: gc.greenConnected, size: 36),
              ),
              const SizedBox(height: 20),
              Text(
                'Подключение получено',
                style: TextStyle(color: gc.textPrimary, fontSize: 18, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              Text(
                'Конфигурация успешно передана на ТВ',
                style: TextStyle(color: gc.textSecondary, fontSize: 13),
              ),
            ],
          ),
        );

      case _PairingState.timeout:
        return _errorWidget(gc, 'Время ожидания истекло', 'Попробуйте ещё раз');

      case _PairingState.error:
        return _errorWidget(gc, 'Ошибка', _errorMsg ?? 'Не удалось запустить сервер');
    }
  }

  Widget _errorWidget(GhostColors gc, String title, String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: gc.redError.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.error_outline, color: gc.redError, size: 36),
          ),
          const SizedBox(height: 20),
          Text(title, style: TextStyle(color: gc.textPrimary, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Text(message, style: TextStyle(color: gc.textSecondary, fontSize: 13), textAlign: TextAlign.center),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () {
              setState(() => _state = _PairingState.starting);
              _startServer();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              decoration: BoxDecoration(
                border: Border.all(color: gc.accentPurple.withValues(alpha: 0.35)),
                borderRadius: BorderRadius.circular(14),
                color: gc.accentPurple.withValues(alpha: 0.1),
              ),
              child: Text(
                'Повторить',
                style: TextStyle(color: gc.accentPurple, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
