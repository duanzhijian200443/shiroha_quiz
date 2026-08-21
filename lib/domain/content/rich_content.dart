import 'content_node.dart';

final class RichContent {
  RichContent({required Iterable<ContentNode> nodes})
      : nodes = List<ContentNode>.unmodifiable(nodes);

  final List<ContentNode> nodes;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! RichContent || nodes.length != other.nodes.length) {
      return false;
    }
    for (var index = 0; index < nodes.length; index++) {
      if (nodes[index] != other.nodes[index]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(nodes);
}
