#if defined(ABSL_STRINGS_CORD_H_) && \
    defined(ABSL_CONTAINER_INTERNAL_HASH_FUNCTION_DEFAULTS_H_)

#ifndef ABSL_CONTAINER_INTERNAL_HASH_FUNCTION_CORD_H_
#define ABSL_CONTAINER_INTERNAL_HASH_FUNCTION_CORD_H_

namespace container_internal {

inline size_t StringHash::operator()(const absl::Cord& v) const {
  return absl::Hash<absl::Cord>{}(v);
}
inline bool StringEq::operator()(const absl::Cord& lhs, const Cord& rhs) const {
  return lhs == rhs;
}
inline bool StringEq::operator()(const absl::Cord& lhs,
                                 absl::string_view rhs) const {
  return lhs == rhs;
}
inline bool StringEq::operator()(absl::string_view lhs,
                                 const absl::Cord& rhs) const {
  return lhs == rhs;
}

}  // namespace container_internal

#endif  // ABSL_CONTAINER_INTERNAL_HASH_FUNCTION_CORD_H_
#endif
