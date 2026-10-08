library;

import '../capabilities/capability.dart';
import 'retrieval.dart';
import 'retrieval_ports.dart';
import 'retrieval_service.dart';

final class RetrieveFileContentInput {
  RetrieveFileContentInput(
      {required this.query, required Iterable<String> fileIds, this.limit = 8})
      : fileIds = List.unmodifiable(fileIds);
  final String query;
  final List<String> fileIds;
  final int limit;
}

const retrieveFileContent =
    CapabilityId<RetrieveFileContentInput, RetrievalResult>(
        'retrieve_file_content');

bool retrievalContextPermits(CapabilityContext context) =>
    context.principal == CapabilityPrincipal.builtInAgent &&
    context.retrievalGrant != null &&
    context.retrievalGrant!.permits(
        turnRequestId: context.turnRequestId ?? '',
        conversationId: context.sourceConversationId ?? '',
        sourceUserMessageId: context.sourceMessageId ?? '',
        providerProfileId: context.providerProfileId ?? '',
        currentFileIds: context.currentFileIds);

CapabilityDefinition<RetrieveFileContentInput, RetrievalResult>
    retrievalCapability(RetrievalService service) => CapabilityDefinition(
          id: retrieveFileContent,
          permission: CapabilityPermission.read,
          permittedEffects: const [
            CapabilityEffect.none,
            CapabilityEffect.derivedCache
          ],
          semantics: CapabilityExecutionSemantics.repeatableRead,
          authorize: (input, context) async =>
              retrievalContextPermits(context) &&
              input.fileIds.isNotEmpty &&
              input.fileIds.length <= RetrievalService.maxFiles &&
              input.fileIds.every((id) =>
                  context.retrievalGrant!.approvedFileIds.contains(id) &&
                  context.currentFileIds.contains(id)) &&
              context.serializationAllowed != null &&
              // The file snapshot cannot prove current authorization. The
              // trusted live gate also checks scope, source turn and recipient.
              await context.serializationAllowed!(),
          release: (_, context) async =>
              retrievalContextPermits(context) &&
              await context.serializationAllowed!(),
          handler: CapabilityHandler((input, _, confirmed) async {
            final evidence = RetrievalExecutionEvidence(
                onDerivedCacheCommitted: () =>
                    confirmed.confirm(CapabilityEffect.derivedCache));
            CapabilityEffect? effect() => evidence.effectKnown
                ? (evidence.derivedCacheWritten
                    ? CapabilityEffect.derivedCache
                    : CapabilityEffect.none)
                : (evidence.derivedCacheWritten
                    ? CapabilityEffect.derivedCache
                    : null);
            try {
              final result = await service.retrieve(
                  scope: RetrievalFilesScope(input.fileIds),
                  query: input.query,
                  limit: input.limit,
                  executionEvidence: evidence);
              return CapabilityEvidence(
                  output: result,
                  status: evidence.effectKnown
                      ? CapabilityExecutionStatus.completed
                      : CapabilityExecutionStatus.outcomeUnknown,
                  effect: effect());
            } on RetrievalException catch (error) {
              return CapabilityEvidence(
                  failure: switch (error.failure) {
                    RetrievalFailure.invalidRequest =>
                      CapabilityFailure.invalidRequest,
                    RetrievalFailure.accessDenied =>
                      CapabilityFailure.retrievalAccessDenied,
                    RetrievalFailure.scopeEmpty =>
                      CapabilityFailure.retrievalScopeEmpty,
                    RetrievalFailure.scopeUnavailable =>
                      CapabilityFailure.retrievalScopeUnavailable,
                    RetrievalFailure.sourceChanged =>
                      CapabilityFailure.retrievalSourceChanged,
                    RetrievalFailure.temporarilyUnavailable =>
                      CapabilityFailure.retrievalTemporarilyUnavailable,
                    RetrievalFailure.internalError =>
                      CapabilityFailure.retrievalInternalError,
                  },
                  status: evidence.effectKnown && !evidence.derivedCacheWritten
                      ? CapabilityExecutionStatus.failedWithoutEffect
                      : CapabilityExecutionStatus.outcomeUnknown,
                  effect: effect());
            } catch (_) {
              return CapabilityEvidence(
                  failure: CapabilityFailure.internalError,
                  status: CapabilityExecutionStatus.outcomeUnknown,
                  effect: effect());
            }
          }),
        );
