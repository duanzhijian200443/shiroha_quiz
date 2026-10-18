#ifndef SHIROHA_L1_TEMPORARY_HANDLE_H_
#define SHIROHA_L1_TEMPORARY_HANDLE_H_
#include <cstdint>
namespace shiroha_l1_crypto {
enum class TemporaryOwner { token_reader, token_validator, image_reader };
// Sole-owner close accounting shared by the real token leaves and Fake tests.
// Exception unwinding attempts the same owner's close once; the exception still
// rejects measurement. Normal callers MUST check close_as() before success.
class TemporaryHandle final {
public:
  using Close = bool (*)(uintptr_t) noexcept;
  TemporaryHandle(TemporaryOwner owner, uintptr_t value, Close close) noexcept
      : owner_(owner), value_(value), close_(close) {}
  TemporaryHandle(const TemporaryHandle &) = delete;
  TemporaryHandle &operator=(const TemporaryHandle &) = delete;
  ~TemporaryHandle() {
    if (!attempted_)
      close_as(owner_);
  }
  bool close_as(TemporaryOwner caller) noexcept {
    if (caller != owner_ || attempted_ || !value_ || !close_)
      return false;
    attempted_ = true;
    closed_ = close_(value_);
    return closed_;
  }
  bool unknown() const noexcept { return attempted_ && !closed_; }

private:
  const TemporaryOwner owner_;
  const uintptr_t value_;
  const Close close_;
  bool attempted_ = false, closed_ = false;
};
} // namespace shiroha_l1_crypto
#endif
