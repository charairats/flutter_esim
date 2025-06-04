// lib/flutter_esim_method_channel.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import 'flutter_esim_installation_event.dart';
import 'flutter_esim_platform_interface.dart';

/// An implementation of [FlutterEsimPlatform] that uses method channels.
class MethodChannelFlutterEsim extends FlutterEsimPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('flutter_esim');

  @visibleForTesting
  final eventChannel = const EventChannel('flutter_esim_events');

  @visibleForTesting
  final uuid = const Uuid();

  @override
  Future<bool> isSupportESim() async {
    // Removed 'newer' parameter
    // invokeMethod called without the second argument, assuming native side handles it.
    // Or, if native side expects an argument (even empty), it could be:
    // await methodChannel.invokeMethod<bool>('isSupportESim', null); or
    // await methodChannel.invokeMethod<bool>('isSupportESim', {});
    final isSupportESim =
        await methodChannel.invokeMethod<bool>('isSupportESim');
    return isSupportESim ?? false;
  }

  @override
  Future<String> installEsimProfile(String profile) async {
    final result = await methodChannel
        .invokeMethod<String>('installEsimProfile', {'profile': profile});
    return result ?? "";
  }

  @override
  Stream<EsimInstallationEvent> installEsimEvent(
    String profile,
  ) {
    final controller = StreamController<EsimInstallationEvent>();
    StreamSubscription? eventSubscription;
    final String correlationId = uuid.v7();

    void cleanUp() {
      eventSubscription?.cancel();
      if (!controller.isClosed) {
        controller.close();
      }
    }

    // Initiate the native eSIM installation process.
    // This calls the same native method as the original installEsimProfile.
    methodChannel.invokeMethod<String>('installEsimProfile', {
      'profile': profile,
      'correlationId': correlationId,
    }).then((_) {
      // Native method call initiated.
      // controller.add(EsimInstallationEvent("initiated", null)); // Optional: send 'initiated' event
    }).catchError((error) {
      if (!controller.isClosed) {
        controller.addError(PlatformException(
            code: error.code ?? 'InvokeError',
            message: error.message,
            details: error.details));
        cleanUp();
      }
    });

    // Listen to the global event channel for installation-related events.
    eventSubscription = onEvent.listen(
        // onEvent is from superclass (FlutterEsimPlatform.instance.onEvent)
        (dynamic rawEvent) {
      if (controller.isClosed) return;

      if (rawEvent is Map) {
        if (rawEvent['correlationId'] == correlationId) {
          final String eventName =
              rawEvent['event'] as String? ?? 'unknown_event_type';
          final dynamic eventBody = rawEvent['body'];
          final event = EsimInstallationEvent(eventName, eventBody);

          switch (eventName) {
            case 'success':
              controller.add(event);
              cleanUp();
              break;
            case 'fail':
              controller.add(event);
              controller.addError(
                  Exception('eSIM installation failed. Event: $event'));
              cleanUp();
              break;
            case 'unsupport':
              controller.add(event);
              controller.addError(Exception(
                  'eSIM not supported or operation unsupported. Event: $event'));
              cleanUp();
              break;
            case 'unknown':
              controller.add(event);
              // Potentially addError and cleanUp() if 'unknown' is terminal.
              break;
            default:
              // controller.add(event); // Optionally pass through other events
              break;
          }
        }
      }
    }, onError: (error) {
      if (!controller.isClosed) {
        controller.addError(error);
        cleanUp();
      }
    }, onDone: () {
      cleanUp();
    });

    controller.onCancel = () {
      cleanUp();
    };

    return controller.stream;
  }

  @override
  Future<String> instructions() async {
    final result = await methodChannel.invokeMethod<String>('instructions');
    return result ?? "";
  }

  @override
  Stream<dynamic> get onEvent =>
      eventChannel.receiveBroadcastStream().map(_receiveCallEvent);

  dynamic _receiveCallEvent(dynamic data) {
    debugPrint('Received event: $data');
    return data;
  }
}
