import 'bridge_raw.dart';
import 'bridge_raw_ffi.dart';

Future<BridgeRaw> openBridge() async => BridgeRawFfi(BridgeRawFfi.defaultLibraryPath());
