// P6 SV-C2: read-only in-app original source viewer.
//
// Consumes only the SV-C1 verified `SupplementalSourceInspection` value:
// originalBytes / displayName / mimeType. Never a path, storage key, or File.
// Opening this viewer is NOT source verification; no verifySource or
// verified/trusted state exists here.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;

import '../../application/supplemental_answers/supplemental_source_inspection.dart';

/// Fixed safe message for content that cannot be displayed. Never carries a
/// raw exception, path, key, or file content.
const String _unableToDisplayMessage = '无法显示原文件内容';

/// Fixed safe message for formats without an in-app original viewer.
const String _unsupportedFormatMessage = '当前格式暂不支持应用内原文查看，因此无法完成原文核验。';

/// Builds the interactive page surface for one already-opened PDF document.
///
/// [initialPage] is a 1-based presentation hint clamped by the caller, or null
/// when the caller explicitly does not claim any exact page.
typedef SupplementalPdfSurfaceViewBuilder = Widget Function(int? initialPage);

/// One prepared, read-only PDF surface bound to exact original bytes.
final class SupplementalPdfSurface {
  SupplementalPdfSurface({
    required this.pagesCount,
    required SupplementalPdfSurfaceViewBuilder buildView,
    required Future<void> Function() dispose,
  })  : _buildView = buildView,
        _dispose = dispose;

  /// Total page count of the opened document.
  final int pagesCount;

  final SupplementalPdfSurfaceViewBuilder _buildView;
  final Future<void> Function() _dispose;

  Widget buildView({int? initialPage}) => _buildView(initialPage);

  /// Releases the controller/document. Safe to call once.
  Future<void> dispose() => _dispose();
}

/// Presentation-only seam for opening original bytes as a PDF surface.
///
/// Implementations must open from memory only and own no verification
/// authority: they never mark a session verified, trusted, or reviewed.
typedef SupplementalPdfSurfaceOpener = Future<SupplementalPdfSurface> Function(
    Uint8List originalBytes);

/// Default [SupplementalPdfSurfaceOpener]: opens the exact original bytes in
/// memory through pdfx. No temp file, no path, no network, no OCR.
Future<SupplementalPdfSurface> openSupplementalPdfSurface(
  Uint8List originalBytes,
) =>
    openSupplementalPdfSurfaceFromDocument(
      pdfx.PdfDocument.openData(originalBytes),
    );

/// Builds the default read-only pdfx surface from one document future.
///
/// Presentation-only seam extension so tests can drive the real surface with
/// a fake document. The surface owns controller/document disposal and holds
/// no verification authority.
Future<SupplementalPdfSurface> openSupplementalPdfSurfaceFromDocument(
  Future<pdfx.PdfDocument> documentFuture,
) async {
  final pdfx.PdfDocument document = await documentFuture;
  pdfx.PdfController? controller;
  var disposed = false;

  Future<void> close() async {
    if (disposed) {
      return;
    }
    disposed = true;
    controller?.dispose();
    await document.close();
  }

  return SupplementalPdfSurface(
    pagesCount: document.pagesCount,
    buildView: (initialPage) {
      final resolvedPage =
          (initialPage ?? 1).clamp(1, document.pagesCount).toInt();
      controller ??= pdfx.PdfController(
        document: documentFuture,
        initialPage: resolvedPage,
      );
      return _PdfxPdfSurfacePage(
        controller: controller!,
        pagesCount: document.pagesCount,
      );
    },
    dispose: close,
  );
}

/// Read-only viewer for one verified supplemental original source.
class SupplementalSourceViewerScreen extends StatefulWidget {
  const SupplementalSourceViewerScreen({
    super.key,
    required this.inspection,
    this.pageHint,
    this.pdfSurfaceOpener = openSupplementalPdfSurface,
  });

  /// SV-C1 verified inspection; only originalBytes / displayName / mimeType
  /// are consumed.
  final SupplementalSourceInspection inspection;

  /// 1-based presentation hint. Null means the caller does not claim to know
  /// an exact page; the viewer never infers pages from any other signal.
  final int? pageHint;

  /// Injectable PDF surface seam for tests. No verification authority.
  final SupplementalPdfSurfaceOpener pdfSurfaceOpener;

  @override
  State<SupplementalSourceViewerScreen> createState() =>
      _SupplementalSourceViewerScreenState();
}

enum _ViewerPhase { resolving, pdf, text, image, unsupported, unable }

class _SupplementalSourceViewerScreenState
    extends State<SupplementalSourceViewerScreen> {
  _ViewerPhase _phase = _ViewerPhase.resolving;
  SupplementalPdfSurface? _pdfSurface;
  int? _pdfInitialPage;
  String? _decodedText;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void dispose() {
    final surface = _pdfSurface;
    _pdfSurface = null;
    if (surface != null) {
      unawaited(surface.dispose());
    }
    super.dispose();
  }

  Future<void> _resolve() async {
    final mimeType = widget.inspection.mimeType;
    if (mimeType == 'application/pdf') {
      await _resolvePdf();
    } else if (mimeType == 'text/plain' || mimeType == 'text/markdown') {
      _resolveText();
    } else if (mimeType.startsWith('image/')) {
      _phase = _ViewerPhase.image;
    } else {
      _phase = _ViewerPhase.unsupported;
    }
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _resolvePdf() async {
    final SupplementalPdfSurface surface;
    try {
      surface = await widget.pdfSurfaceOpener(_originalBytes());
    } catch (_) {
      // Fixed safe failure; parser/provider details are never surfaced.
      _phase = _ViewerPhase.unable;
      return;
    }
    if (!mounted) {
      await surface.dispose();
      return;
    }
    if (surface.pagesCount < 1) {
      await surface.dispose();
      _phase = _ViewerPhase.unable;
      return;
    }
    final hint = widget.pageHint;
    _pdfSurface = surface;
    _pdfInitialPage = hint?.clamp(1, surface.pagesCount).toInt();
    _phase = _ViewerPhase.pdf;
  }

  void _resolveText() {
    try {
      _decodedText = utf8.decode(widget.inspection.originalBytes);
    } on FormatException {
      _phase = _ViewerPhase.unable;
      return;
    }
    _phase = _ViewerPhase.text;
  }

  Uint8List _originalBytes() =>
      Uint8List.fromList(widget.inspection.originalBytes);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.inspection.displayName)),
      body: SafeArea(child: _buildBody(context)),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_phase) {
      case _ViewerPhase.resolving:
        return const Center(child: CircularProgressIndicator());
      case _ViewerPhase.pdf:
        return _pdfSurface!.buildView(initialPage: _pdfInitialPage);
      case _ViewerPhase.text:
        return SingleChildScrollView(
          key: const ValueKey<String>('supplemental-source-viewer-text'),
          padding: const EdgeInsets.all(16),
          child: SelectableText(_decodedText!),
        );
      case _ViewerPhase.image:
        return InteractiveViewer(
          key: const ValueKey<String>('supplemental-source-viewer-image'),
          maxScale: 8,
          child: Center(
            child: Image.memory(
              _originalBytes(),
              errorBuilder: (_, __, ___) =>
                  const _SafeMessageView(_unableToDisplayMessage),
            ),
          ),
        );
      case _ViewerPhase.unsupported:
        return const _SafeMessageView(_unsupportedFormatMessage);
      case _ViewerPhase.unable:
        return const _SafeMessageView(_unableToDisplayMessage);
    }
  }
}

class _SafeMessageView extends StatelessWidget {
  const _SafeMessageView(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          message,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _PdfxPdfSurfacePage extends StatefulWidget {
  const _PdfxPdfSurfacePage({
    required this.controller,
    required this.pagesCount,
  });

  final pdfx.PdfController controller;
  final int pagesCount;

  @override
  State<_PdfxPdfSurfacePage> createState() => _PdfxPdfSurfacePageState();
}

class _PdfxPdfSurfacePageState extends State<_PdfxPdfSurfacePage> {
  bool _documentLoaded = false;

  void _goToPage(int delta) {
    final current = widget.controller.page.clamp(1, widget.pagesCount).toInt();
    final target = (current + delta).clamp(1, widget.pagesCount).toInt();
    widget.controller.jumpToPage(target);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              key: const ValueKey<String>('supplemental-source-viewer-prev'),
              onPressed: _documentLoaded ? () => _goToPage(-1) : null,
              icon: const Icon(Icons.chevron_left),
            ),
            ValueListenableBuilder<int>(
              valueListenable: widget.controller.pageListenable,
              builder: (context, page, _) {
                final shown = page.clamp(1, widget.pagesCount).toInt();
                return Text('第 $shown / ${widget.pagesCount} 页');
              },
            ),
            IconButton(
              key: const ValueKey<String>('supplemental-source-viewer-next'),
              onPressed: _documentLoaded ? () => _goToPage(1) : null,
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        Expanded(
          child: pdfx.PdfView(
            controller: widget.controller,
            onDocumentLoaded: (_) {
              if (mounted) {
                setState(() => _documentLoaded = true);
              }
            },
            builders: pdfx.PdfViewBuilders<pdfx.DefaultBuilderOptions>(
              options: const pdfx.DefaultBuilderOptions(),
              errorBuilder: _pdfSafeErrorBuilder,
              pageBuilder: _pdfSafePageBuilder,
            ),
          ),
        ),
      ],
    );
  }
}

Widget _pdfSafeErrorBuilder(BuildContext context, Exception error) =>
    const Center(child: Text(_unableToDisplayMessage));

/// Page-level safe surface. PdfViewBuilders.errorBuilder only covers document
/// loading; after the document is already open, per-page failures surface
/// through the image pipeline (`getPage` / `render` / page image provider).
/// The photo_view errorBuilder below is the boundary that converts those
/// failures into the fixed safe message instead of a blank page or a raw
/// pipeline error.
pdfx.PhotoViewGalleryPageOptions _pdfSafePageBuilder(
  BuildContext context,
  Future<pdfx.PdfPageImage> pageImage,
  int index,
  pdfx.PdfDocument document,
) =>
    pdfx.PhotoViewGalleryPageOptions(
      imageProvider: pdfx.PdfPageImageProvider(
        pageImage,
        index,
        document.id,
      ),
      minScale: pdfx.PhotoViewComputedScale.contained,
      maxScale: pdfx.PhotoViewComputedScale.contained * 3,
      initialScale: pdfx.PhotoViewComputedScale.contained,
      heroAttributes:
          pdfx.PhotoViewHeroAttributes(tag: '${document.id}-$index'),
      errorBuilder: (_, __, ___) =>
          const _SafeMessageView(_unableToDisplayMessage),
    );
