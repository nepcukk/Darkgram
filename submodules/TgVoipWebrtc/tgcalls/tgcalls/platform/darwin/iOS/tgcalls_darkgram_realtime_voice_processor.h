#ifndef TGCALLS_DARKGRAM_REALTIME_VOICE_PROCESSOR_H_
#define TGCALLS_DARKGRAM_REALTIME_VOICE_PROCESSOR_H_

#include <atomic>
#include <cstdint>
#include <vector>

namespace webrtc {
namespace tgcalls_ios_adm {

class DarkgramRealtimeVoiceProcessor {
 public:
  DarkgramRealtimeVoiceProcessor();

  void SetConfiguration(bool enabled, int32_t pitch_cents, int32_t output_gain_percent);
  void Process(int16_t* samples, size_t count);

 private:
  void ResetState();
  void ApplyGain(int16_t* samples, size_t count, float gain);
  static int16_t ClampToInt16(float value);

  std::atomic<bool> enabled_;
  std::atomic<int32_t> pitch_cents_;
  std::atomic<int32_t> output_gain_percent_;
  std::atomic<uint32_t> generation_;

  uint32_t applied_generation_ = 0;
  std::vector<float> buffered_samples_;
  double read_position_ = 0.0;
  bool primed_ = false;
};

}  // namespace tgcalls_ios_adm
}  // namespace webrtc

#endif  // TGCALLS_DARKGRAM_REALTIME_VOICE_PROCESSOR_H_
