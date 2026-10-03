/// One visible thing to draw, as reported by the bridge's "parts list" API
/// (see engine/bridge/include/bw_bridge.h). Deliberately not a pixel — the
/// renderer decides what image to draw for (imageTypeId, frameIndex,
/// flipped), which is what makes swapping in custom/HD textures later
/// possible without touching the engine.
class SpriteInfo {
  final int x;
  final int y;
  final int imageTypeId;
  final int frameIndex;
  final bool flipped;
  final int owner;
  final int elevationLevel;
  final int modifier;

  const SpriteInfo({
    required this.x,
    required this.y,
    required this.imageTypeId,
    required this.frameIndex,
    required this.flipped,
    required this.owner,
    required this.elevationLevel,
    required this.modifier,
  });
}
