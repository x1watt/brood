#version 460 core

// Terrain with the original's palette animation: the map is stored as
// palette indices (red channel) and colored here through a 256x1 palette
// image the game rotates over time (water, lava and glow colors), the way
// Brood War cycles its 8-bit palette.

#include <flutter/runtime_effect.glsl>

uniform vec2 uCamera;   // map pixel at the view's top-left
uniform vec2 uMapSize;  // map size in pixels
uniform sampler2D uIndices;
uniform sampler2D uPalette;

out vec4 fragColor;

void main() {
  vec2 p = floor(FlutterFragCoord().xy + uCamera);
  if (p.x < 0.0 || p.y < 0.0 || p.x >= uMapSize.x || p.y >= uMapSize.y) {
    fragColor = vec4(0.0, 0.0, 0.0, 1.0);
    return;
  }
  float index = floor(texture(uIndices, (p + 0.5) / uMapSize).r * 255.0 + 0.5);
  fragColor = texture(uPalette, vec2((index + 0.5) / 256.0, 0.5));
}
