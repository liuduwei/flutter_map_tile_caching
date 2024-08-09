// Copyright © Luka S (JaffaKetchup) under GPL-v3
// A full license can be found at .\LICENSE

part of '../../../flutter_map_tile_caching.dart';

/// A specialised [ImageProvider] that uses FMTC internals to enable browse
/// caching
class _FMTCImageProvider extends ImageProvider<_FMTCImageProvider> {
  /// Create a specialised [ImageProvider] that uses FMTC internals to enable
  /// browse caching
  _FMTCImageProvider({
    required this.provider,
    required this.options,
    required this.coords,
    required this.startedLoading,
    required this.finishedLoadingBytes,
  });

  /// An instance of the [FMTCTileProvider] in use
  final FMTCTileProvider provider;

  /// An instance of the [TileLayer] in use
  final TileLayer options;

  /// The coordinates of the tile to be fetched
  final TileCoordinates coords;

  /// Function invoked when the image starts loading (not from cache)
  ///
  /// Used with [finishedLoadingBytes] to safely dispose of the `httpClient` only
  /// after all tiles have loaded.
  final void Function() startedLoading;

  /// Function invoked when the image completes loading bytes from the network
  ///
  /// Used with [startedLoading] to safely dispose of the `httpClient` only
  /// after all tiles have loaded.
  final void Function() finishedLoadingBytes;

  @override
  ImageStreamCompleter loadImage(
    _FMTCImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // Closed by `getBytes`
    // ignore: close_sinks
    final chunkEvents = StreamController<ImageChunkEvent>();

    return MultiFrameImageStreamCompleter(
      codec: getBytes(
        coords: coords,
        options: options,
        provider: provider,
        key: key,
        chunkEvents: chunkEvents,
        finishedLoadingBytes: finishedLoadingBytes,
        startedLoading: startedLoading,
        requireValidImage: true,
      ).then(ImmutableBuffer.fromUint8List).then((v) => decode(v)),
      chunkEvents: chunkEvents.stream,
      scale: 1,
      debugLabel: coords.toString(),
      informationCollector: () => [
        DiagnosticsProperty('Store names', provider.storeNames),
        DiagnosticsProperty('Tile coordinates', coords),
        DiagnosticsProperty('Current provider', key),
      ],
    );
  }

  /// {@macro fmtc.imageProvider.getBytes}
  static Future<Uint8List> getBytes({
    required TileCoordinates coords,
    required TileLayer options,
    required FMTCTileProvider provider,
    Object? key,
    StreamController<ImageChunkEvent>? chunkEvents,
    void Function()? startedLoading,
    void Function()? finishedLoadingBytes,
    bool requireValidImage = false,
  }) async {
    final currentTLIR = provider.tileLoadingInterceptor != null
        ? TileLoadingInterceptorResult._()
        : null;

    void close([Object? error]) {
      finishedLoadingBytes?.call();

      if (key != null && error != null) {
        scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(key));
      }
      if (chunkEvents != null) {
        unawaited(chunkEvents.close());
      }

      if (currentTLIR != null) {
        currentTLIR.error = error;
        if (error != null) currentTLIR.resultPath = null;

        provider.tileLoadingInterceptor!
          ..value[coords] = currentTLIR
          // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
          ..notifyListeners();
      }
    }

    startedLoading?.call();

    final Uint8List bytes;
    try {
      bytes = await _internalGetBytes(
        coords: coords,
        options: options,
        provider: provider,
        chunkEvents: chunkEvents,
        requireValidImage: requireValidImage,
        currentTLIR: currentTLIR,
      );
    } catch (err, stackTrace) {
      close(err);

      if (err is FMTCBrowsingError) {
        final handlerResult = provider.errorHandler?.call(err);
        if (handlerResult != null) return handlerResult;
      }

      Error.throwWithStackTrace(err, stackTrace);
    }

    close();
    return bytes;
  }

  @override
  Future<_FMTCImageProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<_FMTCImageProvider>(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _FMTCImageProvider &&
          other.coords == coords &&
          other.provider == provider &&
          other.options == options);

  @override
  int get hashCode => Object.hash(coords, provider, options);
}
