//import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_animations/flutter_map_animations.dart';
import 'package:flutter_map_tile_caching/flutter_map_tile_caching.dart';
import 'package:http/io_client.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../../../shared/misc/shared_preferences.dart';
import '../../../shared/misc/store_metadata_keys.dart';
//import '../../../shared/state/download_provider.dart';
import '../../../shared/state/general_provider.dart';
import '../../../shared/state/region_selection_provider.dart';
import 'components/additional_overlay/additional_overlay.dart';
import 'components/debugging_tile_builder/debugging_tile_builder.dart';
//import 'components/download_progress/download_progress_masker.dart';
import 'components/region_selection/crosshairs.dart';
import 'components/region_selection/custom_polygon_snapping_indicator.dart';
import 'components/region_selection/region_shape.dart';

enum MapViewMode {
  standard,
  downloadRegion,
}

class MapView extends StatefulWidget {
  const MapView({
    super.key,
    this.mode = MapViewMode.standard,
    this.bottomPaddingWrapperBuilder,
    required this.layoutDirection,
    required this.bottomSheetOuterController,
  });

  final MapViewMode mode;
  final Widget Function(BuildContext context, Widget child)?
      bottomPaddingWrapperBuilder;
  final Axis layoutDirection;
  final DraggableScrollableController bottomSheetOuterController;

  @override
  State<MapView> createState() => _MapViewState();
}

class _MapViewState extends State<MapView> with TickerProviderStateMixin {
  late final _httpClient = IOClient(HttpClient()..userAgent = null);
  late final _mapController = AnimatedMapController(
    vsync: this,
    curve: Curves.easeInOut,
  );

  final _tileLoadingDebugger = ValueNotifier<TileLoadingInterceptorMap>({});

  late final _storesStream =
      FMTCRoot.stats.watchStores(triggerImmediately: true).asyncMap(
    (_) async {
      final stores = await FMTCRoot.stats.storesAvailable;

      return {
        for (final store in stores)
          store.storeName: await store.metadata.read
              .then((e) => e[StoreMetadataKeys.urlTemplate.key]),
      };
    },
  ).distinct(mapEquals);

  bool get _isInRegionSelectMode =>
      widget.mode == MapViewMode.downloadRegion &&
      !context.read<RegionSelectionProvider>().isDownloadSetupPanelVisible;

  @override
  Widget build(BuildContext context) {
    final isCrosshairsVisible = widget.mode == MapViewMode.downloadRegion &&
        !context.select<RegionSelectionProvider, bool>(
          (p) => p.isDownloadSetupPanelVisible,
        ) &&
        context.select<RegionSelectionProvider, RegionSelectionMethod>(
              (p) => p.regionSelectionMethod,
            ) ==
            RegionSelectionMethod.useMapCenter &&
        !context
            .select<RegionSelectionProvider, bool>((p) => p.customPolygonSnap);

    final mapOptions = MapOptions(
      initialCenter: LatLng(
        sharedPrefs.getDouble(SharedPrefsKeys.mapLocationLat.name) ?? 51.5216,
        sharedPrefs.getDouble(SharedPrefsKeys.mapLocationLng.name) ?? -0.6780,
      ),
      initialZoom:
          sharedPrefs.getDouble(SharedPrefsKeys.mapLocationZoom.name) ?? 12,
      interactionOptions: const InteractionOptions(
        flags: InteractiveFlag.all &
            ~InteractiveFlag.rotate &
            ~InteractiveFlag.doubleTapZoom,
        scrollWheelVelocity: 0.002,
      ),
      keepAlive: true,
      backgroundColor: const Color(0xFFaad3df),
      onTap: (_, __) {
        if (!_isInRegionSelectMode) return;

        final provider = context.read<RegionSelectionProvider>();

        final newPoint = provider.currentNewPointPos;

        switch (provider.currentRegionType) {
          case RegionType.rectangle:
            final coords = provider.addCoordinate(newPoint);

            if (coords.length == 2) {
              final region = RectangleRegion(LatLngBounds.fromPoints(coords));
              provider.addConstructedRegion(region);
            }
          case RegionType.circle:
            final coords = provider.addCoordinate(newPoint);

            if (coords.length == 2) {
              final region = CircleRegion(
                coords[0],
                const Distance(roundResult: false)
                        .distance(coords[0], coords[1]) /
                    1000,
              );
              provider.addConstructedRegion(region);
            }
          case RegionType.line:
            provider.addCoordinate(newPoint);
          case RegionType.customPolygon:
            if (provider.customPolygonSnap) {
              // Force closed polygon
              final coords = provider
                  .addCoordinate(provider.currentConstructingCoordinates.first);

              final region = CustomPolygonRegion(List.from(coords));
              provider
                ..addConstructedRegion(region)
                ..customPolygonSnap = false;
            } else {
              provider.addCoordinate(newPoint);
            }
        }
      },
      onSecondaryTap: (_, __) {
        if (!_isInRegionSelectMode) return;
        context.read<RegionSelectionProvider>().removeLastCoordinate();
      },
      onLongPress: (_, __) {
        if (!_isInRegionSelectMode) return;
        context.read<RegionSelectionProvider>().removeLastCoordinate();
      },
      onPointerHover: (evt, point) {
        if (!_isInRegionSelectMode) return;

        final provider = context.read<RegionSelectionProvider>();

        if (provider.regionSelectionMethod ==
            RegionSelectionMethod.usePointer) {
          provider.currentNewPointPos = point;

          if (provider.currentRegionType == RegionType.customPolygon) {
            final coords = provider.currentConstructingCoordinates;
            if (coords.length > 1) {
              final newPointPos = _mapController.mapController.camera
                  .latLngToScreenPoint(coords.first)
                  .toOffset();
              provider.customPolygonSnap = coords.first != coords.last &&
                  sqrt(
                        pow(newPointPos.dx - evt.localPosition.dx, 2) +
                            pow(newPointPos.dy - evt.localPosition.dy, 2),
                      ) <
                      15;
            }
          }
        }
      },
      onPositionChanged: (position, _) {
        if (!_isInRegionSelectMode) return;

        final provider = context.read<RegionSelectionProvider>();

        if (provider.regionSelectionMethod ==
            RegionSelectionMethod.useMapCenter) {
          provider.currentNewPointPos = position.center;

          if (provider.currentRegionType == RegionType.customPolygon) {
            final coords = provider.currentConstructingCoordinates;
            if (coords.length > 1) {
              final newPointPos = _mapController.mapController.camera
                  .latLngToScreenPoint(coords.first)
                  .toOffset();
              final centerPos = _mapController.mapController.camera
                  .latLngToScreenPoint(provider.currentNewPointPos)
                  .toOffset();
              provider.customPolygonSnap = coords.first != coords.last &&
                  sqrt(
                        pow(newPointPos.dx - centerPos.dx, 2) +
                            pow(newPointPos.dy - centerPos.dy, 2),
                      ) <
                      30;
            }
          }
        }
      },
      onMapEvent: (event) {
        if (event is MapEventFlingAnimationNotStarted ||
            event is MapEventMoveEnd ||
            event is MapEventFlingAnimationEnd ||
            event is MapEventScrollWheelZoom) {
          sharedPrefs
            ..setDouble(
              SharedPrefsKeys.mapLocationLat.name,
              _mapController.mapController.camera.center.latitude,
            )
            ..setDouble(
              SharedPrefsKeys.mapLocationLng.name,
              _mapController.mapController.camera.center.longitude,
            )
            ..setDouble(
              SharedPrefsKeys.mapLocationZoom.name,
              _mapController.mapController.camera.zoom,
            );
        }
      },
      onMapReady: () {
        context.read<GeneralProvider>().animatedMapController = _mapController;
      },
    );

    return StreamBuilder(
      stream: _storesStream,
      builder: (context, snapshot) {
        if (snapshot.data == null) {
          return const AbsorbPointer(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  CircularProgressIndicator.adaptive(),
                  SizedBox(height: 12),
                  Text('Preparing map...', textAlign: TextAlign.center),
                  Text(
                    'This should only take a few moments',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
            ),
          );
        }

        final stores = snapshot.data!;

        return Consumer<GeneralProvider>(
          builder: (context, provider, _) {
            final urlTemplate = provider.urlTemplate;

            final compiledStoreNames =
                Map<String, BrowseStoreStrategy?>.fromEntries([
              ...stores.entries.where((e) => e.value == urlTemplate).map((e) {
                final internalBehaviour = provider.currentStores[e.key];
                final behaviour = internalBehaviour == null
                    ? provider.inheritableBrowseStoreStrategy
                    : internalBehaviour.toBrowseStoreStrategy(
                        provider.inheritableBrowseStoreStrategy,
                      );
                if (behaviour == null) return null;
                return MapEntry(e.key, behaviour);
              }).nonNulls,
              ...stores.entries
                  .where((e) => e.value != urlTemplate)
                  .map((e) => MapEntry(e.key, null)),
            ]);

            final attribution = RichAttributionWidget(
              alignment: AttributionAlignment.bottomLeft,
              popupInitialDisplayDuration: const Duration(seconds: 3),
              popupBorderRadius: BorderRadius.circular(12),
              attributions: [
                TextSourceAttribution(Uri.parse(urlTemplate).host),
                const TextSourceAttribution(
                  'For demonstration purposes only',
                  prependCopyright: false,
                  textStyle: TextStyle(fontWeight: FontWeight.bold),
                ),
                const TextSourceAttribution(
                  'Offline mapping made with FMTC',
                  prependCopyright: false,
                  textStyle: TextStyle(fontStyle: FontStyle.italic),
                ),
                LogoSourceAttribution(
                  Image.asset('assets/icons/ProjectIcon.png'),
                  tooltip: 'flutter_map_tile_caching',
                ),
              ],
            );

            final otherStoresStrategy = provider.currentStores['(unspecified)']
                ?.toBrowseStoreStrategy();

            final tileLayer = TileLayer(
              urlTemplate: urlTemplate,
              userAgentPackageName: 'dev.jaffaketchup.fmtc.demo',
              maxNativeZoom: 20,
              tileProvider: widget.mode != MapViewMode.standard
                  ? NetworkTileProvider()
                  : FMTCTileProvider.multipleStores(
                      storeNames: compiledStoreNames,
                      otherStoresStrategy: otherStoresStrategy,
                      loadingStrategy: provider.loadingStrategy,
                      useOtherStoresAsFallbackOnly:
                          provider.useUnspecifiedAsFallbackOnly,
                      recordHitsAndMisses: false,
                      tileLoadingInterceptor: _tileLoadingDebugger,
                      httpClient: _httpClient,
                      // ignore: invalid_use_of_visible_for_testing_member
                      fakeNetworkDisconnect: provider.fakeNetworkDisconnect,
                    ),
              tileBuilder: !provider.displayDebugOverlay ||
                      widget.mode != MapViewMode.standard
                  ? null
                  : (context, tileWidget, tile) => DebuggingTileBuilder(
                        tileLoadingDebugger: _tileLoadingDebugger,
                        tileWidget: tileWidget,
                        tile: tile,
                      ),
            );

            //final isDownloadProgressMaskerVisible = widget.mode ==
            //        MapViewMode.downloadRegion &&
            //    context.select<DownloadingProvider, bool>((p) => p.isFocused);

            final map = FlutterMap(
              mapController: _mapController.mapController,
              options: mapOptions,
              children: [
                /*DownloadProgressMasker(
                  key: ObjectKey(
                    isDownloadProgressMaskerVisible
                        ? context
                            .select<DownloadingProvider, DownloadableRegion>(
                            (p) => p.downloadableRegion,
                          )
                        : null,
                  ),
                  tileEvents: isDownloadProgressMaskerVisible
                      ? context.select<DownloadingProvider,
                          Stream<DownloadProgress>>((p) => p.rawTileEventStream)
                      : null,
                  minZoom: isDownloadProgressMaskerVisible
                      ? context.select<DownloadingProvider, int>(
                          (p) => p.downloadableRegion.minZoom,
                        )
                      : 0,
                  maxZoom: isDownloadProgressMaskerVisible
                      ? context.select<DownloadingProvider, int>(
                          (p) => p.downloadableRegion.maxZoom,
                        )
                      : 0,
                  child: tileLayer,
                ),*/
                tileLayer,
                if (widget.mode == MapViewMode.downloadRegion) ...[
                  const RegionShape(),
                  const CustomPolygonSnappingIndicator(),
                ],
                if (widget.bottomPaddingWrapperBuilder case final bpwb?)
                  Builder(builder: (context) => bpwb(context, attribution))
                else
                  attribution,
              ],
            );

            return Stack(
              fit: StackFit.expand,
              children: [
                MouseRegion(
                  opaque: false,
                  cursor: widget.mode == MapViewMode.standard ||
                          context.select<RegionSelectionProvider, bool>(
                            (p) => p.isDownloadSetupPanelVisible,
                          ) ||
                          context.select<RegionSelectionProvider,
                                  RegionSelectionMethod>(
                                (p) => p.regionSelectionMethod,
                              ) ==
                              RegionSelectionMethod.useMapCenter
                      ? MouseCursor.defer
                      : context.select<RegionSelectionProvider, bool>(
                          (p) => p.customPolygonSnap,
                        )
                          ? SystemMouseCursors.none
                          : SystemMouseCursors.precise,
                  child: map,
                ),
                if (isCrosshairsVisible) const Center(child: Crosshairs()),
                Positioned(
                  bottom: 0,
                  right: 8,
                  left: 8,
                  child: widget.bottomPaddingWrapperBuilder != null
                      ? Builder(
                          builder: (context) =>
                              widget.bottomPaddingWrapperBuilder!(
                            context,
                            AdditionalOverlay(
                              bottomSheetOuterController:
                                  widget.bottomSheetOuterController,
                              layoutDirection: Axis.vertical,
                              mode: widget.mode,
                            ),
                          ),
                        )
                      : AdditionalOverlay(
                          bottomSheetOuterController:
                              widget.bottomSheetOuterController,
                          layoutDirection: Axis.horizontal,
                          mode: widget.mode,
                        ),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
