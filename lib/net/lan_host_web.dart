class LanHost {
  static const bool supported = false;
  static LanHost? get current => null;
  int get port => 0;
  List<String> get urls => const [];
  static Future<LanHost> start({required String dataDir}) => Future.error(UnsupportedError('A browser can not serve'));
  Future<void> stop() async {}
}
