import 'bridge_raw.dart';
import 'bridge_raw_web.dart';

Future<BridgeRaw> openBridge() async => BridgeRawWeb.open();
