// Default-disabled standalone Dart AOT source entry. Compilation/packaging and
// real process startup require their own authorization. No App composition,
// Owner, issuer, Store, listener, migration or business writer is created here.
import 'dart:io';
import 'package:shiroha_quiz/data/external/windows_release_candidate.dart';

// Pins the candidate transport dependency for transitive source auditing.
// Exporting a type neither constructs a Bridge nor starts a connection.
export 'package:shiroha_quiz/data/external/windows_tls_transport.dart'
    show WindowsTlsBridge;

// Explicit local control interface only. main remains default-disabled; a future
// admitted composition must supply the original P27 owner and independent App
// public-input readers, and bind both confirmations to human actions.
export 'package:shiroha_quiz/data/external/windows_pairing.dart'
    show
        WindowsBridgeOnboarding,
        WindowsPairingHandoff,
        BridgeOnboardingDisplay,
        BridgeAppPublicMaterial;

void main(List<String> arguments) {
  if (!WindowsExternalReleaseCandidate.acceptsArguments(arguments)) {
    stderr.writeln('invalidBridgeArguments');
    exitCode = 64;
    return;
  }
  stderr.writeln('externalHostActivationPending');
  exitCode = 78;
}
