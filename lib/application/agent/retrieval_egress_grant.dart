library;

final class RetrievalEgressApproval {
  RetrievalEgressApproval(Iterable<String> approvedFileIds)
      : approvedFileIds =
            List<String>.unmodifiable({...approvedFileIds}.toList()..sort());
  final List<String> approvedFileIds;
}

final class RetrievalEgressGrant {
  RetrievalEgressGrant(
      {required this.agentTurnRequestId,
      required this.conversationId,
      required this.sourceUserMessageId,
      required this.providerProfileId,
      required Iterable<String> approvedFileIds})
      : approvedFileIds =
            List<String>.unmodifiable({...approvedFileIds}.toList()..sort());
  final String agentTurnRequestId;
  final String conversationId;
  final String sourceUserMessageId;
  final String providerProfileId;
  final List<String> approvedFileIds;

  bool permits(
      {required String turnRequestId,
      required String conversationId,
      required String sourceUserMessageId,
      required String providerProfileId,
      required Iterable<String> currentFileIds}) {
    if (turnRequestId != agentTurnRequestId ||
        conversationId != this.conversationId ||
        sourceUserMessageId != this.sourceUserMessageId ||
        providerProfileId != this.providerProfileId) {
      return false;
    }
    final current = currentFileIds.toSet();
    return approvedFileIds.isNotEmpty &&
        approvedFileIds.every(current.contains);
  }
}
