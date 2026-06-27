class OcrDocument {
  const OcrDocument({
    required this.sourceName,
    required this.pages,
    required this.markdown,
    required this.rawResponses,
    required this.usage,
  });

  final String sourceName;
  final List<OcrPage> pages;
  final String markdown;
  final List<Map<String, dynamic>> rawResponses;
  final Map<String, dynamic> usage;

  bool get hasUsableBlocks => pages
      .any((page) => page.blocks.any((block) => block.text.trim().isNotEmpty));

  List<OcrBlock> get flattenedBlocks {
    final blocks = <OcrBlock>[];
    for (final page in pages) {
      blocks.addAll(page.blocks);
    }
    blocks.sort((a, b) {
      final pageCompare = a.pageIndex.compareTo(b.pageIndex);
      if (pageCompare != 0) return pageCompare;
      return a.readingOrder.compareTo(b.readingOrder);
    });
    return blocks;
  }

  Map<String, dynamic> toDiagnostics() {
    return {
      'sourceName': sourceName,
      'pageCount': pages.length,
      'blockCount': flattenedBlocks.length,
      'hasMarkdown': markdown.trim().isNotEmpty,
      'usage': usage,
      'pages': pages.map((page) => page.toDiagnostics()).toList(),
    };
  }

  static OcrDocument fromLayoutParsingResponse(
    Map<String, dynamic> response, {
    required String sourceName,
    int pageOffset = 0,
  }) {
    final markdown = _readString(response['md_results']);
    final details = response['layout_details'];
    final pageInfos = _readPageInfos(response['data_info']);
    final pages = <OcrPage>[];

    final pageDetails = _normalizePageDetails(details);
    for (var pageIdx = 0; pageIdx < pageDetails.length; pageIdx++) {
      final pageIndex = pageOffset + pageIdx + 1;
      final info = pageIdx < pageInfos.length ? pageInfos[pageIdx] : null;
      final blocks = <OcrBlock>[];
      final entries = pageDetails[pageIdx];

      for (var order = 0; order < entries.length; order++) {
        final entry = entries[order];
        final text = _readString(entry['content']);
        if (text.trim().isEmpty) continue;

        final rawIndex = _readInt(entry['index']) ?? order + 1;
        blocks.add(
          OcrBlock(
            blockId:
                'p${pageIndex.toString().padLeft(3, '0')}_b${rawIndex.toString().padLeft(4, '0')}',
            pageIndex: pageIndex,
            type: _readString(entry['label'], fallback: 'text'),
            text: text,
            bbox: _readBbox(entry['bbox_2d']),
            readingOrder: order,
            confidence: _readDouble(entry['confidence']),
            width: _readInt(entry['width']) ?? info?.width,
            height: _readInt(entry['height']) ?? info?.height,
            raw: Map<String, dynamic>.from(entry),
          ),
        );
      }

      pages.add(
        OcrPage(
          pageIndex: pageIndex,
          width: info?.width,
          height: info?.height,
          blocks: blocks,
        ),
      );
    }

    if (pages.isEmpty && markdown.trim().isNotEmpty) {
      pages.add(_fallbackMarkdownPage(markdown, pageOffset + 1));
    }

    return OcrDocument(
      sourceName: sourceName,
      pages: pages,
      markdown: markdown,
      rawResponses: [response],
      usage: _readMap(response['usage']),
    );
  }

  static OcrDocument merge({
    required String sourceName,
    required List<OcrDocument> chunks,
  }) {
    final pages = <OcrPage>[];
    final markdownParts = <String>[];
    final rawResponses = <Map<String, dynamic>>[];
    final usage = <String, dynamic>{};

    for (final chunk in chunks) {
      pages.addAll(chunk.pages);
      if (chunk.markdown.trim().isNotEmpty) {
        markdownParts.add(chunk.markdown.trim());
      }
      rawResponses.addAll(chunk.rawResponses);
      _mergeUsage(usage, chunk.usage);
    }

    pages.sort((a, b) => a.pageIndex.compareTo(b.pageIndex));
    return OcrDocument(
      sourceName: sourceName,
      pages: pages,
      markdown: markdownParts.join('\n\n'),
      rawResponses: rawResponses,
      usage: usage,
    );
  }

  static OcrPage _fallbackMarkdownPage(String markdown, int pageIndex) {
    final blocks = <OcrBlock>[];
    final paragraphs = markdown
        .split(RegExp(r'\n{2,}'))
        .map((part) => part.trim())
        .where((part) => part.isNotEmpty)
        .toList();

    for (var i = 0; i < paragraphs.length; i++) {
      blocks.add(
        OcrBlock(
          blockId:
              'p${pageIndex.toString().padLeft(3, '0')}_md${(i + 1).toString().padLeft(4, '0')}',
          pageIndex: pageIndex,
          type: 'text',
          text: paragraphs[i],
          bbox: const [],
          readingOrder: i,
          raw: {'source': 'md_results'},
        ),
      );
    }

    return OcrPage(pageIndex: pageIndex, blocks: blocks);
  }
}

class OcrPage {
  const OcrPage({
    required this.pageIndex,
    required this.blocks,
    this.width,
    this.height,
  });

  final int pageIndex;
  final int? width;
  final int? height;
  final List<OcrBlock> blocks;

  Map<String, dynamic> toDiagnostics() {
    return {
      'pageIndex': pageIndex,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      'blockCount': blocks.length,
    };
  }
}

class OcrBlock {
  const OcrBlock({
    required this.blockId,
    required this.pageIndex,
    required this.type,
    required this.text,
    required this.bbox,
    required this.readingOrder,
    this.confidence,
    this.width,
    this.height,
    this.raw = const {},
  });

  final String blockId;
  final int pageIndex;
  final String type;
  final String text;
  final List<double> bbox;
  final int readingOrder;
  final double? confidence;
  final int? width;
  final int? height;
  final Map<String, dynamic> raw;

  OcrBlock copyWith({
    String? blockId,
    String? text,
    int? readingOrder,
    Map<String, dynamic>? raw,
  }) {
    return OcrBlock(
      blockId: blockId ?? this.blockId,
      pageIndex: pageIndex,
      type: type,
      text: text ?? this.text,
      bbox: bbox,
      readingOrder: readingOrder ?? this.readingOrder,
      confidence: confidence,
      width: width,
      height: height,
      raw: raw ?? this.raw,
    );
  }
}

class _PageInfo {
  const _PageInfo({this.width, this.height});

  final int? width;
  final int? height;
}

String _readString(dynamic value, {String fallback = ''}) {
  final text = value?.toString() ?? '';
  return text.isEmpty ? fallback : text;
}

int? _readInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim());
  return null;
}

double? _readDouble(dynamic value) {
  if (value is double) return value;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value.trim());
  return null;
}

Map<String, dynamic> _readMap(dynamic value) {
  if (value is Map) return Map<String, dynamic>.from(value);
  return const {};
}

List<double> _readBbox(dynamic value) {
  if (value is! List) return const [];
  final result = <double>[];
  for (final item in value.take(4)) {
    final parsed = _readDouble(item);
    if (parsed == null) return const [];
    result.add(parsed);
  }
  return result.length == 4 ? List.unmodifiable(result) : const [];
}

List<List<Map<String, dynamic>>> _normalizePageDetails(dynamic details) {
  if (details is! List || details.isEmpty) return const [];

  if (details.every((entry) => entry is Map)) {
    return [
      details.map((entry) => Map<String, dynamic>.from(entry as Map)).toList(),
    ];
  }

  final pages = <List<Map<String, dynamic>>>[];
  for (final page in details) {
    if (page is! List) {
      pages.add(const []);
      continue;
    }
    pages.add(
      page
          .whereType<Map>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(),
    );
  }
  return pages;
}

List<_PageInfo> _readPageInfos(dynamic dataInfo) {
  if (dataInfo is! Map) return const [];
  final pages = dataInfo['pages'];
  if (pages is! List) return const [];

  return pages.map((page) {
    if (page is! Map) return const _PageInfo();
    return _PageInfo(
      width: _readInt(page['width']),
      height: _readInt(page['height']),
    );
  }).toList(growable: false);
}

void _mergeUsage(Map<String, dynamic> target, Map<String, dynamic> source) {
  for (final entry in source.entries) {
    final current = target[entry.key];
    if (current is num && entry.value is num) {
      target[entry.key] = current + (entry.value as num);
    } else if (!target.containsKey(entry.key)) {
      target[entry.key] = entry.value;
    }
  }
}
