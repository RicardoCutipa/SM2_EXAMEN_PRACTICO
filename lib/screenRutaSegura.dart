import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../widgets/barralateral.dart'; // Ajusta esta ruta si es diferente

enum TimeFilter { all, last24Hours, last12Hours, last1Hour }

String timeFilterToString(TimeFilter filter) {
  switch (filter) {
    case TimeFilter.all: return "Todos";
    case TimeFilter.last24Hours: return "Últimas 24h";
    case TimeFilter.last12Hours: return "Últimas 12h";
    case TimeFilter.last1Hour: return "Última 1h";
  }
}

class ScreenRutaSegura extends StatefulWidget {
  const ScreenRutaSegura({super.key});

  @override
  State<ScreenRutaSegura> createState() => _ScreenRutaSeguraState();
}

class _ScreenRutaSeguraState extends State<ScreenRutaSegura> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>(); // Key para el Scaffold
  GoogleMapController? _mapController;
  static const CameraPosition _kInitialPosition = CameraPosition(target: LatLng(-18.0146, -70.2534), zoom: 13.0);
  final Set<Marker> _markers = {};
  List<Map<String, dynamic>> _allActiveReports = [];
  List<Map<String, dynamic>> _filteredActiveReports = [];
  final Map<String, BitmapDescriptor> _iconBitmapCache = {};
  bool _isLoadingReports = false;
  TimeFilter _selectedTimeFilter = TimeFilter.all;
  static const double _reportMarkerIconSize = 34.0;

  final List<Map<String, dynamic>> _categories = [
    {'id': 'accident', 'name': 'Accidente', 'icon': Icons.car_crash, 'color': Colors.red},
    {'id': 'fire', 'name': 'Incendio', 'icon': Icons.local_fire_department, 'color': Colors.orange},
    {'id': 'roadblock', 'name': 'Vía bloqueada', 'icon': Icons.block, 'color': Colors.amber},
    {'id': 'protest', 'name': 'Manifestación', 'icon': Icons.people, 'color': Colors.yellow.shade700},
    {'id': 'theft', 'name': 'Robo', 'icon': Icons.money_off, 'color': Colors.purple},
    {'id': 'assault', 'name': 'Asalto', 'icon': Icons.personal_injury, 'color': Colors.deepPurple},
    {'id': 'violence', 'name': 'Violencia', 'icon': Icons.front_hand, 'color': Colors.red.shade800},
    {'id': 'vandalism', 'name': 'Vandalismo', 'icon': Icons.broken_image, 'color': Colors.indigo},
    {'id': 'others', 'name': 'Otros', 'icon': Icons.more_horiz, 'color': Colors.grey},
  ];

  @override
  void initState() {
    super.initState();
    _fetchAllActiveReports();
  }

  @override
  void dispose() {
    _mapController?.dispose();
    super.dispose();
  }

  void _handleLogout() {
    Navigator.of(context).pushNamedAndRemoveUntil('/', (Route<dynamic> route) => false);
  }

  Map<String, dynamic> _getCategoryStyle(String? typeId) {
    final defaultCategory = _categories.firstWhere((cat) => cat['id'] == 'others',
        orElse: () => {'id': 'others', 'name': 'Otros', 'icon': Icons.help_outline, 'color': Colors.grey});
    final category = _categories.firstWhere((cat) => cat['id'] == typeId, orElse: () => defaultCategory);
    return {
      'iconData': category['icon'] ?? defaultCategory['icon'] ?? Icons.help_outline,
      'color': category['color'] ?? defaultCategory['color'] ?? Colors.grey,
      'name': category['name'] ?? defaultCategory['name'] ?? 'Desconocido'
    };
  }

  Future<BitmapDescriptor> _bitmapDescriptorFromIconData(IconData iconData, Color color, {double size = 64.0}) async {
    final String cacheKey = '${iconData.codePoint}_${color.value}_$size';
    if (_iconBitmapCache.containsKey(cacheKey)) return _iconBitmapCache[cacheKey]!;
    
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);
    final double iconSize = size * 0.6;
    final double circleRadius = size / 2;

    TextPainter textPainter = TextPainter(textDirection: ui.TextDirection.ltr)
      ..text = TextSpan(
          text: String.fromCharCode(iconData.codePoint),
          style: TextStyle(
            fontSize: iconSize,
            fontFamily: iconData.fontFamily,
            package: iconData.fontPackage,
            color: color,
          ),
        )
      ..layout();

    final Paint backgroundPaint = Paint()..color = color.withAlpha((0.25 * 255).round());
    canvas.drawCircle(Offset(circleRadius, circleRadius), circleRadius, backgroundPaint);
    final Paint borderPaint = Paint()..color = color.withAlpha((0.8 * 255).round())..style = PaintingStyle.stroke..strokeWidth = 2.5;
    canvas.drawCircle(Offset(circleRadius, circleRadius), circleRadius - 1.25, borderPaint);
    textPainter.paint(canvas, Offset((size - iconSize) / 2, (size - iconSize) / 2));
    
    final ui.Image img = await pictureRecorder.endRecording().toImage(size.toInt(), size.toInt());
    final ByteData? byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return BitmapDescriptor.defaultMarker; 
    
    final BitmapDescriptor descriptor = BitmapDescriptor.bytes(byteData.buffer.asUint8List());
    _iconBitmapCache[cacheKey] = descriptor;
    return descriptor;
  }

  Future<void> _fetchAllActiveReports() async {
    if (!mounted) return;
    setState(() => _isLoadingReports = true);
    try {
      QuerySnapshot snapshot = await FirebaseFirestore.instance.collection('Reportes').where('estado', isEqualTo: 'Activo').get();
      if (mounted) {
        _allActiveReports = snapshot.docs.map((doc) {
          final data = doc.data() as Map<String, dynamic>; data['docId'] = doc.id; return data;
        }).where((r) => r['ubicacion'] != null && r['ubicacion']['latitud'] is num && r['ubicacion']['longitud'] is num).toList();
        _applyTimeFilterToReports();
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error al cargar reportes: $e')));
    } finally {
      if (mounted) setState(() => _isLoadingReports = false);
    }
  }

  void _applyTimeFilterToReports() {
    if (!mounted) return;
    final now = DateTime.now();
    Duration? filterDuration;

    switch (_selectedTimeFilter) {
      case TimeFilter.last24Hours: filterDuration = const Duration(hours: 24); break;
      case TimeFilter.last12Hours: filterDuration = const Duration(hours: 12); break;
      case TimeFilter.last1Hour: filterDuration = const Duration(hours: 1); break;
      case TimeFilter.all: break;
    }

    _filteredActiveReports = filterDuration == null
        ? List.from(_allActiveReports)
        : _allActiveReports.where((r) {
            dynamic fecha = r['fechaCreacion'];
            if (fecha is Timestamp) return fecha.toDate().isAfter(now.subtract(filterDuration!));
            if (fecha is String) { 
              try { return DateTime.parse(fecha).isAfter(now.subtract(filterDuration!)); } catch(_) { return false; }
            }
            return false;
          }).toList();
    
    if (mounted) setState(() {});
    
    _updateReportMarkers();
  }

  Future<void> _updateReportMarkers() async {
    if (!mounted) return;
    Set<Marker> newReportMarkers = {};
    for (var reporte in _filteredActiveReports) {
      final ubicacion = reporte['ubicacion'];
      final LatLng pos = LatLng(ubicacion['latitud'].toDouble(), ubicacion['longitud'].toDouble());
      final String tipoReporte = reporte['tipo'] ?? 'others';
      final categoryStyle = _getCategoryStyle(tipoReporte);
      
      IconData iconData = categoryStyle['iconData'] as IconData? ?? Icons.help_outline;
      Color iconColor = categoryStyle['color'] as Color? ?? Colors.grey;

      final BitmapDescriptor iconBitmap = await _bitmapDescriptorFromIconData(iconData, iconColor, size: _reportMarkerIconSize);
      newReportMarkers.add(Marker(
        markerId: MarkerId('reporte_${reporte['docId']}'),
        position: pos,
        icon: iconBitmap,
      ));
    }
    if (mounted) {
      setState(() {
        _markers.clear();
        _markers.addAll(newReportMarkers);
      });
    }
  }

  Widget _buildCircularButton({required IconData icon, required String tooltip, required VoidCallback onPressed, Color backgroundColor = Colors.white, Color iconColor = Colors.black54, double opacity = 0.85}){
    return Container(
      decoration: BoxDecoration(
        color: backgroundColor.withAlpha((opacity * 255).round()), 
        shape: BoxShape.circle, 
        boxShadow: [BoxShadow(color: Colors.black.withAlpha(51), blurRadius: 5, offset: const Offset(0, 2))]
      ),
      child: IconButton(icon: Icon(icon), color: iconColor, tooltip: tooltip, onPressed: onPressed),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: _scaffoldKey, // Asignar la key al Scaffold
      drawer: BarraLateral(onLogout: _handleLogout),
      body: Stack(
        children: [
          GoogleMap(
            mapType: MapType.normal,
            initialCameraPosition: _kInitialPosition,
            zoomControlsEnabled: true,
            myLocationEnabled: true,
            myLocationButtonEnabled: true, // Puedes mantenerlo o quitarlo si prefieres tu propio botón
            markers: _markers,
            onMapCreated: (GoogleMapController controller) {
              _mapController = controller;
            },
          ),
          if (_isLoadingReports)
            const Center(
              child: CircularProgressIndicator(),
            ),
          
          Positioned( // Botón de Menú personalizado
            top: MediaQuery.of(context).padding.top + 15,
            left: 15,
            child: SafeArea(
              child: _buildCircularButton(
                icon: Icons.menu,
                tooltip: 'Abrir menú',
                onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              ),
            ),
          ),

          Positioned( // Botón de Filtro de Tiempo
            // Ajusta la posición si es necesario para que no se solape con el botón de menú
            // Por ejemplo, podrías ponerlo a la derecha o debajo del de menú.
            // Aquí lo pondré a la derecha del botón de menú como ejemplo
            top: MediaQuery.of(context).padding.top + 15,
            left: 15 + 56 + 10, // (posición del menú) + (ancho aprox botón) + (espacio)
            child: SafeArea(
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.85),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.2),
                      blurRadius: 5,
                      offset: const Offset(0, 2),
                    )
                  ],
                ),
                child: PopupMenuButton<TimeFilter>(
                  icon: const Icon(Icons.filter_list, color: Colors.black54),
                  tooltip: "Filtrar reportes por tiempo",
                  initialValue: _selectedTimeFilter,
                  onSelected: (TimeFilter result) {
                    if (_selectedTimeFilter != result) {
                      if (mounted) setState(() => _selectedTimeFilter = result);
                      _applyTimeFilterToReports();
                    }
                  },
                  itemBuilder: (BuildContext context) => TimeFilter.values
                      .map((filter) => PopupMenuItem<TimeFilter>(
                            value: filter,
                            child: Text(timeFilterToString(filter)),
                          ))
                      .toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}