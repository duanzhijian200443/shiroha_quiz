#include "p256_key_codec.h"
#include <cstring>

namespace {
constexpr uint8_t algorithm[] = {0x30,0x13,0x06,0x07,0x2a,0x86,0x48,
  0xce,0x3d,0x02,0x01,0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07};
constexpr uint8_t curve[] = {0x06,0x08,0x2a,0x86,0x48,0xce,0x3d,0x03,0x01,0x07};
constexpr uint8_t order[] = {0xff,0xff,0xff,0xff,0x00,0x00,0x00,0x00,
  0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xbc,0xe6,0xfa,0xad,0xa7,
  0x17,0x9e,0x84,0xf3,0xb9,0xca,0xc2,0xfc,0x63,0x25,0x51};
struct Reader {
  const uint8_t* p;
  size_t remaining;
  bool literal(const uint8_t* bytes, size_t length) noexcept {
    if (remaining < length || std::memcmp(p,bytes,length) != 0) return false;
    p += length; remaining -= length; return true;
  }
  bool field(uint8_t tag, Reader* child) noexcept {
    if (remaining < 2 || *p != tag) return false;
    size_t header = 2, length = p[1];
    if (length & 0x80) {
      // Every supported key is <=256 bytes, hence at most one length octet.
      if (length != 0x81 || remaining < 3 || p[2] < 128) return false;
      header = 3; length = p[2];
    }
    if (length > remaining-header) return false;
    *child = {p+header,length}; p += header+length; remaining -= header+length;
    return true;
  }
};
}
namespace shiroha_native {
bool p256_scalar_valid(const uint8_t* scalar) noexcept {
  bool nonzero = false;
  for (size_t i=0;i<32;++i) nonzero = nonzero || scalar[i] != 0;
  return nonzero && std::memcmp(scalar,order,32)<0;
}
bool encode_p256_pkcs8(const uint8_t* scalar, const uint8_t* point,
                       uint8_t* output, size_t capacity,
                       size_t* written) noexcept {
  *written = 0;
  if (capacity < 138 || point[0] != 4 || !p256_scalar_valid(scalar)) return false;
  size_t offset = 0;
  const auto add = [&](const uint8_t* bytes,size_t count) noexcept {
    std::memcpy(output+offset,bytes,count); offset += count;
  };
  const uint8_t outer[] = {0x30,0x81,0x87,0x02,0x01,0x00};
  const uint8_t inner[] = {0x04,0x6d,0x30,0x6b,0x02,0x01,0x01,0x04,0x20};
  const uint8_t public_field[] = {0xa1,0x44,0x03,0x42,0x00};
  add(outer,sizeof(outer)); add(algorithm,sizeof(algorithm));
  add(inner,sizeof(inner)); add(scalar,32); add(public_field,sizeof(public_field));
  add(point,65); *written = offset; return true;
}
bool decode_p256_pkcs8(const uint8_t* input, size_t length,
                       const uint8_t* point, uint8_t* scalar) noexcept {
  if (!input || length>256 || point[0]!=4) return false;
  Reader top{input,length}, outer{}, key_octets{}, key{}, value{};
  const uint8_t version0[] = {0x02,0x01,0x00};
  const uint8_t version1[] = {0x02,0x01,0x01};
  if (!top.field(0x30,&outer) || top.remaining ||
      !outer.literal(version0,sizeof(version0)) ||
      !outer.literal(algorithm,sizeof(algorithm)) ||
      !outer.field(0x04,&key_octets) || outer.remaining ||
      !key_octets.field(0x30,&key) || key_octets.remaining ||
      !key.literal(version1,sizeof(version1)) || !key.field(0x04,&value) ||
      value.remaining!=32 || !p256_scalar_valid(value.p)) return false;
  const auto* private_scalar = value.p;
  if (key.remaining && key.p[0]==0xa0) {
    Reader parameters{};
    if (!key.field(0xa0,&parameters) ||
        !parameters.literal(curve,sizeof(curve)) || parameters.remaining) return false;
  }
  if (key.remaining && key.p[0]==0xa1) {
    Reader public_field{}, bits{};
    if (!key.field(0xa1,&public_field) || !public_field.field(0x03,&bits) ||
        public_field.remaining || bits.remaining!=66 || bits.p[0]!=0 ||
        std::memcmp(bits.p+1,point,65)!=0) return false;
  }
  if (key.remaining) return false;
  std::memcpy(scalar,private_scalar,32); return true;
}
}
