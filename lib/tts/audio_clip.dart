import 'dart:typed_data';

/// Synthesized mono audio.
class AudioClip {
  const AudioClip(this.samples, this.sampleRate);

  /// Samples in [-1, 1].
  final Float32List samples;
  final int sampleRate;

  Duration get duration => sampleRate == 0
      ? Duration.zero
      : Duration(microseconds: samples.length * 1000000 ~/ sampleRate);

  bool get isEmpty => samples.isEmpty;

  /// Without the silence the voice model leaves before and after the speech
  /// (Pocket TTS adds up to ~0.7 s), keeping [margin] around it, so the
  /// pauses between sentences are only the ones the app adds. Samples below
  /// [relativeThreshold] × the peak count as silence; an all-zero clip is
  /// returned as is.
  AudioClip trimSilence({
    double relativeThreshold = 0.02,
    Duration margin = const Duration(milliseconds: 40),
  }) {
    var peak = 0.0;
    for (final s in samples) {
      if (s.abs() > peak) peak = s.abs();
    }
    if (peak == 0) return this;
    final threshold = peak * relativeThreshold;
    var start = 0;
    while (samples[start].abs() <= threshold) {
      start++;
    }
    var end = samples.length;
    while (samples[end - 1].abs() <= threshold) {
      end--;
    }
    final keep = margin.inMicroseconds * sampleRate ~/ 1000000;
    start = (start - keep).clamp(0, samples.length);
    end = (end + keep).clamp(0, samples.length);
    if (start == 0 && end == samples.length) return this;
    return AudioClip(Float32List.sublistView(samples, start, end), sampleRate);
  }

  /// Reads a WAV file: 16-bit PCM or 32-bit float, mono (other channels are
  /// dropped).
  factory AudioClip.fromWav(Uint8List wav) {
    final data = ByteData.sublistView(wav);
    String tag(int at) => String.fromCharCodes(wav.sublist(at, at + 4));
    if (wav.length < 12 || tag(0) != 'RIFF' || tag(8) != 'WAVE') {
      throw const FormatException('Not a WAV file');
    }
    int? format, channels, rate, bits;
    var at = 12;
    while (at + 8 <= wav.length) {
      final id = tag(at);
      final size = data.getUint32(at + 4, Endian.little);
      final body = at + 8;
      if (id == 'fmt ') {
        format = data.getUint16(body, Endian.little);
        channels = data.getUint16(body + 2, Endian.little);
        rate = data.getUint32(body + 4, Endian.little);
        bits = data.getUint16(body + 14, Endian.little);
        if (format == 0xFFFE && size >= 26) {
          format = data.getUint16(body + 24, Endian.little); // extensible
        }
      } else if (id == 'data') {
        if (format == null) break;
        final frame = channels! * bits! ~/ 8;
        final n = (size.clamp(0, wav.length - body)) ~/ frame;
        final out = Float32List(n);
        for (var i = 0; i < n; i++) {
          final o = body + i * frame;
          out[i] = switch ((format, bits)) {
            (1, 16) => data.getInt16(o, Endian.little) / 32768,
            (3, 32) => data.getFloat32(o, Endian.little),
            _ => throw FormatException('Unsupported WAV: $format/$bits bits'),
          };
        }
        return AudioClip(out, rate!);
      }
      at = body + size + (size & 1);
    }
    throw const FormatException('WAV file without audio data');
  }

  /// 16-bit PCM WAV file bytes.
  Uint8List toWav() {
    final dataLength = samples.length * 2;
    final bytes = ByteData(44 + dataLength);
    void ascii(int offset, String s) {
      for (var i = 0; i < s.length; i++) {
        bytes.setUint8(offset + i, s.codeUnitAt(i));
      }
    }

    ascii(0, 'RIFF');
    bytes.setUint32(4, 36 + dataLength, Endian.little);
    ascii(8, 'WAVE');
    ascii(12, 'fmt ');
    bytes.setUint32(16, 16, Endian.little); // fmt chunk size
    bytes.setUint16(20, 1, Endian.little); // PCM
    bytes.setUint16(22, 1, Endian.little); // mono
    bytes.setUint32(24, sampleRate, Endian.little);
    bytes.setUint32(28, sampleRate * 2, Endian.little); // byte rate
    bytes.setUint16(32, 2, Endian.little); // block align
    bytes.setUint16(34, 16, Endian.little); // bits per sample
    ascii(36, 'data');
    bytes.setUint32(40, dataLength, Endian.little);
    var offset = 44;
    for (final s in samples) {
      final v = (s.clamp(-1.0, 1.0) * 32767).round();
      bytes.setInt16(offset, v, Endian.little);
      offset += 2;
    }
    return bytes.buffer.asUint8List();
  }
}
