import 'content_node.dart';

final class RichContent {
  RichContent({required Iterable<ContentNode> nodes})
      : nodes = List<ContentNode>.unmodifiable(nodes);

  final List<ContentNode> nodes;
}
