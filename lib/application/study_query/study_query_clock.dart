/// Injectable clock seam for deterministic study query tests.
library;

/// Source of the current UTC instant for the read-only query layer.
abstract interface class StudyClock {
  DateTime nowUtc();
}

/// Default clock backed by the system clock.
final class SystemStudyClock implements StudyClock {
  const SystemStudyClock();

  @override
  DateTime nowUtc() => DateTime.now().toUtc();
}
