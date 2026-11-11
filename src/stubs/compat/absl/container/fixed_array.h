// Shadows src/vendor/robotstxt/compat/absl/container/fixed_array.h (stubs/dune
// searches this directory first). That shim is a std::vector, so
// RobotsMatchStrategy::Matches heap-allocates and zero-fills on every rule it
// tests. Like Abseil's FixedArray, this keeps up to 256 bytes inline and
// leaves trivial elements uninitialised, which is what robots.cc was written
// against.

#ifndef CONTEXTUAL_ABSL_CONTAINER_FIXED_ARRAY_H_
#define CONTEXTUAL_ABSL_CONTAINER_FIXED_ARRAY_H_

#include <cstddef>

namespace absl {

template <typename T, std::size_t N = (256 / sizeof(T) > 0 ? 256 / sizeof(T) : 1)>
class FixedArray {
 public:
  explicit FixedArray(std::size_t n) : size_(n), data_(n <= N ? inline_ : new T[n]) {}
  ~FixedArray() {
    if (data_ != inline_) delete[] data_;
  }
  FixedArray(const FixedArray&) = delete;
  FixedArray& operator=(const FixedArray&) = delete;

  T& operator[](std::size_t i) { return data_[i]; }
  const T& operator[](std::size_t i) const { return data_[i]; }
  T* data() { return data_; }
  const T* data() const { return data_; }
  std::size_t size() const { return size_; }
  T* begin() { return data_; }
  T* end() { return data_ + size_; }

 private:
  std::size_t size_;
  T* data_;
  T inline_[N];
};

}  // namespace absl

#endif  // CONTEXTUAL_ABSL_CONTAINER_FIXED_ARRAY_H_
