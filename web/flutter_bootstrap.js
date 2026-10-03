{{flutter_js}}
{{flutter_build_config}}

// Brood runs offline: CanvasKit is bundled (built with --no-web-resources-cdn)
// and fonts are bundled too, so font fallback looks in this folder instead
// of downloading from the internet.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: "assets/fallback-fonts/",
  },
});
