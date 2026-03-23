#include "platform/darwin/iOS/tgcalls_darkgram_realtime_voice_processor.h"

#include <algorithm>
#include <cmath>

namespace webrtc {
namespace tgcalls_ios_adm {

DarkgramRealtimeVoiceProcessor::DarkgramRealtimeVoiceProcessor()
    : enabled_(false),
      pitch_cents_(0),
      output_gain_percent_(100),
      generation_(1) {
}

void DarkgramRealtimeVoiceProcessor::SetConfiguration(bool enabled, int32_t pitch_cents, int32_t output_gain_percent) {
  enabled_.store(enabled, std::memory_order_relaxed);
  pitch_cents_.store(std::clamp(pitch_cents, static_cast<int32_t>(-1200), static_cast<int32_t>(1200)), std::memory_order_relaxed);
  output_gain_percent_.store(std::clamp(output_gain_percent, static_cast<int32_t>(25), static_cast<int32_t>(200)), std::memory_order_relaxed);
  generation_.fetch_add(1, std::memory_order_relaxed);
}

void DarkgramRealtimeVoiceProcessor::ResetState() {
  buffered_samples_.clear();
  read_position_ = 0.0;
  primed_ = false;
}

int16_t DarkgramRealtimeVoiceProcessor::ClampToInt16(float value) {
  value = std::clamp(value, -32768.0f, 32767.0f);
  return static_cast<int16_t>(std::lrintf(value));
}

void DarkgramRealtimeVoiceProcessor::ApplyGain(int16_t* samples, size_t count, float gain) {
  if (gain == 1.0f) {
    return;
  }
  for (size_t i = 0; i < count; ++i) {
    samples[i] = ClampToInt16(static_cast<float>(samples[i]) * gain);
  }
}

void DarkgramRealtimeVoiceProcessor::Process(int16_t* samples, size_t count) {
  if (samples == nullptr || count == 0) {
    return;
  }

  const uint32_t generation = generation_.load(std::memory_order_relaxed);
  if (generation != applied_generation_) {
    ResetState();
    applied_generation_ = generation;
  }

  const bool enabled = enabled_.load(std::memory_order_relaxed);
  if (!enabled) {
    return;
  }

  const int32_t pitch_cents = pitch_cents_.load(std::memory_order_relaxed);
  const int32_t output_gain_percent = output_gain_percent_.load(std::memory_order_relaxed);
  const float gain = static_cast<float>(output_gain_percent) / 100.0f;
  if (pitch_cents == 0) {
    ApplyGain(samples, count, gain);
    return;
  }

  double desired_factor = std::pow(2.0, static_cast<double>(pitch_cents) / 1200.0);
  desired_factor = std::clamp(desired_factor, 0.5, 2.0);

  buffered_samples_.reserve(buffered_samples_.size() + count + 2);
  for (size_t i = 0; i < count; ++i) {
    buffered_samples_.push_back(static_cast<float>(samples[i]));
  }

  size_t required_backlog = 64;
  if (desired_factor > 1.0) {
    required_backlog = std::max(required_backlog, static_cast<size_t>(std::ceil((desired_factor - 1.0) * static_cast<double>(count))) + 64);
  }
  const size_t minimum_buffered_samples = required_backlog + count + 2;
  if (!primed_) {
    if (buffered_samples_.size() < minimum_buffered_samples) {
      ApplyGain(samples, count, gain);
      return;
    }
    primed_ = true;
  }

  const double available_for_output = static_cast<double>(buffered_samples_.size()) - static_cast<double>(required_backlog) - 2.0 - read_position_;
  if (available_for_output <= 1.0) {
    ApplyGain(samples, count, gain);
    return;
  }

  double actual_factor = std::min(desired_factor, available_for_output / static_cast<double>(std::max<size_t>(1, count)));
  actual_factor = std::clamp(actual_factor, 0.5, 2.0);

  std::vector<int16_t> transformed_samples;
  transformed_samples.resize(count);
  for (size_t i = 0; i < count; ++i) {
    if (buffered_samples_.size() < 2) {
      transformed_samples[i] = ClampToInt16(static_cast<float>(samples[i]) * gain);
      continue;
    }

    const double max_index = static_cast<double>(buffered_samples_.size() - 2);
    if (read_position_ > max_index) {
      read_position_ = max_index;
    }

    const size_t index = static_cast<size_t>(read_position_);
    const double fraction = read_position_ - static_cast<double>(index);
    const float sample_a = buffered_samples_[index];
    const float sample_b = buffered_samples_[index + 1];
    const float rendered_sample = sample_a + (sample_b - sample_a) * static_cast<float>(fraction);
    transformed_samples[i] = ClampToInt16(rendered_sample * gain);

    read_position_ += actual_factor;
  }

  std::copy(transformed_samples.begin(), transformed_samples.end(), samples);

  const size_t consumed_samples = static_cast<size_t>(std::floor(read_position_));
  if (consumed_samples > 0 && consumed_samples <= buffered_samples_.size()) {
    buffered_samples_.erase(buffered_samples_.begin(), buffered_samples_.begin() + static_cast<std::ptrdiff_t>(consumed_samples));
    read_position_ -= static_cast<double>(consumed_samples);
  }

  const size_t max_buffered_samples = std::max(minimum_buffered_samples * 4, count * static_cast<size_t>(8));
  if (buffered_samples_.size() > max_buffered_samples) {
    const size_t trim_count = buffered_samples_.size() - max_buffered_samples;
    buffered_samples_.erase(buffered_samples_.begin(), buffered_samples_.begin() + static_cast<std::ptrdiff_t>(trim_count));
    read_position_ = std::max(0.0, read_position_ - static_cast<double>(trim_count));
  }
}

}  // namespace tgcalls_ios_adm
}  // namespace webrtc
