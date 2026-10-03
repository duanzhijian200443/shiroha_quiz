/// Safe failures shared by the bounded Home Training V3 public contracts.
enum HomeTrainingFailure {
  notFound,
  unavailable,
  stale,
  invalidInput,
  conflict
}

sealed class HomeTrainingResult<T> {
  const HomeTrainingResult();
}

final class HomeTrainingSuccess<T> extends HomeTrainingResult<T> {
  const HomeTrainingSuccess(this.value);
  final T value;
}

/// Contains only a fixed code, never a storage/provider cause or raw message.
final class HomeTrainingFailed<T> extends HomeTrainingResult<T> {
  const HomeTrainingFailed(this.failure);
  final HomeTrainingFailure failure;
}

/// Successful command acknowledgement without a fabricated data snapshot.
final class HomeTrainingUnit {
  const HomeTrainingUnit();
}

/// Safe construction failure for malformed public contract values.
final class HomeTrainingContractException implements Exception {
  const HomeTrainingContractException(this.failure);
  final HomeTrainingFailure failure;

  @override
  String toString() => 'HomeTrainingContractException(${failure.name})';
}

void requireHomeTrainingInput(bool valid) {
  if (!valid) {
    throw const HomeTrainingContractException(HomeTrainingFailure.invalidInput);
  }
}
