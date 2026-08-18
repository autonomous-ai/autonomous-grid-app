/// The audio format the panel captures in, and the container the transcriber
/// reads.
///
/// A byte format agreed with something outside this repo on both ends — the
/// device sends the samples, `grid stt transcribe` reads the file — which is
/// why it sits beside the framing rather than inside the panel feature, and why
/// it is checked by a test instead of by ear. A WAV header that is wrong by
/// four bytes does not sound wrong; it comes back as an empty transcript.
///
/// Free of Flutter, like the rest of this folder.
library;

import 'dart:typed_data';

/// What the panel's microphone runs at (`docs/protocol.md` §2, Voice).
const int kPanelVoiceSampleRate = 16000;

/// One channel: the panel has one microphone.
const int kPanelVoiceChannels = 1;

/// Sixteen bits per sample, which is what both ends of this already speak —
/// the device sends little-endian 16-bit PCM and WAV stores little-endian
/// 16-bit PCM, so the samples are copied rather than converted. Any conversion
/// here would be a second place for the two to disagree.
const int kPanelVoiceBitsPerSample = 16;

/// A canonical WAV header: RIFF/WAVE, one `fmt ` chunk, one `data` chunk.
const int kWavHeaderBytes = 44;

/// Wrap raw PCM in a WAV container.
///
/// [pcm] is taken exactly as it came off the wire: little-endian, signed,
/// 16-bit, [kPanelVoiceChannels] channel. Nothing is resampled — the panel is
/// told what rate to capture at by the protocol, and quietly resampling here
/// would hide a device that had stopped honouring it.
///
/// A trailing odd byte is dropped. Half a sample is not a sample, and keeping
/// it would shift every following one by a byte, which does not sound like
/// truncation — it sounds like static.
Uint8List wavFromPcm16(
  List<int> pcm, {
  int sampleRate = kPanelVoiceSampleRate,
  int channels = kPanelVoiceChannels,
}) {
  final blockAlign = channels * kPanelVoiceBitsPerSample ~/ 8;
  final dataBytes = pcm.length - pcm.length % blockAlign;
  final out = Uint8List(kWavHeaderBytes + dataBytes);
  final header = ByteData.sublistView(out, 0, kWavHeaderBytes);

  _tag(out, 0, 'RIFF');
  // Everything after this field, which is the whole file bar the first eight
  // bytes.
  header.setUint32(4, kWavHeaderBytes - 8 + dataBytes, Endian.little);
  _tag(out, 8, 'WAVE');
  _tag(out, 12, 'fmt ');
  // 16 is the size of a PCM `fmt ` chunk; anything larger announces a codec.
  header.setUint32(16, 16, Endian.little);
  // 1 is uncompressed PCM.
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, channels, Endian.little);
  header.setUint32(24, sampleRate, Endian.little);
  header.setUint32(28, sampleRate * blockAlign, Endian.little);
  header.setUint16(32, blockAlign, Endian.little);
  header.setUint16(34, kPanelVoiceBitsPerSample, Endian.little);
  _tag(out, 36, 'data');
  header.setUint32(40, dataBytes, Endian.little);

  out.setRange(kWavHeaderBytes, kWavHeaderBytes + dataBytes, pcm);
  return out;
}

/// Write a four-character RIFF tag at [offset]. ASCII by definition, so the
/// code units are the bytes.
void _tag(Uint8List out, int offset, String tag) =>
    out.setRange(offset, offset + tag.length, tag.codeUnits);
