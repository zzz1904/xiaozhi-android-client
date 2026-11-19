import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'dart:collection';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:opus_dart/opus_dart.dart';
import 'package:just_audio/just_audio.dart' as ja;
import 'package:audio_session/audio_session.dart';
import 'package:collection/collection.dart';
import 'package:flutter_pcm_player/flutter_pcm_player.dart';
import 'package:flutter/services.dart';

/// 音频工具类，用于处理Opus音频编解码和录制播放
class AudioUtil {
  static const String TAG = "AudioUtil";
  static const int SAMPLE_RATE = 16000;
  static const int CHANNELS = 1;
  static const int FRAME_DURATION = 60; // 毫秒

  static final AudioRecorder _audioRecorder = AudioRecorder();
  static ja.AudioPlayer? _player;
  static bool _isRecorderInitialized = false;
  static bool _isPlayerInitialized = false;
  static bool _isRecording = false;
  static bool _isPlaying = false;
  static final StreamController<Uint8List> _audioStreamController =
      StreamController<Uint8List>.broadcast();
  static final StreamController<bool> _speechActivityController =
      StreamController<bool>.broadcast();
  static String? _tempFilePath;
  static Timer? _audioProcessingTimer;
  // Все входящие аудиофрагменты воспроизводятся строго по очереди.
  static Future<void> _playbackQueue = Future<void>.value();
  // Небольшой стартовый буфер сглаживает короткие сетевые задержки.
  static final List<Uint8List> _startupPlaybackBuffer = [];
  static const int _playbackPrebufferFrames = 8;
  static bool _playbackStarted = false;
  // Оценка момента, когда последний переданный PCM-фрагмент прозвучит.
  static DateTime? _estimatedPlaybackEnd;
  // Кодирование кадров микрофона выполняется последовательно: Opus encoder
  // является общим объектом и не должен использоваться конкурентно.
  static Future<void> _recordingEncodeQueue = Future<void>.value();

  // Opus相关
  static final _encoder = SimpleOpusEncoder(
    sampleRate: SAMPLE_RATE,
    channels: CHANNELS,
    application: Application.voip,
  );
  static final _decoder = SimpleOpusDecoder(
    sampleRate: SAMPLE_RATE,
    channels: CHANNELS,
  );

  // FlutterPcmPlayer实例
  static FlutterPcmPlayer? _pcmPlayer;

  /// 获取音频流
  static Stream<Uint8List> get audioStream => _audioStreamController.stream;

  /// Поток признаков речи.
  static Stream<bool> get speechActivityStream =>
      _speechActivityController.stream;

  /// 初始化音频录制器
  static Future<void> initRecorder() async {
    if (_isRecorderInitialized) return;

    print('$TAG: 开始初始化录音器');

    // 更积极地请求所有可能需要的权限
    if (Platform.isAndroid) {
      print('$TAG: 请求Android所需的所有权限');
      Map<Permission, PermissionStatus> statuses =
          await [
            Permission.microphone,
            Permission.storage,
            Permission.manageExternalStorage,
            Permission.bluetooth,
            Permission.bluetoothConnect,
            Permission.bluetoothScan,
          ].request();

      print('$TAG: 权限状态:');
      statuses.forEach((permission, status) {
        print('$TAG: $permission: $status');
      });

      if (statuses[Permission.microphone] != PermissionStatus.granted) {
        print('$TAG: 麦克风权限被拒绝');
        throw Exception('需要麦克风权限');
      }
    } else {
      // iOS/其他平台只请求麦克风权限
      final status = await Permission.microphone.request();
      if (status != PermissionStatus.granted) {
        print('$TAG: 麦克风权限被拒绝');
        throw Exception('需要麦克风权限');
      }
    }

    // 检查是否可用
    print('$TAG: 检查PCM16编码是否支持');
    final isAvailable = await _audioRecorder.isEncoderSupported(
      AudioEncoder.pcm16bits,
    );
    print('$TAG: PCM16编码支持状态: $isAvailable');

    // 设置音频模式 - 参考Android原生实现
    print('$TAG: 配置音频会话');
    final session = await AudioSession.instance;

    // 使用与原生Android实现更接近的配置
    if (Platform.isAndroid) {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.speech,
            usage: AndroidAudioUsage.voiceCommunication,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientExclusive,
          androidWillPauseWhenDucked: false,
        ),
      );
    } else {
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
          avAudioSessionCategoryOptions:
              AVAudioSessionCategoryOptions.allowBluetooth,
          avAudioSessionMode: AVAudioSessionMode.voiceChat,
        ),
      );
      await session.setActive(true);
    }

    _isRecorderInitialized = true;
    print('$TAG: 录音器初始化成功');
  }

  /// 初始化音频播放器
  static Future<void> initPlayer() async {
    // 确保任何旧播放器被释放
    await stopPlaying();

    try {
      print('$TAG: 使用简单方式初始化PCM播放器');

      // 创建新的播放器实例 - 完全按照官方示例的简单方式
      _pcmPlayer = FlutterPcmPlayer();
      await _pcmPlayer!.initialize();
      await _pcmPlayer!.play();

      _isPlayerInitialized = true;
      print('$TAG: PCM播放器初始化成功');
    } catch (e) {
      print('$TAG: PCM播放器初始化失败: $e');
      _isPlayerInitialized = false;
    }
  }

  /// Добавляет Opus-кадр в последовательную очередь воспроизведения.
  static Future<void> _enqueueOpusForPlayback(Uint8List opusData) {
    final playback = _playbackQueue.then((_) async {
      try {
        if (!_isPlayerInitialized || _pcmPlayer == null) {
          await initPlayer();
        }

        final Int16List pcmData = _decoder.decode(input: opusData);
        final Uint8List pcmBytes = Uint8List(pcmData.length * 2);
        final bytes = ByteData.view(pcmBytes.buffer);
        for (int i = 0; i < pcmData.length; i++) {
          bytes.setInt16(i * 2, pcmData[i], Endian.little);
        }

        if (_pcmPlayer != null) {
          await _pcmPlayer!.feed(pcmBytes);
          // feed() передаёт PCM плееру, но не гарантирует, что динамик уже
          // воспроизвёл весь фрагмент. Учитываем его реальную длительность.
          final now = DateTime.now();
          final previousEnd = _estimatedPlaybackEnd;
          final playbackStart =
              previousEnd != null && previousEnd.isAfter(now) ? previousEnd : now;
          final durationUs =
              (pcmData.length * Duration.microsecondsPerSecond / SAMPLE_RATE).round();
          _estimatedPlaybackEnd =
              playbackStart.add(Duration(microseconds: durationUs));
        }
      } catch (e) {
        print('$TAG: 播放失败: $e');
        await stopPlaying();
        await initPlayer();
      }
    });
    _playbackQueue = playback.catchError((Object error) {
      print('$TAG: 音频播放队列错误: $error');
    });
    return _playbackQueue;
  }

  /// Сначала накапливает три кадра (около 180 мс), затем начинает воспроизведение.
  static Future<void> playOpusData(Uint8List opusData) {
    if (!_playbackStarted) {
      _startupPlaybackBuffer.add(Uint8List.fromList(opusData));
      if (_startupPlaybackBuffer.length < _playbackPrebufferFrames) {
        return Future<void>.value();
      }
      _playbackStarted = true;
      final bufferedFrames = List<Uint8List>.from(_startupPlaybackBuffer);
      _startupPlaybackBuffer.clear();
      var result = Future<void>.value();
      for (final frame in bufferedFrames) {
        result = result.then((_) => _enqueueOpusForPlayback(frame));
      }
      return result;
    }
    return _enqueueOpusForPlayback(opusData);
  }

  /// Дожидается всех кадров, включая короткий ответ короче стартового буфера,
  /// и фактического окончания их расчётного воспроизведения через динамик.
  static Future<void> waitForPlaybackComplete() async {
    if (_startupPlaybackBuffer.isNotEmpty) {
      _playbackStarted = true;
      final bufferedFrames = List<Uint8List>.from(_startupPlaybackBuffer);
      _startupPlaybackBuffer.clear();
      for (final frame in bufferedFrames) {
        await _enqueueOpusForPlayback(frame);
      }
    }

    while (true) {
      final pendingQueue = _playbackQueue;
      await pendingQueue;
      if (identical(pendingQueue, _playbackQueue)) break;
    }

    final playbackEnd = _estimatedPlaybackEnd;
    if (playbackEnd != null) {
      final remaining = playbackEnd.difference(DateTime.now());
      if (remaining > Duration.zero) await Future.delayed(remaining);
      // Небольшой запас на аппаратный вывод последнего буфера.
      await Future.delayed(const Duration(milliseconds: 150));
    }
    _estimatedPlaybackEnd = null;
    _playbackStarted = false;
  }

  /// 停止播放
  static Future<void> stopPlaying() async {
    if (_pcmPlayer != null) {
      try {
        await _pcmPlayer!.stop();
        print('$TAG: 播放器已停止');
      } catch (e) {
        print('$TAG: 停止播放失败: $e');
      }
      _pcmPlayer = null;
      _isPlayerInitialized = false;
    }
    _startupPlaybackBuffer.clear();
    _playbackStarted = false;
    _estimatedPlaybackEnd = null;
  }

  /// 释放资源
  static Future<void> dispose() async {
    _audioStreamController.close();
    print('$TAG: 资源已释放');
  }

  /// 开始录音
  static Future<void> startRecording() async {
    if (!_isRecorderInitialized) {
      await initRecorder();
    }

    if (_isRecording) return;

    try {
      print('$TAG: 尝试启动录音');

      // 确保麦克风权限已获取 - 使用不同方式检查权限
      final status = await Permission.microphone.status;
      print('$TAG: 麦克风权限状态: $status');

      if (status != PermissionStatus.granted) {
        final result = await Permission.microphone.request();
        print('$TAG: 请求麦克风权限结果: $result');
        if (result != PermissionStatus.granted) {
          print('$TAG: 麦克风权限被拒绝');
          return;
        }
      }

      // 尝试直接使用音频流
      try {
        print('$TAG: 尝试启动流式录音');
        final stream = await _audioRecorder.startStream(
          const RecordConfig(
            encoder: AudioEncoder.pcm16bits,
            sampleRate: SAMPLE_RATE,
            numChannels: CHANNELS,
          ),
        );

        _isRecording = true;
        print('$TAG: 流式录音启动成功');

        // 直接从流中处理数据
        stream.listen(
          (data) {
            if (data.isEmpty || data.length % 2 != 0) return;
            // Не запускаем несколько encodeToOpus одновременно: иначе общий
            // Opus encoder может обработать соседние PCM-кадры в неверном порядке.
            _recordingEncodeQueue = _recordingEncodeQueue.then((_) async {
              if (!_isRecording) return;
              _publishSpeechActivity(data);
              final opusData = await encodeToOpus(data);
              if (opusData != null && _isRecording) {
                _audioStreamController.add(opusData);
              }
            }).catchError((Object error) {
              print('$TAG: Ошибка последовательного кодирования микрофона: $error');
            });
          },
          onError: (error) {
            print('$TAG: 音频流错误: $error');
            _isRecording = false;
          },
          onDone: () {
            print('$TAG: 音频流结束');
            _isRecording = false;
          },
        );
      } catch (e) {
        print('$TAG: 流式录音失败: $e');
        _isRecording = false;
        rethrow;
      }
    } catch (e, stackTrace) {
      print('$TAG: 启动录音失败: $e');
      print(stackTrace);
      _isRecording = false;
    }
  }

  /// 停止录音
  static Future<String?> stopRecording() async {
    if (!_isRecorderInitialized || !_isRecording) return null;

    // 取消定时器
    _audioProcessingTimer?.cancel();

    // 停止录音
    try {
      final path = await _audioRecorder.stop();
      _isRecording = false;
      print('$TAG: 停止录音: $path');
      return path;
    } catch (e) {
      print('$TAG: 停止录音失败: $e');
      _isRecording = false;
      return null;
    }
  }

  /// Определяет наличие речи по уровню PCM-сигнала.
  static void _publishSpeechActivity(Uint8List pcmData) {
    final sampleCount = pcmData.length ~/ 2;
    if (sampleCount == 0) return;
    var sumSquares = 0.0;
    var peak = 0;
    for (var i = 0; i + 1 < pcmData.length; i += 2) {
      var sample = pcmData[i] | (pcmData[i + 1] << 8);
      if (sample >= 0x8000) sample -= 0x10000;
      final magnitude = sample.abs();
      if (magnitude > peak) peak = magnitude;
      sumSquares += sample * sample;
    }
    final rms = math.sqrt(sumSquares / sampleCount);
    _speechActivityController.add(rms >= 700 || peak >= 2200);
  }

  /// Синтезирует русский текст Android TTS и кодирует результат в Opus 16 кГц mono.
  /// Аудио отправляется на сервер как обычная голосовая реплика, а не как текстовый JSON.
  static const MethodChannel _ttsChannel = MethodChannel('xiaozhi/tts');

  static Future<List<Uint8List>> synthesizeTextToOpus(String text) async {
    if (!Platform.isAndroid) {
      throw Exception('Отправка текста голосом сейчас поддерживается только на Android.');
    }

    final response = await _ttsChannel.invokeMapMethod<String, dynamic>(
      'synthesizeText',
      {'text': text},
    ).timeout(const Duration(seconds: 60));

    if (response == null) {
      throw Exception('Android не вернул аудиоданные синтеза речи.');
    }

    final rawAudio = response['audio'];
    final Uint8List audio = rawAudio is Uint8List
        ? rawAudio
        : Uint8List.fromList(List<int>.from(rawAudio as List));
    final int sourceRate = (response['sampleRate'] as num?)?.toInt() ?? 0;
    final int channels = (response['channels'] as num?)?.toInt() ?? 0;
    final int audioFormat = (response['audioFormat'] as num?)?.toInt() ?? 0;

    // Android ENCODING_PCM_16BIT = 2.
    if (audioFormat != 2 || sourceRate <= 0 || channels <= 0) {
      throw Exception(
        'Неподдерживаемый формат звука Android TTS (format=$audioFormat, rate=$sourceRate, channels=$channels).',
      );
    }
    if (audio.length < 2 * channels) {
      throw Exception('Android создал слишком короткий аудиофрагмент.');
    }

    final sourceSampleCount = audio.length ~/ (2 * channels);
    final source = ByteData.sublistView(audio);
    final mono = Int16List(sourceSampleCount);
    for (var i = 0; i < sourceSampleCount; i++) {
      var sum = 0;
      for (var channel = 0; channel < channels; channel++) {
        sum += source.getInt16((i * channels + channel) * 2, Endian.little);
      }
      mono[i] = (sum / channels).round().clamp(-32768, 32767).toInt();
    }

    // Линейная передискретизация к частоте, которую объявляет XiaoZhi.
    final outputCount = (mono.length * SAMPLE_RATE / sourceRate).round();
    if (outputCount <= 0) {
      throw Exception('Не удалось преобразовать аудио Android TTS.');
    }
    final resampled = Int16List(outputCount);
    for (var i = 0; i < outputCount; i++) {
      final position = i * sourceRate / SAMPLE_RATE;
      final left = position.floor().clamp(0, mono.length - 1).toInt();
      final right = (left + 1).clamp(0, mono.length - 1).toInt();
      final fraction = position - left;
      final value = mono[left] * (1.0 - fraction) + mono[right] * fraction;
      resampled[i] = value.round().clamp(-32768, 32767).toInt();
    }

    // Opus принимает кадры фиксированной длительности. Используем 60 мс,
    // как указано в hello: 16 000 Гц * 0,06 с = 960 отсчётов.
    const samplesPerFrame = SAMPLE_RATE * FRAME_DURATION ~/ 1000;
    final encoder = SimpleOpusEncoder(
      sampleRate: SAMPLE_RATE,
      channels: CHANNELS,
      application: Application.voip,
    );
    final frames = <Uint8List>[];
    for (var offset = 0; offset < resampled.length; offset += samplesPerFrame) {
      final frame = Int16List(samplesPerFrame);
      final int count = math.min(samplesPerFrame, resampled.length - offset).toInt();
      frame.setRange(0, count, resampled, offset);
      frames.add(Uint8List.fromList(encoder.encode(input: frame)));
    }

    if (frames.isEmpty) {
      throw Exception('Не удалось подготовить голосовые аудиокадры.');
    }
    return frames;
  }

  /// 将PCM数据编码为Opus格式
  static Future<Uint8List?> encodeToOpus(Uint8List pcmData) async {
    try {
      // 删除频繁日志
      // 转换PCM数据为Int16List (小端字节序，与Android一致)
      final Int16List pcmInt16 = Int16List.fromList(
        List.generate(
          pcmData.length ~/ 2,
          (i) => (pcmData[i * 2]) | (pcmData[i * 2 + 1] << 8),
        ),
      );

      // 确保数据长度符合Opus要求（必须是2.5ms、5ms、10ms、20ms、40ms或60ms的采样数）
      final int samplesPerFrame = (SAMPLE_RATE * FRAME_DURATION) ~/ 1000;

      Uint8List encoded;

      // 处理过短的数据
      if (pcmInt16.length < samplesPerFrame) {
        // 对于过短的数据，可以通过添加静音来填充到所需长度
        final Int16List paddedData = Int16List(samplesPerFrame);
        for (int i = 0; i < pcmInt16.length; i++) {
          paddedData[i] = pcmInt16[i];
        }

        // 编码填充后的数据
        encoded = Uint8List.fromList(_encoder.encode(input: paddedData));
      } else {
        // 对于足够长的数据，裁剪到精确的帧长度
        encoded = Uint8List.fromList(
          _encoder.encode(input: pcmInt16.sublist(0, samplesPerFrame)),
        );
      }

      return encoded;
    } catch (e, stackTrace) {
      print('$TAG: Opus编码失败: $e');
      print(stackTrace);
      return null;
    }
  }

  /// 检查是否正在录音
  static bool get isRecording => _isRecording;

  /// 检查是否正在播放
  static bool get isPlaying => _isPlaying;
}
